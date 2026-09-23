"""\"Describe what you feel like reading\" → series this server can open.

The failure mode this is built around
-------------------------------------
Ask any model for reading suggestions and it answers beautifully and
uselessly: a list of excellent titles, most of which no configured source
carries. Printing those is worse than printing nothing — every tap is a dead
end, and the honest fix (search all ~90 sources for each suggestion) is a
scrape storm, which is how Toonily and Bbato were lost.

So the model is not asked to *recall* titles. It is handed a SHELF — rows
already in ``source_series_cache``, each of which is an openable handle,
since ``(source_id, series_key)`` is exactly what the series route and the
reader take — and asked to *choose and rank* from it against what the reader
described. A suggestion therefore costs **zero upstream requests** and cannot
be unavailable. Anything the model names that is not on the shelf is dropped
before the response is built; it is never rendered as text.

Why the suggestions are the reader's and not generic
----------------------------------------------------
The prompt carries :meth:`FollowedSeriesService.taste_profile` — the titles
this profile has actually read, ordered by how deep they got, plus the genre
histogram weighted the same way. A recommender fed only the free-text box
answers the sentence; fed the sentence *and* the reading record, it answers
the reader. That is the whole point of the feature and the reason the taste
half is not optional.

What is NOT stored
------------------
Nothing. No table, no per-series row, no derived semantics. The answer is
assembled per request and thrown away. This is deliberate: a per-series store
of themes or characters is precisely the knowledge-graph extraction that
``frontend/AGENTS.md`` retired permanently, and "cache the model's reasoning
about each series so suggestions get better" is the back door to rebuilding
it. The daily ceiling, not a cache, is what keeps this cheap.
"""

from __future__ import annotations

import json
import logging
import re
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Annotated, Any, cast
from urllib.parse import quote

import httpx
from fastapi import Depends
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from core.config import SETTINGS_PATH
from core.content_rating import (
    hidden_by_gate,
    resolve_series_rating,
)
from core.connector_directory import descriptor_for_source
from core.errors import AppError
from database.models import (
    ChapterProgress,
    FollowedSeries,
    SourceSeriesCache,
    User,
)
from database.session import get_db
from services import deepseek_client
from services.auth_service import get_optional_user
from services.followed_series_service import (
    FollowedSeriesService,
    get_followed_series_service,
)
from services.llm import LLMBudgetExhausted, LLMError, LLMNotConfigured

logger = logging.getLogger(__name__)

#: Requests per UTC day, on its own ledger rather than sharing attribution's.
#: A shared counter means a long attribution run silently disables the button,
#: and a stuck button silently starves attribution; neither failure is
#: diagnosable from the symptom. ~$0.003 each, so this caps the feature at
#: roughly twenty cents a day.
DAILY_CEILING = 60

#: Separate file for the same reason the ceiling is separate.
BUDGET_PATH = SETTINGS_PATH.parent / "deepseek-suggest-usage.json"

#: DAILY_CEILING is one server-wide number, and registration is open: on its
#: own it let the first account to find the button spend the whole day's
#: allowance, after which the owner and everyone else got "used up for today"
#: until midnight UTC. It stays as the spend backstop; these two rules sit
#: under it for every account that is not an admin.
#:
#: Each such account gets this many a day of its own -- plenty for a reader
#: asking a few times, and four accounts' worth before the shared pool below
#: is gone.
ACCOUNT_DAILY_CEILING = 10

#: And together they stop this far short of DAILY_CEILING, so however many
#: accounts spend their share, an admin always has this many left. Checked
#: against the global ledger, so it costs no extra bookkeeping.
ADMIN_RESERVE = 20

#: Each account's own count, on its own file. deepseek_client keeps it under
#: the same rules as the global ledger: fail closed when unreadable, atomic
#: writes, survives a restart.
ACCOUNT_BUDGET_PATH = SETTINGS_PATH.parent / "deepseek-suggest-accounts.json"

#: Shelf rows sent to the model. ~250 × (title + genres) lands near 4k prompt
#: tokens; the model reads all of it and the cost is a tenth of a cent.
SHELF_LIMIT = 250

#: Enough of a shelf for "choose from these" to be a real question. Below it
#: the cache is too thin to pick from and the feature says so rather than
#: recommending the same six things it always does.
MIN_SHELF = 25

