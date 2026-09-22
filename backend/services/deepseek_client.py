"""Minimal DeepSeek chat client, for novel speaker attribution.

This is the backend's ONLY outbound call to a paid third-party API, and the
only place an API key is held in the process, so the rules it follows are
deliberately stricter than the rest of the HTTP in this codebase.

**The key is read from the environment and nowhere else.** Never from
``Settings``: that model is declared ``extra="allow"`` and is *written back* to
``settings.json`` by ``save_settings`` -- so a key that ever reached it would be
persisted to disk, copied into every database backup, and served to whatever can
read the settings route. ``os.getenv`` inside this module keeps it in process
memory and out of every file this project writes.

**The host is pinned and redirects are refused.** ``httpx`` re-sends the
``Authorization`` header when it follows a redirect to the same host, and a 302
pointing somewhere else is exactly how a key leaks to a host nobody audited.
There is one legitimate destination here, so anything but a direct 2xx from it
is an error rather than something to chase.

**Spending has a hard daily ceiling.** Attribution is cheap per chapter
(~$0.003) and ruinous in a loop: a retry storm, or a re-attribution sweep over a
3,000-chapter series, is the failure mode that turns a nine-cent feature into a
bill. The ceiling is counted in requests, persisted next to ``settings.json`` so
a container restart cannot reset it, and it refuses loudly rather than degrading
quietly.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx

from core.config import SETTINGS_PATH
from services.llm import (
    Completion,
    LLMBudgetExhausted,
    LLMError,
    LLMNotConfigured,
)

logger = logging.getLogger(__name__)

#: The one legitimate destination. Built from a constant rather than a setting
#: so no configuration change can redirect a bearer token somewhere else.
API_HOST = "api.deepseek.com"
API_URL = f"https://{API_HOST}/chat/completions"

#: The cheap non-reasoning model. Attribution is a reading task against rules
#: supplied in the prompt, not a thinking task, and the reasoning model costs
#: several times more for the same answer.
#:
#: Named `deepseek-flash` because that is what /models actually lists as of
#: 2026-09-19; the older `deepseek-chat` id still answers but is an alias, and
#: a request for it comes back stamped `deepseek-flash`. Which is why the
#: RESPONSE's model is what gets recorded below -- pinning a name here and
#: storing it as fact would put a model in the database that never ran.
MODEL = "deepseek-flash"

#: Generous: the model reasons for a minute or more on a full chapter before
#: emitting its first visible token. Measured: 84s for a 26-span chapter, and
#: reasoning scales with span count. Short enough that a wedged connection
#: cannot hold a worker indefinitely.
TIMEOUT_SECONDS = 600.0

#: Requests per UTC day. ~$0.003 each, so this caps a runaway at roughly $1.50 —
#: enough for four full 120-chapter validation passes in one day, and nowhere
#: near enough to matter if something loops.
DAILY_REQUEST_CEILING = 500

_BUDGET_PATH = SETTINGS_PATH.parent / "deepseek-usage.json"


# The shared shape lives in ``services.llm`` because a local model answers the
# same question and attribution takes whichever is available; these names stay
# so existing callers and tests read unchanged.
DeepSeekError = LLMError
DeepSeekNotConfigured = LLMNotConfigured
DeepSeekBudgetExhausted = LLMBudgetExhausted


def api_key() -> str | None:
    """The key, or None. Read fresh so a restart picks up a rotation."""
    key = os.getenv("DEEPSEEK_API_KEY", "").strip()
    return key or None


def is_configured() -> bool:
    """Whether attribution can run at all.

    Callers use this to degrade to narrator-only rather than raising into a
    request: a missing key is a deployment state, not a bug.
    """
    return api_key() is not None


# --- daily ceiling ---------------------------------------------------------


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


#: Returned by `_read_budget` for a ledger that exists but cannot be trusted
#: (truncated JSON, permission denied, a directory where the file should be).
#: Deliberately larger than any real `ceiling` argument this module is called
#: with, so a corrupt ledger reads as "budget exhausted" for every caller
#: rather than as "nothing spent yet" -- see the docstring below for why a
#: missing file is NOT the same case as this one.
_UNREADABLE = 1 << 30


def _read_budget(path: Path) -> tuple[str, int]:
    """The ledger's `(date, requests)`, read defensively.

    Two failure shapes are NOT the same thing and used to be conflated:

    - The file does not exist. This is the normal state before the first
      request of any kind has ever been recorded -- a fresh deployment, or a
      fresh `budget_path` a test just made up -- and reads as zero spent.
    - The file exists but cannot be trusted: truncated JSON (the classic
      crash-mid-`write_text` shape, now closed by `_record_request` writing
      atomically, but old data or a hand-edited file can still hit this),
      wrong permissions, or a directory sitting where the file should be.
      This used to read as zero spent too, on the theory that "it resets to
      today at zero, which is the conservative reading either way" -- it is
      not. Zero-spent is a FRESH allowance; it is the most permissive answer
      available, handed out precisely when the ledger can no longer prove
      what has already been charged. Reads as `_UNREADABLE` instead, which
      exceeds every `ceiling` this module is ever called with, so a caller
      that cannot prove its budget is unspent is refused until a human
      restores or removes the file.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return str(data.get("date", "")), int(data.get("requests", 0))
    except FileNotFoundError:
        return _today(), 0
    except (OSError, ValueError, TypeError):
        logger.error(
            "DeepSeek usage ledger at %s is unreadable; refusing further "
            "spend until it is restored or removed",
            path,
        )
        return _today(), _UNREADABLE


