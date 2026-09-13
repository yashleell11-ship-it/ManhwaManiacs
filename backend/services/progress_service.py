"""Source-native reading-position service (spec §3.3, §4.1).

Owns ``chapter_progress`` (per-profile reading position) and
``reading_sessions`` writes. Bookmarks live in ``services.bookmark_service``
(they are objects with tombstones, not a furthest-wins scalar); the three
bookmark methods below are delegating shims for existing callers.

The one rule that matters: **furthest-wins merge**. When a client pushes
progress for a chapter it already has a row for, the row moves *forward* only.
``last_read_at`` is a tie-break, never the deciding signal — last-write-wins
silently rewinds a reader that synced an older device.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from time import sleep
from typing import TYPE_CHECKING, Annotated, Any

from fastapi import Depends
from sqlalchemy import and_, select, tuple_, update
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from connectors.ids import fully_unquote
from core.connector_directory import descriptor_for_source
from core.content_rating import (
    TRACKER_RATING_MATURE,
    mature_tracker_case,
    resolve_mature_gate,
    resolve_tracker_rating,
)
from core.errors import AppError
from core.profile_context import ProfileContext, resolve_profile_context
from core.time_utils import clamp_client_clock, utcnow
from database.models import (
    ChapterProgress,
    FollowedSeries,
    ReadingSession,
    UpdateNotification,
)
from database.session import get_db
from services.browse_service import BrowseService, get_browse_service

if TYPE_CHECKING:  # pragma: no cover - typing only
    from services.bookmark_service import BookmarkService

#: Row-value ``IN`` chunk size for the batch prefetch. Matches the library's
#: (``followed_series_service._IN_CHUNK``): three bound parameters per key, so
#: 400 keys stay inside even the old 999-variable SQLite ceiling.
_IN_CHUNK = 300

#: Most reading time ONE push may claim, in seconds.
#:
#: The seconds are not just a counter: ``_apply_one`` back-dates the session it
#: writes by them, so an unbounded value does not merely inflate a total, it
#: invents *history* — one push claiming three days plants an active day three
#: days ago, bridges a broken streak and fills the daily chart with reading
#: that never happened. Both clients already cap their own delta far lower (300
#: s: ``reading_clock.dart``, ``reading-clock.ts``) and the phone's outbox sums
#: those deltas per chapter before it flushes, so an hour is well above any
#: honest push and a refusal to believe anything past it. It is the same number
#: as ``reading_stats_service.SESSION_SECONDS_CAP`` — which already declines to
#: count more than an hour out of a single session — deliberately: a value the
#: read path would throw away has no business back-dating a row on the way in.
#: Not imported from there, because that cap is a *reading* policy free to
#: change without touching what is stored.
MAX_PUSH_SECONDS = 3600

#: How far a client's clock may run BEHIND the server before its stamp stops
#: being evidence of anything.
#:
#: ``clamp_client_clock`` caps only the future, on purpose — a week-old offline
#: push must stay a week old — so the past has no floor at all. A client whose
#: ``last_read_at`` serializes as its DateTime *default* therefore writes a
#: 1970 ``chapter_progress`` row and a 1970 ``reading_sessions`` row, and
#: ``reading_stats_service._active_days`` scans the whole table rather than a
#: window: that one row owns ``first_session_at`` and the longest-streak run
#: for as long as the profile exists, and no later reading can dislodge it.
#:
#: The window is deliberately enormous rather than tight. Every stamp inside it
#: is believed verbatim, and the fallback for one outside it is ``now`` — which
#: is a lie in the other direction, so the floor must only ever catch a clock
#: that is broken rather than a device that was genuinely away. Nothing in this
#: database predates the 2026 baseline (``alembic/versions/0001_source_native``
#: wiped everything before it), so five years is already unreachable by any
#: honest push and is still far above the epoch, which is the value actually
#: observed. A device whose clock is merely a year or two wrong is believed;
#: that is the trade, and it is the right way round.
MAX_CLIENT_CLOCK_AGE = timedelta(days=5 * 365)

#: Seconds to tell a client to wait after a 503 ``db_busy``.
RETRY_AFTER_SECONDS = 2

#: Attempts a progress write gets before it gives up. Each one already waits up
#: to ``busy_timeout`` (5 s, ``database/session.py``) for SQLite's single
#: writer, so this is one more full budget, not a busy-loop.
_WRITE_ATTEMPTS = 2

#: Pause between those attempts. Long enough for the winning writer's commit to
#: land, short enough to be invisible next to the wait that preceded it.
_WRITE_RETRY_DELAY = 0.05


# ---------------------------------------------------------------------------
# Pure merge — unit-tested in isolation (tests/test_progress_merge.py)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ProgressInput:
    """A single progress push from a client."""

    source_id: str
    series_key: str
    chapter_key: str
    chapter_number: float | None = None
    last_page: int = 1
    page_count: int = 0
    scroll_offset_px: int = 0
    is_completed: bool = False
    last_read_at: datetime | None = None
    time_spent_seconds: int = 0


@dataclass(frozen=True)
class MergedProgress:
    """Result of merging a push against the stored row (or nothing)."""

    chapter_number: float | None
    last_page: int
    page_count: int
    scroll_offset_px: int
    is_completed: bool
    last_read_at: datetime
    completed_at: datetime | None
    time_spent_seconds: int
    advanced: bool  # did the stored position actually move forward?


def _believable_stamp(stamp: datetime | None, now: datetime) -> datetime:
    """The instant a push is taken to have happened.

    The client's own clock when it is plausible — that is the whole point of
    letting it stamp its writes (``routes.reader.ProgressRequest``) — capped
    into the present when it runs ahead (``clamp_client_clock``), and replaced
    by ``now`` when it sent nothing at all or a stamp older than
    :data:`MAX_CLIENT_CLOCK_AGE`.

    Applied here rather than at the route because this is where a stamp turns
    into stored history: ``merge_progress`` hands it to ``last_read_at``,
    ``started_at`` and the back-dated ``reading_sessions`` row, and every
    in-process caller (offline batches, the tests) reaches those through the
    service without passing a request model at all.
    """
    stamp = clamp_client_clock(stamp, now=now)
    if stamp is None or stamp < now - MAX_CLIENT_CLOCK_AGE:
        return now
    return stamp


def _position(chapter_number: float | None, last_page: int) -> tuple[float, int]:
    """The comparable position tuple.

    A ``chapter_number`` that is still NULL on *both* sides sorts to a constant,
    so the comparison falls through to ``last_page``. It is never a "sorts
    lowest" sentinel — see :func:`_resolve_number`.
    """
    return (chapter_number if chapter_number is not None else float("-inf"), last_page)


def _resolve_number(primary: float | None, fallback: float | None) -> float | None:
    """``primary``, or ``fallback`` when the client did not send a number.

    A ``chapter_progress`` row is keyed by ``chapter_key``, so its
    ``chapter_number`` is a constant *within* that row: a NULL means "the client
    did not send one", never "an earlier chapter". Treating NULL as ``-inf``
    broke the merge in both directions —

    * stored ``(5.0, page 3)`` + incoming ``(None, page 20)`` read as a move
      *backwards*, so a legitimate forward push was silently dropped; and
    * stored ``(None, page 40)`` + incoming ``(12.0, page 1)`` read as a move
      *forwards*, rewinding the reader to page 1 — the exact failure
      furthest-wins exists to prevent.

    Coalescing collapses both to "same chapter", which lets ``last_page``
    decide. It also means a push that supplies a number the stored row lacks
    upgrades it: strictly more information, and not a rewind.
    """
    return primary if primary is not None else fallback


def _credited_seconds(
    stored: MergedProgress | None,
    incoming: ProgressInput,
    incoming_read_at: datetime,
) -> int:
    """The seconds this push may ADD to the chapter's stored total.

    ``time_spent_seconds`` is a delta — the time since *this client's* previous
    push — and it arrives with no id of its own, so two rules stand between it
    and the ledger.

    **A delta is believed once.** The phone deletes an outbox row only after
    the 2xx, so a lost response, a kill mid-flush, or two flushes overlapping
    re-send the identical row, and ``stored + incoming`` bills those minutes
    again every time it happens. The device's own ``last_read_at`` is the only
    idempotency key on the wire, and a replay carries exactly the stamp the row
    already recorded — so a push whose clock is not strictly newer than
    ``stored.last_read_at`` contributes no time. The position merge below still
    runs on it: furthest-wins was always idempotent, and this only refuses to
    pay twice.

    **A delta is bounded** (:data:`MAX_PUSH_SECONDS`) — see there for why an
    unbounded one is a history-rewriting bug rather than a large number.
    """
    if incoming.time_spent_seconds <= 0:
        return 0
    if stored is not None and incoming_read_at <= stored.last_read_at:
        return 0
    return min(MAX_PUSH_SECONDS, incoming.time_spent_seconds)


def merge_progress(
    stored: MergedProgress | None,
    incoming: ProgressInput,
    *,
    now: datetime | None = None,
) -> MergedProgress:
    """Furthest-wins merge (spec §3.3).

    * Position ``(chapter_number, last_page)`` only ever moves forward.
    * ``last_read_at`` decides *only* when the position tuple is equal, and is
      the client's own stamp only as far as :func:`_believable_stamp` will go.
    * ``is_completed`` is sticky — once true it stays true; ``completed_at`` is
      stamped the first time it becomes true and never moved.
    * ``time_spent_seconds`` accumulates, by whatever
      :func:`_credited_seconds` will believe of this push.
    """
    now = now or utcnow()
    incoming_read_at = _believable_stamp(incoming.last_read_at, now)
    credited = _credited_seconds(stored, incoming, incoming_read_at)

    if stored is None:
        completed_at = now if incoming.is_completed else None
        return MergedProgress(
            chapter_number=incoming.chapter_number,
            last_page=max(1, incoming.last_page),
            page_count=max(0, incoming.page_count),
            scroll_offset_px=max(0, incoming.scroll_offset_px),
            is_completed=bool(incoming.is_completed),
            last_read_at=incoming_read_at,
            completed_at=completed_at,
            time_spent_seconds=credited,
            advanced=True,
        )

    # Coalesce across the pair before comparing: within one chapter_key the
    # number is a constant, so a NULL on either side must not decide the
    # ordering. See _resolve_number.
    incoming_number = _resolve_number(incoming.chapter_number, stored.chapter_number)
    stored_number = _resolve_number(stored.chapter_number, incoming.chapter_number)
    stored_pos = _position(stored_number, stored.last_page)
    incoming_pos = _position(incoming_number, incoming.last_page)

    is_completed = stored.is_completed or bool(incoming.is_completed)
    completed_at = stored.completed_at
    if is_completed and completed_at is None:
        completed_at = incoming_read_at if incoming.is_completed else now
    time_spent = stored.time_spent_seconds + credited
    # last_read_at always advances to the most recent real read.
    last_read_at = max(stored.last_read_at, incoming_read_at)

    if incoming_pos > stored_pos:
        # Genuine forward movement — take the incoming position + its snapshots.
        return MergedProgress(
            chapter_number=incoming_number,
            last_page=max(1, incoming.last_page),
            page_count=max(stored.page_count, incoming.page_count),
            scroll_offset_px=max(0, incoming.scroll_offset_px),
            is_completed=is_completed,
            last_read_at=last_read_at,
            completed_at=completed_at,
            time_spent_seconds=time_spent,
            advanced=True,
        )

    if incoming_pos == stored_pos and incoming_read_at > stored.last_read_at:
        # Tie on position — the more recent push wins scroll offset only.
        return MergedProgress(
            chapter_number=stored_number,
            last_page=stored.last_page,
            page_count=max(stored.page_count, incoming.page_count),
            scroll_offset_px=max(0, incoming.scroll_offset_px),
            is_completed=is_completed,
            last_read_at=last_read_at,
            completed_at=completed_at,
            time_spent_seconds=time_spent,
            advanced=False,
        )

    # Incoming is behind (or a stale tie): never rewind. Only sticky flags and
    # bookkeeping fields may change.
    return MergedProgress(
        chapter_number=stored_number,
        last_page=stored.last_page,
        page_count=max(stored.page_count, incoming.page_count),
        scroll_offset_px=stored.scroll_offset_px,
        is_completed=is_completed,
        last_read_at=last_read_at,
        completed_at=completed_at,
        time_spent_seconds=time_spent,
        advanced=False,
    )


def _row_to_merged(row: ChapterProgress) -> MergedProgress:
    return MergedProgress(
        chapter_number=row.chapter_number,
        last_page=row.last_page,
        page_count=row.page_count,
        scroll_offset_px=row.scroll_offset_px,
        is_completed=bool(row.is_completed),
        last_read_at=row.last_read_at or row.started_at or utcnow(),
        completed_at=row.completed_at,
        time_spent_seconds=row.time_spent_seconds,
        advanced=False,
    )


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------


class ProgressService:
    def __init__(
        self,
        db: Session,
        browse: BrowseService | None = None,
        *,
        user_id: int | None = None,
        profile_id: int | None = None,
    ) -> None:
        """``browse`` carries this caller's resolved 18+ gate for the source
        check the single-series read makes.

        Optional in signature, never in effect: absent, one is built lazily
        from this service's own ``(user_id, profile_id)`` through
        ``resolve_mature_gate`` — the same resolution ``get_browse_service``
        performs — so there is no way to construct a service whose reads are
        ungated, which is the invariant ``OcrIngestService`` reaches by making
        the argument required. Self-building is the stronger form of it here:
        a required argument can still be handed a BrowseService carrying some
        *other* profile's gate, and this one cannot disagree with the gate the
        rest of the service resolves.
        """
        self._db = db
        self._browse_service = browse
        self._user_id = user_id
        self._profile_id = profile_id
        # Resolved once per request: the gate is a property of the (user,
        # profile) pair and cannot change mid-request.
        self._gate_cache: bool | None = None

    # --- progress ----------------------------------------------------------

    def _require_owner(self) -> tuple[int, int | None]:
        if self._user_id is None:
            raise AppError(
                "Authentication is required to save reading progress.",
                code="auth_required",
                status_code=401,
            )
        return self._user_id, self._profile_id

    def _require_profile(self) -> tuple[int, int]:
        """Owner + active profile, for the write paths.

        ``profile_id`` is NOT NULL on chapter_progress / reading_sessions, so a write from the unscoped bucket (an account that
        owns no profiles, which ``require_profile_context`` lets through) is an
        IntegrityError 500. Return the documented 400 the clients already
        handle instead.
        """
        user_id, profile_id = self._require_owner()
        if profile_id is None:
            raise AppError(
                "An active profile is required for this action.",
                code="profile_required",
                status_code=400,
            )
        return user_id, profile_id

    def _scope(self, stmt):
        stmt = stmt.where(ChapterProgress.user_id == self._user_id)
        if self._profile_id is None:
            stmt = stmt.where(ChapterProgress.profile_id.is_(None))
        else:
            stmt = stmt.where(ChapterProgress.profile_id == self._profile_id)
        return stmt

    # --- the 18+ gate ------------------------------------------------------
    #
    # ``chapter_progress`` rows are already scoped to (user_id, profile_id), so
    # nothing below is about one profile reading another's. It is about the
    # profile's OWN mature series: with the 18+ toggle shut, browse, the
    # manifest, Continue Reading, Bookmarks and the statistics screen all hide
    # a series that these two reads happily described. A gate that holds
    # everywhere but the history screen is not a gate.

    def _browse(self) -> BrowseService:
        if self._browse_service is None:
            self._browse_service = BrowseService(
                mature_enabled=self._gate_open(),
                db=self._db,
                user_id=self._user_id,
                profile_id=self._profile_id,
            )
        return self._browse_service

    def _gate_open(self) -> bool:
        """This caller's own 18+ gate.

        Resolved from the (user, profile) pair via ``resolve_mature_gate`` —
        the single resolution path. Reading
        ``get_settings().mature_content_enabled`` in the service layer instead
        is what once made the in-app toggle inert.
        """
        if self._gate_cache is None:
            self._gate_cache = resolve_mature_gate(
                self._db, self._profile_id, self._user_id
            )
        return self._gate_cache

    def _follow_join(self, stmt):
        """Outer-join the follow row a progress row's rating is resolved from.

        OUTER, unlike ``FollowedSeriesService.continue_reading``'s inner join,
        and the difference is the point: that strip is a view of the *library*,
        so a series this profile does not follow has no business in it. History
        is the profile's own record — unfollowing a series is not a rating, and
        an inner join here would erase the history of everything the reader
        ever stopped following. ``uq_followed_series`` guarantees at most one
        match, so the join can never fan a progress row out into duplicates.
        """
        return stmt.outerjoin(
            FollowedSeries,
            and_(
                FollowedSeries.user_id == ChapterProgress.user_id,
                FollowedSeries.profile_id == ChapterProgress.profile_id,
                FollowedSeries.source_id == ChapterProgress.source_id,
                FollowedSeries.series_key == ChapterProgress.series_key,
            ),
        )

    def _mature_case(self):
        """1 when a progress row's series is 18+ for this profile, else 0.

        The rule is :func:`core.content_rating.mature_tracker_case` — shared
        outright, rather than copied verbatim from
        ``reading_stats_service._progress_mature_case`` as it once was, so the
        history list and the statistics screen cannot disagree about what is
        adult. All this names is the column the source's maturity is read from.
        """
        return mature_tracker_case(ChapterProgress.source_id)

    def _series_visible(self, source_id: str, series_key: str) -> bool:
        """Whether ONE series' stored positions may be shown to this profile.

        The *source* gate is ``ensure_visible``'s job and has already run by
        the time this is called; what is left is the series' own rating, which
        the source gate alone misses — an 18+ series on a general source like
        mangadex, flagged by ``mature_override`` or by the ``content_rating``
        captured at follow time.

        No follow row leaves no rating signal but the source's own, which
        ``ensure_visible`` has already cleared: unknown is deliberately not
        folded into mature (see :func:`resolve_tracker_rating`), so the profile
        keeps its own history for a series it stopped following. This is
        :meth:`_mature_case` resolved in Python because it answers for a single
        series — calling the authority directly for one row is one fewer place
        for the two to drift.
        """
        if self._gate_open():
            return True
        stmt = select(FollowedSeries).where(
            FollowedSeries.user_id == self._user_id,
            FollowedSeries.source_id == source_id,
            FollowedSeries.series_key == series_key,
        )
        # Unconditional profile predicate, exactly as ``_scope`` reads it: the
        # unscoped bucket is a bucket, not a wildcard over the account.
        stmt = (
            stmt.where(FollowedSeries.profile_id.is_(None))
            if self._profile_id is None
            else stmt.where(FollowedSeries.profile_id == self._profile_id)
        )
        follow = self._db.execute(stmt).scalar_one_or_none()
        if follow is None:
            return True
        return (
            resolve_tracker_rating(follow, descriptor_for_source(source_id))
            != TRACKER_RATING_MATURE
        )

    def _prefetch(
        self, payloads: list[ProgressInput]
    ) -> dict[tuple[str, str, str], ChapterProgress]:
        """Every existing row a batch will touch, in one statement per chunk.

        ``_apply_one`` looked its row up with its own SELECT, which is fine for
        one push and an N+1 for a sync: the route accepts 200 items, so an
        offline catch-up issued 200 point queries before it wrote anything.
        Row-value ``IN`` collapses them, chunked exactly like the library's
        lookups so the statement stays inside SQLite's variable ceiling.
        """
        keys = [
            (
                p.source_id,
                fully_unquote(p.series_key),
                fully_unquote(p.chapter_key),
            )
            for p in payloads
        ]
        found: dict[tuple[str, str, str], ChapterProgress] = {}
        target = tuple_(
            ChapterProgress.source_id,
            ChapterProgress.series_key,
            ChapterProgress.chapter_key,
        )
        for start in range(0, len(keys), _IN_CHUNK):
            chunk = keys[start : start + _IN_CHUNK]
            if not chunk:
                continue
            rows = self._db.execute(
                self._scope(select(ChapterProgress).where(target.in_(chunk)))
            ).scalars().all()
            for row in rows:
                found[(row.source_id, row.series_key, row.chapter_key)] = row
        return found

    def _apply_one(
        self,
        payload: ProgressInput,
        *,
        prefetched: dict[tuple[str, str, str], ChapterProgress] | None = None,
    ) -> tuple[ChapterProgress, MergedProgress]:
        """Merge one push into the session WITHOUT committing.

        Ends with a ``flush`` so a later payload in the same batch that targets
        the same chapter sees the pending row (the per-item-commit behaviour it
        replaces provided that visibility implicitly).

        ``prefetched`` is the batch path's shared row map (see ``_prefetch``).
        It is READ AND WRITTEN: a row this call creates is put back into it, so
        a second payload for the same chapter later in the batch merges onto
        the same object rather than inserting a duplicate — exactly what the
        per-item SELECT + flush used to guarantee.
        """
        user_id, profile_id = self._require_profile()
        source_id = payload.source_id
        series_key = fully_unquote(payload.series_key)
        chapter_key = fully_unquote(payload.chapter_key)

        if prefetched is not None:
            row = prefetched.get((source_id, series_key, chapter_key))
        else:
            row = self._db.execute(
                self._scope(
                    select(ChapterProgress).where(
                        ChapterProgress.source_id == source_id,
                        ChapterProgress.series_key == series_key,
                        ChapterProgress.chapter_key == chapter_key,
                    )
                )
            ).scalar_one_or_none()

        if row is None:
            merged = merge_progress(None, payload)
            row, created = self._claim_row(
                user_id, profile_id, source_id, series_key, chapter_key, merged
            )
            if prefetched is not None:
                prefetched[(source_id, series_key, chapter_key)] = row
        else:
            created = False

        # Captured BEFORE the row is mutated below: a session records only the
        # stretch this push covered, not the chapter's whole history. A row
        # this call created has no history at all, and already holds `merged`.
        if created:
            previous_last_page = 0
            previous_time_spent = 0
        else:
            merged = merge_progress(_row_to_merged(row), payload)
            previous_last_page = row.last_page
            previous_time_spent = row.time_spent_seconds

        row.chapter_number = merged.chapter_number
        row.last_page = merged.last_page
        row.page_count = merged.page_count
        row.scroll_offset_px = merged.scroll_offset_px
        row.is_completed = merged.is_completed
        row.last_read_at = merged.last_read_at
        row.completed_at = merged.completed_at
        row.time_spent_seconds = merged.time_spent_seconds

        self._db.flush()

        # A reading session per *advance*, or per push that carried reading
        # time. Clients ping progress repeatedly for the same page (autosave,
        # scroll settle), and one row per ping would bury the real history in
        # noise — but such a ping reports no seconds either, so `elapsed` sorts
        # it out without the collateral damage `advanced` alone caused: under
        # furthest-wins NOTHING advances while a chapter is re-read, so a
        # chapter read a second time charged its minutes to `chapter_progress`
        # and wrote nothing here at all. The statistics screen then reported no
        # reading, no time and a broken streak for a day spent reading, and the
        # live table showed the shape of it — every session zero-length,
        # because only the pushes that also moved the position were ever
        # recorded.
        elapsed = max(0, merged.time_spent_seconds - previous_time_spent)
        if merged.advanced or elapsed:
            if merged.advanced:
                # +1 because the previous position was already read: resuming
                # at page 5 and reaching 8 is three pages (6, 7, 8), not four.
                # A first push has no previous position, so it starts at page 1.
                start_page = previous_last_page + 1 if previous_last_page else 1
                end_page = merged.last_page
                pages_read = None  # the inclusive span
            else:
                # Time on ground the row already covers. The page the client
                # named is the honest span — one page re-read — and when it is
                # the page the row already points at, nothing new was read at
                # all, so the session carries the time and no pages.
                start_page = end_page = max(1, payload.last_page)
                pages_read = 0 if payload.last_page == previous_last_page else 1
            ended_at = merged.last_read_at
            self.record_session(
                source_id=source_id,
                series_key=series_key,
                chapter_key=chapter_key,
                chapter_number=merged.chapter_number,
                start_page=start_page,
                end_page=end_page,
                pages_read=pages_read,
                # Only claim a start time the client actually reported. Without
                # elapsed time, a zero-length session is honest; inventing a
                # duration would corrupt the time-read statistic outright.
                started_at=(
                    ended_at - timedelta(seconds=elapsed) if elapsed else ended_at
                ),
                ended_at=ended_at,
                commit=False,
            )

        self._clear_update_notification(
            user_id, profile_id, source_id, series_key, chapter_key
        )

        return row, merged

    def _clear_update_notification(
        self,
        user_id: int,
        profile_id: int,
        source_id: str,
        series_key: str,
        chapter_key: str,
    ) -> None:
        """Mark this chapter's "new chapter" notification read, if there is one.

        Reading a chapter IS the acknowledgement. Before this, ``is_read`` moved
        only when someone pressed a button, reachable from the two routes in
        ``routes/updates.py`` and nowhere else -- so the unread badge counted
        chapters that had already been read, and a counter that lies is one the
        reader stops looking at. That badge is the only thing in the product
        whose job is to bring someone back.

        Runs inside the caller's transaction, so a rolled-back progress push
        cannot leave a notification wrongly cleared.

        Scoped to (user_id, profile_id): two profiles following the same series
        each get their own notification row, and one of them reading the chapter
        must not clear the other's. That is the same isolation
        ``chapter_progress`` has, and this box currently has two profiles
        following the same novel, so the wrong query here would be visible.

        ``chapter_key`` arrives already ``fully_unquote``d, which is why
        ``update_service`` canonicalises the key it writes: the two spellings
        would compare unequal and this UPDATE would silently match nothing.
        """
        self._db.execute(
            update(UpdateNotification)
            .where(
                UpdateNotification.user_id == user_id,
                UpdateNotification.profile_id == profile_id,
                UpdateNotification.source_id == source_id,
                UpdateNotification.series_key == series_key,
                UpdateNotification.chapter_key == chapter_key,
                UpdateNotification.is_read.is_(False),
            )
            .values(is_read=True)
        )

    def _claim_row(
        self,
        user_id: int,
        profile_id: int,
        source_id: str,
        series_key: str,
        chapter_key: str,
        merged: MergedProgress,
    ) -> tuple[ChapterProgress, bool]:
        """Insert this chapter's first row, or hand back whoever beat us to it.

        Returns ``(row, created)``; ``created`` False means another connection
        inserted the same chapter between our SELECT and ours, so the caller
        must redo its merge against THAT row.

        The lookup ran outside SQLite's write lock — pysqlite runs a SELECT in
        autocommit and the INSERT only takes the lock at flush — so two first
        pushes for one chapter (the phone flushing its outbox while the web
        reader live-pushes, or one autosave firing twice) can both see "no row"
        and both insert. A plain ORM insert makes the loser trip
        ``uq_chapter_progress``, and an unhandled IntegrityError is a 500 for a
        push whose entire job was to merge.

        The violation is therefore prevented rather than caught: ``ON CONFLICT
        DO NOTHING`` leaves the transaction intact, and reading the row back
        gives the loser the winner's row to merge onto — what it would have
        done had its SELECT run a moment later. Catching the IntegrityError
        instead would need a SAVEPOINT to keep the session usable, and pysqlite
        emits no BEGIN of its own, so releasing that savepoint would commit a
        batch's earlier items behind its back.

        ``RETURNING`` keeps the winning path at ONE statement, which is what an
        insert cost before this: the row comes back as a live ORM object, and
        only the loser — who has to see somebody else's row anyway — pays for a
        SELECT.
        """
        inserted = self._db.scalars(
            sqlite_insert(ChapterProgress)
            .values(
                user_id=user_id,
                profile_id=profile_id,
                source_id=source_id,
                series_key=series_key,
                chapter_key=chapter_key,
                chapter_number=merged.chapter_number,
                last_page=merged.last_page,
                page_count=merged.page_count,
                scroll_offset_px=merged.scroll_offset_px,
                is_completed=merged.is_completed,
                started_at=merged.last_read_at,
                last_read_at=merged.last_read_at,
                completed_at=merged.completed_at,
                time_spent_seconds=merged.time_spent_seconds,
            )
            .on_conflict_do_nothing(
                index_elements=[
                    ChapterProgress.user_id,
                    ChapterProgress.profile_id,
                    ChapterProgress.source_id,
                    ChapterProgress.series_key,
                    ChapterProgress.chapter_key,
                ]
            )
            .returning(ChapterProgress)
        ).one_or_none()
        if inserted is not None:
            return inserted, True
        row = self._db.execute(
            self._scope(
                select(ChapterProgress).where(
                    ChapterProgress.source_id == source_id,
                    ChapterProgress.series_key == series_key,
                    ChapterProgress.chapter_key == chapter_key,
                )
            )
        ).scalar_one()
        return row, False

    def _write(self, apply: Callable[[], dict[str, Any]]) -> dict[str, Any]:
        """Run one write unit, retrying once if SQLite's writer is busy.

        A progress write that raises ``database is locked`` has already waited
        out ``busy_timeout`` (5 s) behind the update sweep or someone's 200-item
        offline flush. Left alone it reaches ``core.errors``'s catch-all as a
        500 ``internal_error``: the reader's keep-alive is dropped, and the
        client cannot tell "come back in a second" from "this request will
        never work" — so every device in the busy window retries at whatever
        cadence it feels like, at the writer that is already saturated.

        So: one more attempt (the lock is transient by definition), and if it
        is still held, a 503 the clients can read, carrying the wait in
        ``details`` for the ``Retry-After`` the route attaches. Rolling back
        first is not optional — SQLAlchemy refuses every later statement on a
        session whose flush failed.
        """
        for attempt in range(_WRITE_ATTEMPTS):
            try:
                return apply()
            except OperationalError as exc:
                if "locked" not in str(exc.orig or exc).lower():
                    raise
                self._db.rollback()
                if attempt + 1 == _WRITE_ATTEMPTS:
                    raise AppError(
                        "The database is busy. Try again in a moment.",
                        code="db_busy",
                        status_code=503,
                        details={"retry_after_seconds": RETRY_AFTER_SECONDS},
                    ) from exc
                sleep(_WRITE_RETRY_DELAY)
        raise AssertionError("unreachable: the last attempt returns or raises")

    def save_one(self, payload: ProgressInput) -> dict[str, Any]:
        def apply() -> dict[str, Any]:
            row, merged = self._apply_one(payload)
            self._db.commit()
            return {**self._serialize(row), "advanced": merged.advanced}

        return self._write(apply)

    def save_batch(self, payloads: list[ProgressInput]) -> dict[str, Any]:
        """Offline-sync catch-up, applied in ONE transaction.

        This used to be ``[save_one(p) for p in payloads]`` — N separate
        write-lock acquire/commit(fsync) cycles against the single-writer
        SQLite for a single request, which let one large batch monopolise the
        writer (audit finding 12; the route also caps the batch length).
        """
        def apply() -> dict[str, Any]:
            # Prefetched inside, so a retry after a busy writer re-reads rather
            # than merging onto rows a rollback has already detached.
            prefetched = self._prefetch(payloads)
            applied = [self._apply_one(p, prefetched=prefetched) for p in payloads]
            self._db.commit()
            results = []
            for row, merged in applied:
                # No refresh(). The session is created with expire_on_commit=False
                # and _apply_one flushes, so every column -- including the
                # Python-side defaults -- is already loaded on the object. The
                # refresh was one extra SELECT per item, 200 of them for a full
                # batch, to re-read values this process had just written.
                results.append({**self._serialize(row), "advanced": merged.advanced})
            return {
                "saved": len(results),
                "advanced": sum(1 for r in results if r.get("advanced")),
                "items": results,
            }

        return self._write(apply)

    def get_series_progress(
        self, source_id: str, series_key: str
    ) -> list[dict[str, Any]]:
        """Every stored chapter position for ONE series, for this profile.

        Gated in the two steps every read that names a source takes, in this
        order:

        * the *source* gate — ``ensure_visible``, the same call
          ``ReaderService.manifest`` makes one route above, so a mature source
          answers here byte-identically to how it answers there: 404
          ``source_not_found``, never 403, because off-limits has to be
          indistinguishable from absent;
        * the *series* gate — ``_series_visible``, because a series that is 18+
          on a *general* source is something no source-level check can see.

        A withheld series returns the empty list rather than raising: that is
        already this endpoint's answer for a series the profile has never
        opened, and it is the same answer for the same reason.
        ``OcrIngestService.coverage`` resolves the identical pair the identical
        way.
        """
        self._require_owner()
        series_key = fully_unquote(series_key)
        self._browse().ensure_visible(source_id)
        if not self._series_visible(source_id, series_key):
            return []
        rows = self._db.execute(
            self._scope(
                select(ChapterProgress)
                .where(
                    ChapterProgress.source_id == source_id,
                    ChapterProgress.series_key == series_key,
                )
                .order_by(ChapterProgress.chapter_number)
            )
        ).scalars().all()
        return [self._serialize(r) for r in rows]

    def reading_history(
        self, *, limit: int = 50, offset: int = 0
    ) -> list[dict[str, Any]]:
        """The profile's own reading history, newest first.

        Spans sources, so it cannot call ``ensure_visible`` the way the
        single-series read does — that raises, and one deregistered or
        non-browsable source in a reader's history would take the whole list
        down with it. The source's maturity is therefore folded into the rating
        instead (``_mature_case``'s fall-through), which is how every other
        cross-source listing of stored rows resolves it: ``list_bookmarks``,
        the statistics screen.

        The join is load-bearing rather than decorative — with no
        ``followed_series`` row in the statement there is nothing to resolve a
        rating against, which is exactly why this read had no gate. And the
        filter is SQL rather than a Python pass afterwards so ``limit`` and
        ``offset`` still count the rows the caller can actually see: dropping
        them after the page is cut hands back short pages, and a client paging
        on ``offset`` then steps clean over the removed rows and loses the tail
        of its own history.
        """
        self._require_owner()
        stmt = self._scope(select(ChapterProgress))
        if not self._gate_open():
            # Joined only when the gate is shut. The other 99% of requests are
            # an open gate with nothing to resolve, and an unconditional join
            # would make every one of them pay an index probe per progress row
            # (the cost ``ReadingStatsService._sessions`` measured).
            stmt = self._follow_join(stmt).where(self._mature_case() == 0)
        rows = self._db.execute(
            stmt.order_by(ChapterProgress.last_read_at.desc())
            .limit(limit)
            .offset(offset)
        ).scalars().all()
        return [self._serialize(r) for r in rows]

    # --- bookmarks -------------------------------------------------------
    #
    # Bookmarks moved to ``services.bookmark_service`` when they gained exact
    # positions and object-sync semantics (design 2026-09-05-smart-bookmarks).
    # They are NOT progress: progress is an automatic furthest-wins scalar,
    # a bookmark is a deliberate user-created object with a client id and a
    # tombstone, and the two merges are opposites. These three delegating
    # methods remain so existing callers keep working; new code should take a
    # ``BookmarkService`` directly.

    def _bookmarks(self) -> "BookmarkService":
        from services.bookmark_service import BookmarkService

        return BookmarkService(
            self._db, user_id=self._user_id, profile_id=self._profile_id
        )

    def add_bookmark(self, **kwargs: Any) -> dict[str, Any]:
        """``page=`` is translated, not dropped.

        The pre-design signature took a 1-based ``page``; that column is now
        ``anchor_index`` (still 1-based, still the page for manga), so a
        legacy caller keeps working and lands at offset 0.0 of the page it
        named — the same back-compat rule the migration applies to stored
        rows.
        """
        page = kwargs.pop("page", None)
        if page is not None:
            kwargs.setdefault("anchor_index", int(page))
        return self._bookmarks().add_bookmark(**kwargs)

    def list_bookmarks(self, **kwargs: Any) -> list[dict[str, Any]]:
        return self._bookmarks().list_bookmarks(**kwargs)

    def delete_bookmark(self, bookmark_id: int) -> None:
        self._bookmarks().delete_bookmark(bookmark_id)

    # --- reading sessions ------------------------------------------------

    def record_session(
        self,
        *,
        source_id: str,
        series_key: str,
        chapter_key: str,
        chapter_number: float | None,
        start_page: int,
        end_page: int,
        pages_read: int | None = None,
        started_at: datetime | None = None,
        ended_at: datetime | None = None,
        commit: bool = True,
    ) -> None:
        """``pages_read`` defaults to the inclusive span the two pages describe.
        It is passed explicitly for a session that covered no new ground — the
        reader spent the time on the page the row already points at — because
        an inclusive span can never say zero.
        """
        user_id, profile_id = self._require_profile()
        if pages_read is None:
            pages_read = max(0, end_page - start_page + 1)
        row = ReadingSession(
            user_id=user_id,
            profile_id=profile_id,
            source_id=source_id,
            series_key=fully_unquote(series_key),
            chapter_key=fully_unquote(chapter_key),
            chapter_number=chapter_number,
            start_page=max(1, start_page),
            end_page=max(1, end_page),
            pages_read=pages_read,
            started_at=started_at or utcnow(),
            ended_at=ended_at,
        )
        self._db.add(row)
        # `commit=False` lets a caller already inside a transaction append a
        # session without breaking it — save_batch deliberately applies the
        # whole batch in ONE commit (audit finding 12: per-item commits let a
        # single large batch monopolise SQLite's single writer).
        if commit:
            self._db.commit()

    # --- serialization -------------------------------------------------

    @staticmethod
    def _serialize(row: ChapterProgress) -> dict[str, Any]:
        return {
            "id": row.id,
            "source_id": row.source_id,
            "series_key": row.series_key,
            "chapter_key": row.chapter_key,
            "chapter_number": row.chapter_number,
            "last_page": row.last_page,
            "page_count": row.page_count,
            "scroll_offset_px": row.scroll_offset_px,
            "is_completed": bool(row.is_completed),
            "started_at": _iso(row.started_at),
            "last_read_at": _iso(row.last_read_at),
            "completed_at": _iso(row.completed_at),
            "time_spent_seconds": row.time_spent_seconds,
        }


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value is not None else None


def get_progress_service(
    db: Annotated[Session, Depends(get_db)],
    browse: Annotated[BrowseService, Depends(get_browse_service)],
    ctx: Annotated[ProfileContext, Depends(resolve_profile_context)],
) -> ProgressService:
    # ``browse`` already carries this request's resolved 18+ gate, so the read
    # paths reuse it rather than resolving the same (user, profile) twice.
    return ProgressService(
        db, browse, user_id=ctx.user_id, profile_id=ctx.profile_id
    )