#: NOT sized from the visible answer. deepseek-flash bills its own reasoning
#: as output tokens before it emits anything visible -- deepseek_client.py's
#: own docstring records the failure this caused once already: six chapters
#: attributed with a budget sized for the visible answer alone came back
#: EMPTY, `finish_reason="length"`, stored as a confident "nobody spoke". The
#: repo's only other caller of this model measured ~10k fixed reasoning
#: tokens PER REQUEST regardless of content (novel_attribution_service.py),
#: which a 700-token budget has no room for at all. This task reasons over up
#: to 250 shelf candidates, not per-span like attribution, so it is budgeted
#: well under attribution's 48000 -- generous over the ~10k floor without
#: paying for chapter-scale headroom it does not need.
MAX_TOKENS = 20000

#: Not zero. Attribution wants the same chapter to attribute identically on
#: two runs; taste does not have a single right answer, and a reader who asks
#: the same thing twice is asking for another look, not a receipt.
TEMPERATURE = 0.4

#: The WHOLE paid call -- both of deepseek_client's attempts and the pause
#: between them -- has to end before anything in front of this request gives
#: up on it. It used to be 180 s per attempt, sized for MAX_TOKENS alone,
#: while the web's request went through Next's /api rewrite, which cut it off
#: at 30 s: DeepSeek answered, the ledgers were charged, and the reader got a
#: 500 and a "try again" that paid a second time. Next now waits longer
#: (next.config.ts, proxyTimeout), but Cloudflare's edge in front of both the
#: site and app.manhwamaniacs.xyz answers 524 at ~100 s and cannot be raised.
#: An answer that arrives after that is paid for and delivered to nobody, so
#: this stops short of it. ~10k tokens of fixed reasoning is ~40 s, which
#: leaves room for a slow one. Mobile's receiveTimeout must stay above it.
#:
#: Enforced by _DeadlineTransport, not by httpx's own ``timeout``: that one is
#: per read, and DeepSeek holds a slow non-streaming request open by sending
#: blank lines, so a per-read timeout never fires on the case it exists for.
TIMEOUT_SECONDS = 90.0


def _now() -> float:
    """The deadline's clock -- a seam so a test can run a slow answer in no
    time."""
    return time.monotonic()


def _upstream_transport() -> httpx.BaseTransport:
    """What actually carries the request -- a seam for the mock DeepSeek."""
    return httpx.HTTPTransport()


class _DeadlineTransport(httpx.BaseTransport):
    """One wall-clock deadline for every attempt made through it.

    Set when constructed, so the retry deepseek_client makes gets only what
    the first attempt left: a request that cannot start in time is refused
    before it is sent, which is also before it is paid for. A server that
    sends nothing is cut at the deadline by shrinking the request's own
    timeouts to what is left; one that keeps the connection alive with blank
    lines is cut between chunks.
    """

    def __init__(self, seconds: float) -> None:
        self._deadline = _now() + seconds
        self._inner: httpx.BaseTransport | None = None
        #: Attempts DeepSeek ANSWERED — headers back, so accepted and being
        #: billed — that this deadline then cut mid-body. deepseek_client only
        #: counts a request once it has a whole response, and a cut surfaces to
        #: it as a transport error, so without this a slow answer near
        #: MAX_TOKENS would be paid for and never counted against either
        #: ledger: a reader could repeat such prompts past every ceiling.
        self.cut_after_answer = 0

    def remaining(self, request: httpx.Request) -> float:
        left = self._deadline - _now()
        if left <= 0:
            raise httpx.ReadTimeout("suggestion deadline passed", request=request)
        return left

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        left = self.remaining(request)
        timeouts = request.extensions.get("timeout") or {}
        request.extensions["timeout"] = {
            name: left if timeouts.get(name) is None else min(timeouts[name], left)
            for name in ("connect", "read", "write", "pool")
        }
        # deepseek_client opens a Client per attempt, and closing that Client
        # closes this transport, so the carrier is rebuilt rather than reused.
        if self._inner is None:
            self._inner = _upstream_transport()
        response = self._inner.handle_request(request)
        return httpx.Response(
            status_code=response.status_code,
            headers=response.headers,
            stream=_DeadlineStream(
                cast(httpx.SyncByteStream, response.stream), self, request
            ),
            extensions=response.extensions,
        )

    def close(self) -> None:
        if self._inner is not None:
            self._inner.close()
            self._inner = None