def spent_today(path: Path | None = None) -> int:
    """Requests already made today. Zero on a new day."""
    date, count = _read_budget(path or _BUDGET_PATH)
    return count if date == _today() else 0


def _record_request(path: Path) -> None:
    date, count = _read_budget(path)
    count = count + 1 if date == _today() else 1
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Write to a sibling temp file and rename over the target rather than
        # writing the path directly. `Path.write_text` is not atomic: a
        # container killed mid-write (a deploy, an OOM) can leave a truncated
        # file, which `_read_budget` used to treat as a fresh zero-spent
        # ledger -- silently erasing however much of the day's allowance had
        # already been recorded. `os.replace` is atomic on the same
        # filesystem, and the temp file lives next to the target so it always
        # is one.
        tmp = path.with_suffix(f"{path.suffix}.tmp-{os.getpid()}")
        tmp.write_text(
            json.dumps({"date": _today(), "requests": count}), encoding="utf-8"
        )
        os.replace(tmp, path)
    except OSError:
        # Losing a tick of the counter used to be dismissed as survivable --
        # true for an operator-triggered attribution batch, not for a button
        # a reader can press with nothing else bounding it. A write failure
        # here (full volume, read-only mount) means the NEXT read of this
        # ledger raises too, which now fails closed via `_UNREADABLE` rather
        # than quietly re-opening the budget on every call.
        logger.error("could not record DeepSeek usage to %s", path)


# --- per-account shares ----------------------------------------------------
#
# One ceiling per ledger is a spend backstop, not a fairness rule. With
# registration open, the first account to find a paid button can spend all of
# it, and everyone else -- the owner included -- is refused until midnight UTC.
# So a caller can also name an ``AccountBudget``: a second ledger, keyed by
# account, holding each account's own count for the day, checked before the
# request and charged alongside the global one. It keeps the global ledger's
# rules, for the global ledger's reasons: counted on disk so a restart cannot
# reset it, replaced atomically so a crash cannot truncate it, and a file that
# exists but cannot be read counts as EVERY account exhausted, never as every
# account fresh.


@dataclass(frozen=True)
class AccountBudget:
    """One account's share of a feature's daily allowance."""

    path: Path
    account: str
    ceiling: int