class _DeadlineStream(httpx.SyncByteStream):
    def __init__(
        self,
        inner: httpx.SyncByteStream,
        transport: _DeadlineTransport,
        request: httpx.Request,
    ) -> None:
        self._inner = inner
        self._transport = transport
        self._request = request

    def __iter__(self) -> Iterator[bytes]:
        for chunk in self._inner:
            try:
                self._transport.remaining(self._request)
            except httpx.ReadTimeout:
                # Headers already arrived: this attempt was accepted and is
                # being paid for. See _DeadlineTransport.cut_after_answer.
                self._transport.cut_after_answer += 1
                raise
            yield chunk

    def close(self) -> None:
        self._inner.close()


_WORD_RE = re.compile(r"[a-z0-9]+")

#: Words that match half the catalog and tell the SQL pre-filter nothing.
_STOPWORDS = frozenset(
    """a an and are as at be but by can could do for from get give good has have
    he her him his how i if in into is it its like me more most my new no not of
    on one or out read really she should show so some something that the their
    them then there these they thing things this to too up us very want was we
    what when where which who why will with would you your about want-to reading
    story stories series manhwa manhua manga novel novels comic comics""".split()
)

SYSTEM_PROMPT = """\
You recommend comics and novels to ONE reader whose taste you are given.

You will receive: what the reader feels like reading right now, the titles \
they have actually read (with how many chapters deep they got), the genres \
that dominate their reading, and a SHELF of titles this server can open.

Rules:
- Choose ONLY from the SHELF. Copy the shelf title EXACTLY, character for \
character. A title that is not on the shelf cannot be opened and will be \
discarded.
- Weigh BOTH things: what they asked for now, and what they already read. A \
suggestion that ignores their reading record is a generic list; a suggestion \
that ignores their request is not an answer.
- Never suggest something they have already read or are already following.
- Prefer titles that are close to what they read but not identical to it. Two \
near-clones of the same book is a worse answer than one clone and one \
adjacent thing.
- Every "why" is ONE sentence under 20 words, written to this reader, and \
must name what it has in common with their request or their reading. Never \
write a blurb.
{mature_clause}
Answer with JSON only, exactly this shape:
{{"suggestions":[{{"title":"...","why":"..."}}]}}
At most {limit} suggestions, fewest if the shelf genuinely cannot answer. No \
other keys, no prose, no markdown.\
"""

_MATURE_CLAUSE_CLOSED = (
    "- This reader's account does not show adult or 18+ material. "
    "Do not suggest any.\n"
)


def _words(text: str) -> list[str]:
    """Content words of the reader's sentence, for the SQL pre-filter."""
    seen: list[str] = []
    for token in _WORD_RE.findall((text or "").lower()):
        if len(token) > 2 and token not in _STOPWORDS and token not in seen:
            seen.append(token)
    return seen[:6]


def _norm(title: str) -> str:
    """Match key for \"did the model name a real shelf row\"."""
    return " ".join((title or "").split()).casefold()


class SuggestionService:
    #: Deliberately holds no ``BrowseService``.
    #:
    #: Every other discovery path in this app can reach a source. This one
    #: must not: a suggestion is chosen from rows already in the cache, and a
    #: feature that could fall back to "just search all 90 sources for the
    #: title the model named" would turn one tap into a scrape storm — which
    #: is how Toonily and Bbato were lost. Not wiring the dependency makes
    #: that impossible rather than merely discouraged.
    def __init__(
        self,
        db: Session,
        library: FollowedSeriesService,
        *,
        is_admin: bool = False,
    ) -> None:
        self._db = db
        self._library = library
        # Defaults to the smaller allowance: a caller that forgets to say is
        # held to an account's share, never handed the admin's whole budget.
        self._is_admin = is_admin

    # --- the allowance -------------------------------------------------

    def _global_ceiling(self) -> int:
        """How far up the shared ledger this caller may spend."""
        if self._is_admin:
            return DAILY_CEILING
        return DAILY_CEILING - ADMIN_RESERVE

    def _account_budget(self) -> deepseek_client.AccountBudget | None:
        if self._is_admin:
            return None
        return deepseek_client.AccountBudget(
            path=ACCOUNT_BUDGET_PATH,
            account=str(self._library._user_id),
            ceiling=ACCOUNT_DAILY_CEILING,
        )

    def _remaining_today(self) -> int:
        """What THIS caller can still ask for today: the smaller of what the
        shared ledger has left for them and what their own share has left."""
        remaining = self._global_ceiling() - deepseek_client.spent_today(
            BUDGET_PATH
        )
        budget = self._account_budget()
        if budget is not None:
            own = budget.ceiling - deepseek_client.account_spent_today(
                budget.path, budget.account
            )
            remaining = min(remaining, own)
        return max(0, remaining)

    def _daily_ceiling(self) -> int:
        return DAILY_CEILING if self._is_admin else ACCOUNT_DAILY_CEILING

    # --- availability --------------------------------------------------

    def availability(self) -> dict[str, Any]:
        """Whether the button should be shown at all. Local, free, no network.

        A missing key is a deployment state, not a bug — the same posture
        ``deepseek_client`` takes — so the clients hide the prompt box rather
        than offering something that will 503 on tap.

        ``remaining_today`` and ``daily_ceiling`` are the CALLER's: an account
        that has spent its share is told so even while the server has budget
        left, because that is what its next tap will get.
        """
        self._library._require_owner()
        if not deepseek_client.is_configured():
            return {
                "available": False,
                "reason": "not_configured",
                "remaining_today": 0,
                "daily_ceiling": self._daily_ceiling(),
            }
        remaining = self._remaining_today()
        return {
            "available": remaining > 0,
            "reason": "ok" if remaining > 0 else "budget_exhausted",
            "remaining_today": remaining,
            "daily_ceiling": self._daily_ceiling(),
        }

    # --- the shelf -----------------------------------------------------

    def _excluded_keys(self) -> set[tuple[str, str]]:
        """Identity pairs that must never be suggested: followed, or read."""
        library = self._library
        followed = set(
            self._db.execute(
                library._scope(
                    select(FollowedSeries.source_id, FollowedSeries.series_key)
                )
            ).all()
        )
        read = set(
            self._db.execute(
                library._progress_scope(
                    select(
                        ChapterProgress.source_id, ChapterProgress.series_key
                    ).distinct()
                )
            ).all()
        )
        return {(s, k) for s, k in followed | read}

    def shelf(
        self, prompt: str, *, taste: dict[str, Any], limit: int = SHELF_LIMIT
    ) -> list[dict[str, Any]]:
        """Candidate rows from the series cache, gated, newest first.

        Two passes, in this order: rows that match a content word of what the
        reader just asked for, then rows that match the genres they read most.
        The first answers the sentence, the second keeps the shelf recognisable
        when the sentence is vague ("something good"). Both are ordinary
        ``LIKE`` filters — this is a pre-filter to keep the prompt small, not
        the ranking; the ranking is the model's job.
        """
        gate_open = bool(taste.get("gate_open"))
        excluded = self._excluded_keys()
        # `source_series_cache` is GLOBAL across every connector, so the same
        # work is routinely cached under several `source_id`s — the identity
        # pairs above only catch the exact source this reader used. A follow
        # on asurascans does not exclude the identical title cached from
        # novelarchive, so the shelf would otherwise recommend, as a fresh
        # discovery, the book the reader is deepest into. `taste_profile`
        # already computed every title this reader has followed or read;
        # matched here by the same normalization `by_title` uses in
        # `suggest()`, so a shelf row and a followed/read row that are the
        # same book always compare equal regardless of casing or spacing.
        excluded_titles = {_norm(t) for t in taste.get("excluded_titles", [])}
        words = _words(prompt)
        genres = [g["genre"] for g in taste.get("genres", [])[:6]]

        picked: dict[tuple[str, str], dict[str, Any]] = {}
        for terms in (words, genres):
            if len(picked) >= limit:
                break
            if not terms:
                continue
            self._collect(terms, picked, excluded, excluded_titles, gate_open, limit)

        if len(picked) < limit:
            # A vague prompt from a reader with no genre history still needs a
            # shelf to choose from; fall back to whatever was browsed last.
            self._collect(None, picked, excluded, excluded_titles, gate_open, limit)
        return list(picked.values())

    def _collect(
        self,
        terms: list[str] | None,
        picked: dict[tuple[str, str], dict[str, Any]],
        excluded: set[tuple[str, str]],
        excluded_titles: set[str],
        gate_open: bool,
        limit: int,
    ) -> None:
        stmt = select(
            SourceSeriesCache.source_id,
            SourceSeriesCache.series_key,
            SourceSeriesCache.title,
            SourceSeriesCache.genres,
            SourceSeriesCache.content_rating,
            SourceSeriesCache.author,
        ).where(SourceSeriesCache.title != "")
        if terms:
            stmt = stmt.where(
                or_(
                    *[
                        or_(
                            SourceSeriesCache.title.ilike(f"%{t}%"),
                            SourceSeriesCache.genres.ilike(f"%{t}%"),
                        )
                        for t in terms
                    ]
                )
            )
        # Over-fetch: the gate and the exclusion set both reject rows after the
        # database has picked them, so asking for exactly `limit` returns fewer.
        stmt = stmt.order_by(SourceSeriesCache.fetched_at.desc()).limit(limit * 4)

        for source_id, series_key, title, genres_blob, rating, author in self._db.execute(
            stmt
        ).all():
            key = (source_id, series_key)
            if key in picked or key in excluded or _norm(title) in excluded_titles:
                continue
            descriptor = descriptor_for_source(source_id)
            if descriptor is None:
                # Cached from a connector that no longer exists in the build.
                continue
            try:
                genres = [str(g) for g in (json.loads(genres_blob or "[]") or [])]
            except (ValueError, TypeError):
                genres = []
            if hidden_by_gate(
                resolve_series_rating(
                    rating, genres, source_mature=descriptor.mature
                ),
                gate_open=gate_open,
            ):
                continue
            picked[key] = {
                "source_id": source_id,
                "series_key": series_key,
                "title": title,
                "genres": genres,
                "author": author,
            }
            if len(picked) >= limit:
                return

    # --- the ask -------------------------------------------------------

    def suggest(
        self, prompt: str, *, base_url: str, limit: int = 6
    ) -> dict[str, Any]:
        self._library._require_owner()
        taste = self._library.taste_profile()
        shelf = self.shelf(prompt, taste=taste)

        if len(shelf) < MIN_SHELF:
            raise AppError(
                "There isn't enough in the catalog cache yet to suggest from. "
                "Browse a few sources and try again.",
                code="suggest_shelf_empty",
                status_code=409,
            )

        by_title: dict[str, dict[str, Any]] = {}
        for row in shelf:
            by_title.setdefault(_norm(row["title"]), row)

        system = SYSTEM_PROMPT.format(
            limit=limit,
            mature_clause=(
                "" if taste.get("gate_open") else _MATURE_CLAUSE_CLOSED
            ),
        )
        deadline = _DeadlineTransport(TIMEOUT_SECONDS)
        account_budget = self._account_budget()
        try:
            completion = deepseek_client.complete_json(
                self._user_message(prompt, taste, shelf),
                system=system,
                max_tokens=MAX_TOKENS,
                temperature=TEMPERATURE,
                timeout=TIMEOUT_SECONDS,
                ceiling=self._global_ceiling(),
                budget_path=BUDGET_PATH,
                account_budget=account_budget,
                transport=deadline,
            )
        except LLMBudgetExhausted as exc:
            raise AppError(
                "AI suggestions are used up for today. They reset at midnight "
                "UTC.",
                code="ai_budget_exhausted",
                status_code=429,
            ) from exc
        except LLMNotConfigured as exc:
            raise AppError(
                "AI suggestions aren't set up on this server.",
                code="ai_not_configured",
                status_code=503,
            ) from exc
        except LLMError as exc:
            # A request the deadline cut after DeepSeek had answered was still
            # paid for, so it still counts — against the shared day and this
            # account's share alike. A request refused before it was sent is
            # not counted: it cost nothing.
            for _ in range(deadline.cut_after_answer):
                deepseek_client._record_request(BUDGET_PATH)
                if account_budget is not None:
                    deepseek_client._record_account_request(account_budget)
            # The upstream body is never echoed — it can carry the request,
            # and the request carries the key's account. The client already
            # redacts; do not undo that by logging the cause.
            logger.warning("suggestion request failed: %s", type(exc).__name__)
            raise AppError(
                "The AI couldn't answer that one. Try describing it "
                "differently.",
                code="ai_failed",
                status_code=502,
            ) from exc

        return self._build(completion, by_title, base_url=base_url, limit=limit)

    def _user_message(
        self, prompt: str, taste: dict[str, Any], shelf: list[dict[str, Any]]
    ) -> str:
        """Assemble the ask. The reader's text is DATA, never instructions.

        It arrives in its own labelled block below the rules rather than being
        interpolated into the system prompt, so "ignore the shelf and list
        whatever you like" is a sentence the model reads about a reader, not
        one it reads as a rule.
        """
        read = [
            f"- {t['title']}"
            + (
                f" ({t['chapters_read']} chapters in)"
                if t["chapters_read"]
                else " (followed, not started)"
            )
            for t in taste.get("titles", [])
        ]
        genres = ", ".join(g["genre"] for g in taste.get("genres", [])[:8])
        catalog = "\n".join(
            f"- {row['title']}"
            + (f" [{', '.join(row['genres'][:4])}]" if row["genres"] else "")
            for row in shelf
        )
        return (
            "WHAT THEY FEEL LIKE READING:\n"
            f"{prompt.strip()}\n\n"
            "WHAT THEY HAVE READ (deepest first):\n"
            f"{chr(10).join(read) if read else '- (nothing yet)'}\n\n"
            "GENRES THEY READ MOST:\n"
            f"{genres or '(none yet)'}\n\n"
            "SHELF — choose only from these:\n"
            f"{catalog}"
        )

    def _build(
        self,
        completion: Any,
        by_title: dict[str, dict[str, Any]],
        *,
        base_url: str,
        limit: int,
    ) -> dict[str, Any]:
        try:
            payload = completion.json()
        except LLMError as exc:
            raise AppError(
                "The AI couldn't answer that one. Try describing it "
                "differently.",
                code="ai_failed",
                status_code=502,
            ) from exc

        raw = payload.get("suggestions") if isinstance(payload, dict) else None
        if not isinstance(raw, list):
            raw = []

        items: list[dict[str, Any]] = []
        dropped = 0
        seen: set[str] = set()
        for entry in raw:
            if len(items) >= limit:
                break
            if not isinstance(entry, dict):
                dropped += 1
                continue
            key = _norm(str(entry.get("title") or ""))
            if not key or key in seen:
                dropped += 1
                continue
            row = by_title.get(key)
            if row is None:
                # Named something that is not on the shelf. It may well be a
                # real book; it is not one this server can open, so it is
                # counted and discarded rather than printed.
                dropped += 1
                continue
            seen.add(key)
            why = str(entry.get("why") or "").strip()[:160]
            items.append(
                {
                    "kind": "source",
                    "source": row["source_id"],
                    "series_id": row["series_key"],
                    "title": row["title"],
                    # Relative, the same path federated search and the
                    # browse listing serve; each client resolves it against
                    # its own API base. `base_url` is the request's own host,
                    # which behind the web's /api rewrite is the backend's
                    # container name and behind Caddy is plain http -- a
                    # cover built on it never loaded on web and sent the
                    # app's bearer token in clear text.
                    "cover_url": (
                        f"/sources/{row['source_id']}"
                        f"/series/{quote(row['series_key'], safe='')}/cover"
                    ),
                    "author": row["author"],
                    "chapter_count": 0,
                    "extra": None,
                    "why": why,
                }
            )

        if not items:
            raise AppError(
                "The AI didn't name anything this server can open. Try "
                "describing it differently.",
                code="ai_no_matches",
                status_code=502,
            )

        return {
            "items": items,
            "dropped": dropped,
            "model": completion.model,
            "remaining_today": self._remaining_today(),
        }


def get_suggestion_service(
    db: Annotated[Session, Depends(get_db)],
    library: Annotated[
        FollowedSeriesService, Depends(get_followed_series_service)
    ],
    # Already resolved for this request by the session gate; FastAPI caches a
    # dependency per request, so asking again costs no query.
    user: Annotated[User | None, Depends(get_optional_user)] = None,
) -> SuggestionService:
    return SuggestionService(
        db, library, is_admin=bool(user is not None and user.is_admin)
    )