#: One file holds every account's count, so two requests finishing together
#: would otherwise both read the same counts and the second write would drop
#: the first one's tick. On the global ledger a lost tick is one request; here
#: it is somebody else's request. In-process is enough: the backend is a
#: single uvicorn process.
_ACCOUNT_LEDGER_LOCK = threading.Lock()


def _read_account_ledger(path: Path) -> tuple[str, dict[str, int]] | None:
    """The ledger's ``(date, {account: requests})``, or None when it exists
    but cannot be trusted. A missing file is a fresh day, exactly as for
    ``_read_budget``; anything else that fails is not."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        counts = data.get("accounts", {})
        if not isinstance(counts, dict):
            raise TypeError("accounts is not an object")
        return str(data.get("date", "")), {
            str(k): int(v) for k, v in counts.items()
        }
    except FileNotFoundError:
        return _today(), {}
    except (OSError, ValueError, TypeError, AttributeError):
        logger.error(
            "DeepSeek per-account ledger at %s is unreadable; refusing "
            "further spend by any account until it is restored or removed",
            path,
        )
        return None


def account_spent_today(path: Path, account: str) -> int:
    """Requests this account made today; ``_UNREADABLE`` if that is unknown."""
    ledger = _read_account_ledger(path)
    if ledger is None:
        return _UNREADABLE
    date, counts = ledger
    return counts.get(account, 0) if date == _today() else 0


def _record_account_request(budget: AccountBudget) -> None:
    with _ACCOUNT_LEDGER_LOCK:
        ledger = _read_account_ledger(budget.path)
        if ledger is None:
            # Left exactly as it is. Rewriting it from what little could be
            # read would erase the one signal that a human needs to look,
            # and hand every other account a fresh day.
            return
        date, counts = ledger
        if date != _today():
            counts = {}
        counts[budget.account] = counts.get(budget.account, 0) + 1
        try:
            budget.path.parent.mkdir(parents=True, exist_ok=True)
            # Same temp-and-rename as `_record_request`, for the same reason:
            # a truncated file is what a kill mid-write leaves behind.
            tmp = budget.path.with_suffix(
                f"{budget.path.suffix}.tmp-{os.getpid()}"
            )
            tmp.write_text(
                json.dumps({"date": _today(), "accounts": counts}),
                encoding="utf-8",
            )
            os.replace(tmp, budget.path)
        except OSError:
            # The previous file still stands (the rename never happened), so
            # this account is under-counted by one request. The global ledger
            # was charged first and still caps the total.
            logger.error("could not record DeepSeek usage to %s", budget.path)


def complete_json(
    prompt: str,
    *,
    system: str = "",
    max_tokens: int = 2000,
    temperature: float = 0.0,
    timeout: float = TIMEOUT_SECONDS,
    ceiling: int = DAILY_REQUEST_CEILING,
    budget_path: Path | None = None,
    account_budget: AccountBudget | None = None,
    transport: httpx.BaseTransport | None = None,
) -> Completion:
    """One JSON-mode completion.

    Retries exactly once, and only for failures that a second attempt can
    plausibly fix: a transport error, a 429, or a 5xx. A 400 or a 401 is
    re-sending a bad request with a bad key, which costs money on some APIs and
    buys nothing on any.

    ``temperature=0`` because this is an extraction task with a right answer --
    sampling only adds a chance of a different wrong one, and makes the same
    chapter attribute differently on two runs.

    ``account_budget``, when given, is the calling account's own share: it is
    refused before spending once that account's count reaches its ceiling,
    even with the global ledger still open, and every request the global
    ledger is charged for is charged to it too.
    """
    key = api_key()
    if key is None:
        raise DeepSeekNotConfigured(
            "DEEPSEEK_API_KEY is not set; attribution cannot run"
        )

    path = budget_path or _BUDGET_PATH
    used = spent_today(path)
    if used >= ceiling:
        raise DeepSeekBudgetExhausted(
            f"daily DeepSeek ceiling reached ({used}/{ceiling} requests); "
            "refusing to spend more today"
        )
    if account_budget is not None:
        mine = account_spent_today(account_budget.path, account_budget.account)
        if mine >= account_budget.ceiling:
            raise DeepSeekBudgetExhausted(
                f"this account's daily share is spent ({mine}/"
                f"{account_budget.ceiling} requests); refusing to spend more "
                "today"
            )

    messages: list[dict[str, str]] = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": MODEL,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "response_format": {"type": "json_object"},
        "stream": False,
    }

    last: Exception | None = None
    for attempt in (1, 2):
        try:
            with httpx.Client(
                timeout=timeout,
                # The whole point: a redirect must never carry this header to a
                # host that was not audited.
                follow_redirects=False,
                transport=transport,
            ) as client:
                response = client.post(
                    API_URL,
                    headers={
                        "Authorization": f"Bearer {key}",
                        "Content-Type": "application/json",
                    },
                    json=payload,
                )
        except httpx.HTTPError as exc:
            # str(exc) can embed the request URL but never the headers, so this
            # is safe to log; the key is not in it.
            last = DeepSeekError(f"DeepSeek request failed: {type(exc).__name__}")
            logger.warning("DeepSeek attempt %d transport error: %s", attempt, exc)
            if attempt == 1:
                time.sleep(2)
                continue
            raise last from exc

        # Paid for the moment it was answered, whatever the status.
        _record_request(path)
        if account_budget is not None:
            _record_account_request(account_budget)

        if response.status_code in (429, 500, 502, 503, 504) and attempt == 1:
            logger.warning("DeepSeek returned %d; retrying once", response.status_code)
            time.sleep(2)
            continue

        if 300 <= response.status_code < 400:
            # follow_redirects=False means httpx hands the 3xx back rather than
            # re-sending the Authorization header somewhere new. Name it
            # explicitly: falling through to the JSON parse would report this
            # as a malformed body and hide a redirect nobody expected.
            raise DeepSeekError(
                f"DeepSeek redirected (HTTP {response.status_code}); refusing to "
                "follow it with a bearer token"
            )

        if response.status_code >= 400:
            # Never echo the body: an auth error from this API quotes the key
            # back, masked by them but not by us, and this message reaches logs.
            raise DeepSeekError(
                f"DeepSeek returned HTTP {response.status_code}"
            )

        try:
            body = response.json()
            choice = body["choices"][0]["message"]["content"]
            usage = body.get("usage") or {}
            served_by = str(body.get("model") or MODEL)
            finish = body["choices"][0].get("finish_reason")
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise DeepSeekError(f"unexpected DeepSeek response shape: {exc}") from exc

        # A truncated answer is a FAILURE, not an answer. This model reasons
        # before it replies and bills that reasoning as output, so a budget set
        # for the visible answer alone is spent entirely on thinking and the
        # content comes back EMPTY with finish_reason "length". Six chapters
        # were attributed that way and every one was stored as a confident
        # "nobody spoke" -- paid for, marked ok, and wrong. Parsing whatever
        # arrives is exactly how that becomes invisible.
        if finish == "length":
            raise DeepSeekError(
                "answer truncated at max_tokens "
                f"({usage.get('completion_tokens', '?')} spent, "
                f"{(usage.get('completion_tokens_details') or {}).get('reasoning_tokens', 0)}"
                " of it on reasoning); raise max_tokens"
            )
        if not (choice or "").strip():
            raise DeepSeekError("model returned an empty answer")

        return Completion(
            content=choice,
            prompt_tokens=int(usage.get("prompt_tokens", 0)),
            completion_tokens=int(usage.get("completion_tokens", 0)),
            model=served_by,
        )

    raise last or DeepSeekError("DeepSeek request failed")
