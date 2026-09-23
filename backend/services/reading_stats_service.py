"""Reading statistics over ``reading_sessions`` (spec §3.3, §5.2).

``reading_sessions`` has been written by :mod:`services.progress_service` since
the source-native rebuild and read by nothing, so every read the owner has ever
done was recorded and thrown away. This module is the reader: it turns those
rows into the numbers behind ``GET /library/statistics``.

Three rules shape everything here.

**Scope.** Every statement filters ``(user_id, profile_id)`` -- see
:meth:`_session_scope`. A statement that filters on ``user_id`` alone reports
one profile the account's *other* profiles' reading, which is the exact
cross-profile leak this project has already shipped and fixed once.

**The 18+ gate.** A session row carries no maturity signal of its own, so the
rating is resolved by joining the profile's ``followed_series`` row -- the same
signals :func:`core.content_rating.resolve_tracker_rating` resolves in Python,
mirrored into SQL by :meth:`_mature_case` so the filter can run inside the
aggregate instead of pulling rows into memory. The join is a LEFT join on
purpose: unfollowing a series must not erase its history from the totals, it
only removes the per-series signal (which then falls back to the source's own
maturity, exactly as rule 3 of ``resolve_tracker_rating`` does). When the gate
is closed a mature series is excluded from *every* number, not just from the
named breakdowns -- a total that silently includes 800 invisible pages tells the
reader that hidden content exists, which is the thing the gate is for.

**Time.** Every timestamp column in this project is a naive SQLite ``DATETIME``
holding UTC. "Day" is therefore not a property of the data; it is a choice the
caller makes. Callers pass ``tz_offset_minutes`` and days are bucketed at that
fixed offset from UTC (``strftime(..., '+330 minutes')``), with the offset
echoed back in the payload so a chart can label its axis honestly. A fixed
offset means no DST transitions -- for a single-household app that is the right
trade against carrying a tz database, but it is a deliberate one.

**The roll-up.** ``reading_sessions`` is append-only and never pruned, and one
of the questions here is asked of the WHOLE of it: the streak needs every day
the profile ever read on, so :meth:`ReadingStatsService._active_days` grouped
the entire history under ``strftime`` -- unindexable, sorted into a temp
b-tree, and slower after every chapter ever read. ``reading_day_stats`` stores
that answer, one row per CLOSED day, and this module is both its reader and
its writer: nothing in the write path maintains it, so a statistics read
materialises the days that have closed since the last one
(:meth:`ReadingStatsService._materialise`) and then answers from what it
stored. Today is deliberately never materialised -- it is still accumulating
-- so the streak is the stored days plus today's, and today's comes from the
sessions under a range predicate that touches nothing older.

The reader believes those rows only under the three conditions in
:meth:`ReadingStatsService._rollup_usable`, and it proves the third of them on
every read rather than assuming it: sessions stay the record of truth and the
roll-up must be shown to account for every one of them before it is allowed to
answer.

Everything else still comes from the sessions. The windowed roll-ups are
bounded by ``days`` already, and totals count DISTINCT chapters and series,
which do not add across days and so cannot come out of a per-day summary at
all -- :meth:`ReadingStatsService._totals` therefore still reads the whole
history, and fixing that needs a table shaped differently from this one, not
a wider version of it.

Measured over 14,600 sessions across 730 days: the streak went 5.3 ms to
1.6 ms, and ``build(30)`` 23.2 ms to 19.2 ms -- of which ``_totals`` is now
11.1 ms and is the whole of what is left of this finding.
"""

from __future__ import annotations

from datetime import date, datetime, time, timedelta
from typing import Any

from sqlalchemy import (
    Integer,
    and_,
    delete,
    distinct,
    func,
    insert,
    literal,
    select,
    tuple_,
)
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from core.connector_directory import descriptors_by_source
from core.content_rating import mature_tracker_case
from core.time_utils import utcnow
from database.models import (
    ChapterProgress,
    FollowedSeries,
    ReadingDayStats,
    ReadingSession,
    SourceSeriesCache,
)

#: Longest span a single reading session may contribute to "time spent".
#: ``ended_at`` is written by the client when it stops reporting, so a chapter
#: left open on a locked phone overnight arrives as a nine-hour session. Nobody
#: reads one chapter for an hour; anything past this is a client that stopped
#: talking, not reading time, so it is clamped rather than believed. The cap is
#: published in the payload so a client can say "capped" instead of guessing.
SESSION_SECONDS_CAP = 3600

#: Separator used to fold a composite key into one string for
#: ``COUNT(DISTINCT ...)`` -- SQLite's DISTINCT takes a single expression.
#: ASCII unit-separator: connector keys are URL-ish (slashes, percent-escapes),
#: so a control character cannot collide with one and produce a false match.
_SEP = "\x1f"

_TOP_SOURCES = 8
_TOP_SERIES = 10
_RECENT_SESSIONS = 10

#: The offset from UTC that ``reading_day_stats.day`` is bucketed at, and the
#: only offset a request may read those rows at.
#:
#: A day is not a property of the data (see **Time** above) -- it is the
#: caller's ``tz_offset_minutes``. The roll-up has one ``day`` column and
#: nowhere to record which offset produced it, so writer and reader agree on
#: one offset here and a request at any other one falls back to the sessions
#: and gets the same numbers the slow way. UTC is the default because it is
#: the only offset the server can name without guessing, and it is what the
#: endpoint itself defaults to; a deployment whose clients all sit in one
#: timezone should set this to that offset and rebuild, which is the whole of
#: what it takes to make the roll-up answer for them.
#:
#: Changing this invalidates every stored row and the reader CANNOT notice:
#: its check counts sessions, and re-bucketing a day changes which row a
#: session is counted under, never how many there are. So run
#: :func:`backfill_reading_day_stats` in the same deploy that changes this
#: line -- it is the one edit here that a wrong answer follows silently from.
ROLLUP_TZ_OFFSET_MINUTES = 0

_ROLLUP_MODIFIER = f"{ROLLUP_TZ_OFFSET_MINUTES:+d} minutes"

#: How many closed days the reader re-derives when it catches the roll-up
#: short of a session (see :meth:`ReadingStatsService._materialise`).
#:
#: A session's ``started_at`` is the CLIENT's, not the server's: a phone that
#: read on the train and flushed when it found wifi inserts rows into days
#: that were closed and rolled up hours ago. The other way to handle that is
#: to re-derive only the days a session newer than the roll-up touched, which
#: is strictly less work -- and it is not available here: ``reading_day_stats``
#: has nowhere to record how new "newer" is (the revision that created it is
#: shipped, and adding a watermark column is a migration, not a patch). So the
#: reader re-derives a trailing window instead. A week is wider than any
#: same-session flush and is still ~1/500th of a two-year history; anything
#: later than that is caught by the session count in
#: :meth:`ReadingStatsService._rollup_counts_every_session` and repaired by a
#: full rebuild, which is why being wrong about this number costs time and
#: never correctness.
_REPAIR_DAYS = 7

#: ``reading_day_stats`` columns, in the order :func:`_closed_day_source`
#: selects them.
_ROLLUP_COLUMNS = [
    "user_id",
    "profile_id",
    "day",
    "sessions",
    "pages_read",
    "seconds_read",
    "series_count",
]


def _shift_day(day: str, delta: int) -> str:
    return (date.fromisoformat(day) + timedelta(days=delta)).isoformat()


def _day_started_at(day: date | str) -> datetime:
    """The UTC instant the roll-up day ``day`` began at.

    The one place a ``YYYY-MM-DD`` becomes an instant, so every bound the
    roll-up is written and read under is the same boundary.
    """
    if isinstance(day, str):
        day = date.fromisoformat(day)
    return datetime.combine(day, time.min) - timedelta(
        minutes=ROLLUP_TZ_OFFSET_MINUTES
    )


# --- shared clause elements ------------------------------------------------
#
# Built once. See ``ReadingStatsService._aggregates`` for why.


def _build_seconds():
    """Capped seconds for one session row.

    The elapsed time itself is stored (``ReadingSession.duration_seconds``,
    revision 0009) instead of being recomputed from the two timestamps on every
    read: ``strftime`` parsed both of them per row, per roll-up, and this
    expression appears in six of them. The cap stays here rather than in the
    column because it is a reading policy, not a fact about the session — see
    ``SESSION_SECONDS_CAP``.

    No ``max(0, ...)`` guard is needed any more: the stored value is already
    floored at 0 by the mapper listener that writes it, so an unclosed session
    and a client with a skewed clock both arrive as 0.
    """
    return func.min(literal(SESSION_SECONDS_CAP), ReadingSession.duration_seconds)


_SECONDS = _build_seconds()
_CHAPTER_ID = (
    ReadingSession.source_id
    + literal(_SEP)
    + ReadingSession.series_key
    + literal(_SEP)
    + ReadingSession.chapter_key
)
_SERIES_ID = ReadingSession.source_id + literal(_SEP) + ReadingSession.series_key
_AGGREGATES = (
    func.count().label("sessions"),
    func.coalesce(func.sum(ReadingSession.pages_read), 0).label("pages_read"),
    func.count(distinct(_CHAPTER_ID)).label("chapters_read"),
    func.count(distinct(_SERIES_ID)).label("series_read"),
    func.coalesce(func.sum(_SECONDS), 0).label("seconds_read"),
)


def _closed_day_source(*, before: datetime, since: datetime | None = None):
    """One row per ``(user_id, profile_id, day)``, in ``_ROLLUP_COLUMNS`` order.

    The single statement behind both writers here -- the reader's catch-up and
    the operator's rebuild -- so a day can only ever be materialised one way.

    ``before`` is the exclusive upper bound and it is what makes these rows
    *settled*: passed today's local midnight, the statement can only see days
    that can never gain another session in the ordinary course of things.
    Both bounds are compared against ``started_at`` rather than against the
    bucketed day string, so the window stays a range predicate on
    ``ix_reading_sessions_started_at`` instead of a ``strftime`` over the
    table.
    """
    day = func.strftime("%Y-%m-%d", ReadingSession.started_at, _ROLLUP_MODIFIER)
    stmt = (
        select(
            ReadingSession.user_id,
            ReadingSession.profile_id,
            day,
            func.count(),
            func.coalesce(func.sum(ReadingSession.pages_read), 0),
            func.coalesce(func.sum(_SECONDS), 0),
            func.count(distinct(_SERIES_ID)),
        )
        .where(ReadingSession.started_at < before)
        .group_by(ReadingSession.user_id, ReadingSession.profile_id, day)
    )
    if since is not None:
        stmt = stmt.where(ReadingSession.started_at >= since)
    return stmt


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


class ReadingStatsService:
    """Aggregates one profile's ``reading_sessions`` entirely in SQL."""

    def __init__(
        self,
        db: Session,
        *,
        user_id: int | None,
        profile_id: int | None,
        gate_open: bool,
        tz_offset_minutes: int = 0,
    ) -> None:
        self._db = db
        self._user_id = user_id
        self._profile_id = profile_id
        self._gate_open = gate_open
        self._tz = int(tz_offset_minutes)
        #: One clock for the whole payload. Every "now" here used to be its own
        #: ``utcnow()``, which was harmless while nothing was written; it is
        #: not any more. A request that straddles midnight would materialise a
        #: day under one boundary and then read it back under the next one,
        #: and the roll-up would look short of a session it had just correctly
        #: excluded.
        self._now = utcnow()
        _rollup_today = (
            self._now + timedelta(minutes=ROLLUP_TZ_OFFSET_MINUTES)
        ).date()
        #: The instant today's roll-up day began, and the last day that may be
        #: materialised. Everything the roll-up writes is strictly below the
        #: first; everything it cannot answer for is at or above it.
        self._today_started_at = _day_started_at(_rollup_today)
        self._yesterday = (_rollup_today - timedelta(days=1)).isoformat()
        #: Resolved once per instance by ``_rollup_usable`` -- it materialises
        #: and then verifies, and ``build`` must not pay that per roll-up.
        self._rollup_ok: bool | None = None

    # --- scope + gate --------------------------------------------------

    def _session_scope(self, stmt):
        """``FollowedSeriesService._scope`` for ``reading_sessions``.

        ``None`` is the unscoped bucket, not a wildcard: ``profile_id`` is NOT
        NULL on this table, so an unscoped caller correctly sees nothing rather
        than the account's every profile merged together.
        """
        stmt = stmt.where(ReadingSession.user_id == self._user_id)
        if self._profile_id is None:
            return stmt.where(ReadingSession.profile_id.is_(None))
        return stmt.where(ReadingSession.profile_id == self._profile_id)

    def _rollup_scope(self, stmt):
        """:meth:`_session_scope` for ``reading_day_stats``."""
        stmt = stmt.where(ReadingDayStats.user_id == self._user_id)
        if self._profile_id is None:
            return stmt.where(ReadingDayStats.profile_id.is_(None))
        return stmt.where(ReadingDayStats.profile_id == self._profile_id)

    def _rollup_usable(self) -> bool:
        """Whether ``reading_day_stats`` may answer for ``reading_sessions``.

        Three conditions, and every one of them is about the roll-up returning
        the *same* answer rather than a faster one. A statistics screen that
        loads quickly and reports a streak of 4 where the sessions say 11 is a
        worse outcome than the scan it replaced.

        **The gate must be open.** The roll-up counts every session, mature
        included, and it cannot do otherwise: a series' rating is resolved from
        the profile's follow row and changes when someone flips an override, so
        a rating frozen into a summary is wrong from that moment on. With the
        gate shut the numbers are a different question, asked of the sessions.

        **The offset must match.** ``day`` is a string bucketed at
        :data:`ROLLUP_TZ_OFFSET_MINUTES`; a caller reading at another offset is
        asking where a different midnight falls, which these rows cannot say.

        **Every closed session must be accounted for.** ``SUM(sessions)`` over
        the scope against ``COUNT(*)`` of the scope's sessions older than
        today -- see :meth:`_rollup_counts_every_session`, which
        :meth:`_materialise` has just tried to make true. It is the reason the
        two paths cannot disagree, and it is cheap next to what it guards: a
        covering count over ``ix_reading_sessions_started_at`` instead of a
        ``strftime`` group-by that sorts the profile's whole history into a
        temp b-tree and parses a date per row. It is not free, and it is not
        asymptotically better -- it is the price of never moving someone's
        streak without being able to prove the move.

        A count is not a hash: it cannot see a session counted under the wrong
        day. It does not have to. Sessions are append-only and never updated,
        so the only way to reach a right count over wrong days is to have
        written these rows by something other than :func:`_closed_day_source`.
        """
        if self._rollup_ok is None:
            self._rollup_ok = (
                self._gate_open
                and self._tz == ROLLUP_TZ_OFFSET_MINUTES
                and self._materialise()
            )
        return self._rollup_ok

    def _materialise(self) -> bool:
        """Bring the roll-up level with yesterday. True when it may be believed.

        This is a read that writes, which is worth being uncomfortable about,
        so: nothing else can do it. ``progress_service`` records a session
        without knowing whether the day it lands in was already summarised,
        and a day's ``series_count`` is a DISTINCT count that cannot be
        incremented from one session anyway; there is no scheduler on this box
        to run a nightly job, and a roll-up nothing maintains is a roll-up the
        reader can never use (which is exactly what shipping the empty table
        left behind). So the reader owns it, and pays for it in bounded steps.

        The count decides, and it decides FIRST: a roll-up that already
        accounts for every closed session has nothing missing from it, so the
        overwhelmingly common read -- the second one of the day, or any read by
        someone who did not read yesterday -- writes nothing at all and costs
        the two counts it would have cost anyway. Only a short count leads to a
        write, and then :meth:`_repair_plan` says where to start.

        The write is deliberately the last thing that can fail: if SQLite's
        single writer is busy, the read gives up on the roll-up and returns the
        same numbers the slow way rather than 500ing a statistics screen over
        a derived table.
        """
        try:
            if self._rollup_counts_every_session():
                return True
            for since_day in self._repair_plan():
                self._roll_closed_days(since_day)
                if self._rollup_counts_every_session():
                    return True
            # A full rebuild makes the count true by construction, so reaching
            # here means something outside this module's model of the data.
            # The sessions answer, and this instance stops asking.
            return False
        except OperationalError:
            # A locked database, on the read path, for a summary that is only
            # ever an optimisation. ``rollback`` is safe here because this
            # module never shares a transaction with a caller's writes: the
            # statistics endpoint reads, and this is the only thing in it that
            # does not.
            self._db.rollback()
            return False

    def _repair_plan(self) -> list[str | None]:
        """The days to re-derive from, cheapest first. ``None`` is "the scope".

        * Nothing rolled up yet -- build the scope, once.
        * The days that closed since the last read. The ordinary case, and
          normally one day.
        * The trailing window: a session landing in a day that was already
          summarised. See :data:`_REPAIR_DAYS` for why this is a window and not
          the exact set of days that changed.
        * The whole scope: anything older than the window. This is the scan the
          roll-up exists to avoid, paid once, after which the count is true by
          construction.
        """
        last = self._last_rolled_day()
        if last is None:
            return [None]
        # Skipped when the roll-up already reaches yesterday: there are no
        # closed days after it to add, so extending would write nothing.
        extend = [] if last >= self._yesterday else [_shift_day(last, 1)]
        return [*extend, _shift_day(self._yesterday, 1 - _REPAIR_DAYS), None]

    def _last_rolled_day(self) -> str | None:
        return self._db.execute(
            self._rollup_scope(select(func.max(ReadingDayStats.day)))
        ).scalar_one()

    def _roll_closed_days(self, since_day: str | None) -> None:
        """Re-derive this scope's roll-up from ``since_day`` through yesterday.

        Delete-then-insert rather than an upsert: a day can lose its last
        session only by a delete that never happens here, but the *set* of days
        in the range is the thing being replaced, and a stale row inside it
        (one written at a different ``ROLLUP_TZ_OFFSET_MINUTES``, or for a day
        that should never have been summarised) has to go rather than survive
        an ON CONFLICT that never fires for it. ``since_day=None`` replaces the
        scope entirely.

        One statement each way, in the database: a decade of sessions never
        crosses into Python, and both land in one transaction so a crash
        between them cannot leave a scope summarised as zero.
        """
        stale = self._rollup_scope(delete(ReadingDayStats))
        source = self._session_scope(
            _closed_day_source(
                before=self._today_started_at,
                since=_day_started_at(since_day) if since_day else None,
            )
        )
        if since_day is not None:
            stale = stale.where(ReadingDayStats.day >= since_day)
        self._db.execute(stale)
        self._db.execute(
            insert(ReadingDayStats).from_select(_ROLLUP_COLUMNS, source)
        )
        self._db.commit()

    def _rollup_counts_every_session(self) -> bool:
        """``SUM(sessions)`` stored vs. sessions recorded before today.

        Today is excluded from both sides, not just from the roll-up: it is
        the boundary the materialisation is defined by, and a session stamped
        slightly in the future (clients stamp their own, clamped at
        ``MAX_CLIENT_CLOCK_SKEW``) sits above it on both sides rather than
        counting against a day that is not allowed to exist yet.
        """
        rolled = self._db.execute(
            self._rollup_scope(
                select(func.coalesce(func.sum(ReadingDayStats.sessions), 0))
            )
        ).scalar_one()
        recorded = self._db.execute(
            self._session_scope(
                select(func.count()).select_from(ReadingSession)
            ).where(ReadingSession.started_at < self._today_started_at)
        ).scalar_one()
        return int(rolled or 0) == int(recorded or 0)

    def _mature_case(self):
        """1 when a session's series is 18+ for this profile, else 0.

        The rule is :func:`core.content_rating.mature_tracker_case`, beside the
        ``resolve_tracker_rating`` it mirrors. All this names is the column the
        source's own maturity is read from.
        """
        return mature_tracker_case(ReadingSession.source_id)

    def _sessions(self, stmt, *, needs_follow: bool = False):
        """Scope + gate a statement whose FROM is ``reading_sessions``.

        The follow row is joined when the statement actually needs it, which is
        either because it *selects* something off it (``needs_follow=True`` —
        the per-series breakdown reads ``title``/``cover_url``, recent activity
        reads ``title``) or because the 18+ gate is shut and the rating has to
        be resolved to filter on it.

        It used to be joined unconditionally, and that is what made the
        statistics screen expensive: six of the nine roll-ups select nothing but
        aggregates over ``reading_sessions``, yet every session row still paid
        an index probe into ``followed_series``. Removing the join from those
        six cut ``GET /library/statistics`` roughly in half on a 12,000-session
        profile. ``uq_followed_series`` still guarantees at most one match
        wherever the join *is* applied, so it can never fan a session row out.
        """
        if needs_follow or not self._gate_open:
            stmt = stmt.outerjoin(
                FollowedSeries,
                and_(
                    FollowedSeries.user_id == ReadingSession.user_id,
                    FollowedSeries.profile_id == ReadingSession.profile_id,
                    FollowedSeries.source_id == ReadingSession.source_id,
                    FollowedSeries.series_key == ReadingSession.series_key,
                ),
            )
        stmt = self._session_scope(stmt)
        if not self._gate_open:
            stmt = stmt.where(self._mature_case() == 0)
        return stmt

    # --- expressions ---------------------------------------------------

    @property
    def _modifier(self) -> str:
        """SQLite date modifier that shifts UTC into the caller's local day."""
        return f"{self._tz:+d} minutes"

    def _day(self, column=None):
        return func.strftime(
            "%Y-%m-%d", column if column is not None else ReadingSession.started_at,
            self._modifier,
        )

    def _hour(self):
        return func.cast(
            func.strftime("%H", ReadingSession.started_at, self._modifier), Integer
        )

    @staticmethod
    def _seconds():
        """Capped wall-clock seconds for one session row.

        ``max(0, ...)`` because a client with a skewed clock can report an
        ``ended_at`` before its ``started_at``, and a negative session would
        quietly subtract from the day's total.
        """
        return _SECONDS

    @staticmethod
    def _chapter_id():
        return _CHAPTER_ID

    @staticmethod
    def _series_id():
        return _SERIES_ID

    def _aggregates(self) -> list[Any]:
        """The five numbers every roll-up reports, in a fixed column order.

        The expressions are built once at import (see ``_build_*`` below) and
        reused. SQLAlchemy clause elements are immutable and safe to share
        between statements, and rebuilding these was measurably the single
        biggest cost of the statistics endpoint on small data: five roll-ups
        each rebuilt five aggregates, several of them string concatenations of
        three columns, which came to ~640 ``coercions.expect`` calls per
        request before a single row was read.
        """
        return list(_AGGREGATES)

    @staticmethod
    def _roll(row) -> dict[str, int]:
        return {
            "sessions": int(row.sessions or 0),
            "pages_read": int(row.pages_read or 0),
            "chapters_read": int(row.chapters_read or 0),
            "series_read": int(row.series_read or 0),
            "seconds_read": int(row.seconds_read or 0),
        }

    # --- windows --------------------------------------------------------

    def _bounds(self, days: int) -> tuple[datetime, datetime, list[str]]:
        """UTC lower bound of the window, "now", and its dense day labels.

        The bound is computed in Python rather than in SQL so the window filter
        stays a plain ``started_at >= ?`` range predicate and keeps using
        ``ix_reading_sessions_started_at``; wrapping the column in ``strftime``
        to compare local days would make every window scan the whole table.
        """
        now_utc = self._now
        offset = timedelta(minutes=self._tz)
        today_local = (now_utc + offset).date()
        first_local = today_local - timedelta(days=days - 1)
        since_utc = datetime.combine(first_local, time.min) - offset
        labels = [(first_local + timedelta(days=i)).isoformat() for i in range(days)]
        return since_utc, now_utc, labels

    # --- queries --------------------------------------------------------

    def _totals(self) -> dict[str, Any]:
        row = self._db.execute(
            self._sessions(
                select(
                    *self._aggregates(),
                    func.min(ReadingSession.started_at).label("first_at"),
                    func.max(ReadingSession.started_at).label("last_at"),
                ).select_from(ReadingSession)
            )
        ).one()
        payload = self._roll(row)
        payload["first_session_at"] = _iso(row.first_at)
        payload["last_session_at"] = _iso(row.last_at)
        return payload

    def _window(self, since: datetime) -> dict[str, int]:
        row = self._db.execute(
            self._sessions(
                select(*self._aggregates()).select_from(ReadingSession)
            ).where(ReadingSession.started_at >= since)
        ).one()
        return self._roll(row)

    def _daily(self, since: datetime, labels: list[str]) -> list[dict[str, Any]]:
        day = self._day().label("day")
        rows = self._db.execute(
            self._sessions(
                select(day, *self._aggregates()).select_from(ReadingSession)
            )
            .where(ReadingSession.started_at >= since)
            .group_by(day)
        ).all()
        found = {r.day: self._roll(r) for r in rows}
        empty = {
            "sessions": 0,
            "pages_read": 0,
            "chapters_read": 0,
            "series_read": 0,
            "seconds_read": 0,
        }
        # Dense on purpose: a chart that only receives the days with data draws
        # a line straight through the gaps and turns a week off into a plateau.
        return [{"date": d, **(found.get(d) or dict(empty))} for d in labels]

    def _active_days(self) -> list[str]:
        """Every local day this profile read on, oldest first.

        DISTINCT is done by the database, so this returns one string per day the
        owner has ever read -- a few thousand rows after a decade, not the
        session table.

        It is the only question here asked of the whole history, so it is also
        the only one that grew forever: no window means no range predicate, and
        grouping on ``strftime`` means no index either, so every open of the
        statistics screen sorted every session ever recorded into a temp
        b-tree. The roll-up already holds one row per closed active day and is
        read instead whenever it can be shown to hold the same days -- see
        :meth:`_rollup_usable`.

        Today is added from the sessions, because today is the one day the
        roll-up is forbidden to hold: it is still being read into. That query
        is bounded by ``started_at >= today``, which is a range predicate on
        ``ix_reading_sessions_started_at`` and touches no closed-day row --
        together with the roll-up it is the whole point of the change.
        """
        if self._rollup_usable():
            closed = self._db.execute(
                self._rollup_scope(select(ReadingDayStats.day))
                .where(ReadingDayStats.sessions > 0)
                .order_by(ReadingDayStats.day)
            ).scalars().all()
            today = self._day().label("day")
            # ">=", not "== today": a client may stamp a session up to
            # MAX_CLIENT_CLOCK_SKEW ahead, and the session path counts that day
            # too, so dropping it here would make the two paths disagree at
            # midnight.
            open_days = self._db.execute(
                self._sessions(select(today).select_from(ReadingSession))
                .where(ReadingSession.started_at >= self._today_started_at)
                .group_by(today)
            ).scalars().all()
            return sorted({d for d in (*closed, *open_days) if d})
        day = self._day().label("day")
        rows = self._db.execute(
            self._sessions(select(day).select_from(ReadingSession))
            .group_by(day)
            .order_by(day)
        ).all()
        return [r.day for r in rows if r.day]

    def _streak(self, active: list[str]) -> dict[str, Any]:
        """Current and longest run of consecutive active days.

        The current streak survives a day with no reading *today*: it stays
        alive while the last active day is today or yesterday, because zeroing
        it at midnight would report a broken streak to someone whose day has
        barely started. It is 0 once a whole day has been missed.
        """
        if not active:
            return {"current_days": 0, "longest_days": 0, "last_active_date": None}
        days = [datetime.strptime(d, "%Y-%m-%d").date() for d in active]
        longest = run = 1
        for prev, cur in zip(days, days[1:]):
            run = run + 1 if (cur - prev).days == 1 else 1
            longest = max(longest, run)
        today = (self._now + timedelta(minutes=self._tz)).date()
        current = run if (today - days[-1]).days <= 1 else 0
        return {
            "current_days": current,
            "longest_days": longest,
            "last_active_date": active[-1],
        }

    def _by_hour(self, since: datetime) -> list[dict[str, int]]:
        hour = self._hour().label("hour")
        rows = self._db.execute(
            self._sessions(
                select(
                    hour,
                    func.count().label("sessions"),
                    func.coalesce(func.sum(ReadingSession.pages_read), 0).label(
                        "pages_read"
                    ),
                    func.coalesce(func.sum(self._seconds()), 0).label("seconds_read"),
                ).select_from(ReadingSession)
            )
            .where(ReadingSession.started_at >= since)
            .group_by(hour)
        ).all()
        found = {int(r.hour): r for r in rows if r.hour is not None}
        out = []
        for h in range(24):
            r = found.get(h)
            out.append(
                {
                    "hour": h,
                    "sessions": int(r.sessions) if r else 0,
                    "pages_read": int(r.pages_read) if r else 0,
                    "seconds_read": int(r.seconds_read) if r else 0,
                }
            )
        return out

    def _by_source(self, since: datetime) -> list[dict[str, Any]]:
        names = {
            source_id: d.name
            for source_id, d in descriptors_by_source().items()
        }
        rows = self._db.execute(
            self._sessions(
                select(ReadingSession.source_id, *self._aggregates()).select_from(
                    ReadingSession
                )
            )
            .where(ReadingSession.started_at >= since)
            .group_by(ReadingSession.source_id)
            .order_by(func.sum(ReadingSession.pages_read).desc())
            .limit(_TOP_SOURCES)
        ).all()
        return [
            {
                "source_id": r.source_id,
                "name": names.get(r.source_id, r.source_id),
                **self._roll(r),
            }
            for r in rows
        ]

    def _by_series(self, since: datetime) -> list[dict[str, Any]]:
        # ``max()`` over title/cover is an aggregate only for SQL's sake: the
        # LEFT join matches at most one follow row per group, so the group's
        # rows all carry the same value (or NULL for a series no longer
        # followed, whose history still counts).
        rows = self._db.execute(
            self._sessions(
                select(
                    ReadingSession.source_id,
                    ReadingSession.series_key,
                    func.max(FollowedSeries.title).label("title"),
                    func.max(FollowedSeries.cover_url).label("cover_url"),
                    func.max(ReadingSession.started_at).label("last_read_at"),
                    *self._aggregates(),
                ).select_from(ReadingSession),
                needs_follow=True,
            )
            .where(ReadingSession.started_at >= since)
            .group_by(ReadingSession.source_id, ReadingSession.series_key)
            .order_by(func.sum(ReadingSession.pages_read).desc())
            .limit(_TOP_SERIES)
        ).all()
        out = []
        for r in rows:
            item = {
                "source_id": r.source_id,
                "series_key": r.series_key,
                "title": r.title,
                "cover_url": r.cover_url,
                "last_read_at": _iso(r.last_read_at),
            }
            item.update(self._roll(r))
            item.pop("series_read")  # always 1 inside a per-series group
            out.append(item)
        self._fill_cached_titles(out, with_cover=True)
        return out

    def _fill_cached_titles(
        self, items: list[dict[str, Any]], *, with_cover: bool = False
    ) -> None:
        """Name rows whose series is no longer followed, from the series cache.

        The follow join is the only title source the grouped queries have, so a
        series read but never followed (or unfollowed since) came back with no
        title at all -- and the clients fell back to the raw ``series_key`` or
        just the source's name, which put two rows both labelled "novelarchive"
        at the top of the owner's "Most read". ``source_series_cache`` usually
        still holds the title, and :meth:`ProgressService._series_titles`
        already reads it the same way for the history screen.

        One lookup after the query, not a join inside the GROUP BY: the lists
        are a handful of rows, and the cache has no business shaping the
        grouping. A miss stays a miss -- the cache is TTL-evicted, and filling
        it would mean fetching from the source on a statistics render. The 18+
        gate is untouched: this only relabels rows the gate already let through.
        """
        pairs = {
            (item["source_id"], item["series_key"])
            for item in items
            if not item.get("title")
        }
        if not pairs:
            return
        found = {
            (source_id, series_key): (title, cover)
            for source_id, series_key, title, cover in self._db.execute(
                select(
                    SourceSeriesCache.source_id,
                    SourceSeriesCache.series_key,
                    SourceSeriesCache.title,
                    SourceSeriesCache.cover_url,
                ).where(
                    tuple_(
                        SourceSeriesCache.source_id, SourceSeriesCache.series_key
                    ).in_(list(pairs))
                )
            ).all()
            if title
        }
        for item in items:
            hit = found.get((item["source_id"], item["series_key"]))
            if hit is None or item.get("title"):
                continue
            item["title"] = hit[0]
            if with_cover and not item.get("cover_url"):
                item["cover_url"] = hit[1]

    def _recent(self) -> list[dict[str, Any]]:
        """The last few SITTINGS, deliberately *not* windowed.

        A row here is one chapter on one LOCAL day, not one ping. The write side
        appends a ``reading_sessions`` row per advance (``progress_service``),
        which is right for the totals and wrong for a list a human reads: one
        evening with a chapter produced a dozen identical rows. The live table
        showed exactly that -- twelve rows for one chapter, "1 page" each,
        06:27 to 06:50 -- and the three chapters read before it were pushed off
        a ten-row list by a single sitting.

        Grouping rules worth keeping:

        * On the three raw key columns, never a folded ``source||series||chapter``
          string: connector keys contain slashes, so folding would merge
          ``("a/b", "c")`` with ``("a", "b/c")`` into one sitting.
        * By the caller's LOCAL day, so a sitting is split where the reader's
          midnight is, not Greenwich's.
        * ``seconds_read`` sums the ALREADY-CAPPED per-row expression. The cap
          is a per-ping policy (``SESSION_SECONDS_CAP``); applying it to the
          merged group instead would silently shrink every long sitting to an
          hour.
        * Ordered by the LAST ping of each sitting. A bare column beside a
          GROUP BY is legal in SQLite and picks an arbitrary row, which would
          order this list by nothing in particular.

        "Recent activity" that goes blank because the caller asked for a 7-day
        chart and last read a fortnight ago is worse than useless -- so there is
        still no window here, however tempting one is for the GROUP BY.
        """
        day = self._day().label("day")
        last_at = func.max(ReadingSession.started_at)
        rows = self._db.execute(
            self._sessions(
                select(
                    ReadingSession.source_id,
                    ReadingSession.series_key,
                    ReadingSession.chapter_key,
                    day,
                    func.max(ReadingSession.chapter_number).label("chapter_number"),
                    func.coalesce(func.sum(ReadingSession.pages_read), 0).label(
                        "pages_read"
                    ),
                    func.coalesce(func.sum(self._seconds()), 0).label("seconds_read"),
                    func.min(ReadingSession.started_at).label("started_at"),
                    func.max(ReadingSession.ended_at).label("ended_at"),
                    func.count().label("sessions"),
                    FollowedSeries.title.label("title"),
                ).select_from(ReadingSession),
                needs_follow=True,
            )
            .group_by(
                ReadingSession.source_id,
                ReadingSession.series_key,
                ReadingSession.chapter_key,
                day,
                FollowedSeries.title,
            )
            .order_by(last_at.desc())
            .limit(_RECENT_SESSIONS)
        ).all()
        out = [
            {
                "source_id": r.source_id,
                "series_key": r.series_key,
                "chapter_key": r.chapter_key,
                "chapter_number": r.chapter_number,
                "title": r.title,
                "day": r.day,
                "pages_read": int(r.pages_read or 0),
                "seconds_read": int(r.seconds_read or 0),
                #: How many pings this sitting merged. 1 means it really was one.
                "sessions": int(r.sessions or 0),
                "started_at": _iso(r.started_at),
                "ended_at": _iso(r.ended_at),
            }
            for r in rows
        ]
        self._fill_cached_titles(out)
        return out

    def chapters_completed(self) -> int:
        """Chapters marked finished in ``chapter_progress`` for this profile.

        A different number from ``totals.chapters_read`` and both are honest:
        this one counts chapters *finished* (including ones finished before
        session recording existed, and ones synced from another device with no
        session attached), while ``chapters_read`` counts chapters an actual
        recorded session touched. Gated like everything else so the count does
        not move when a gated profile cannot see the chapters behind it.

        Counted per chapter IDENTITY, not per row: AsuraScans rotates its slug
        suffix, so one chapter finished under last week's key and reopened
        under this week's holds a completed row under each, and a row count
        called it two chapters.
        """
        stmt = (
            select(ChapterProgress.source_id, ChapterProgress.chapter_key)
            .where(ChapterProgress.user_id == self._user_id)
            .where(ChapterProgress.is_completed.is_(True))
        )
        if self._profile_id is None:
            stmt = stmt.where(ChapterProgress.profile_id.is_(None))
        else:
            stmt = stmt.where(ChapterProgress.profile_id == self._profile_id)
        if not self._gate_open:
            stmt = stmt.outerjoin(
                FollowedSeries,
                and_(
                    FollowedSeries.user_id == ChapterProgress.user_id,
                    FollowedSeries.profile_id == ChapterProgress.profile_id,
                    FollowedSeries.source_id == ChapterProgress.source_id,
                    FollowedSeries.series_key == ChapterProgress.series_key,
                ),
            ).where(self._progress_mature_case() == 0)
        from services.browse_service import chapter_identity

        return len(
            {
                (source_id, chapter_identity(source_id, chapter_key))
                for source_id, chapter_key in self._db.execute(stmt)
            }
        )

    def _progress_mature_case(self):
        """:meth:`_mature_case` against ``chapter_progress``' source column."""
        return mature_tracker_case(ChapterProgress.source_id)

    # --- public ---------------------------------------------------------

    def build(self, days: int) -> dict[str, Any]:
        since, now, labels = self._bounds(days)
        return {
            "range": {
                "days": days,
                "since": _iso(since),
                "until": _iso(now),
                "timezone_offset_minutes": self._tz,
                "session_cap_seconds": SESSION_SECONDS_CAP,
            },
            "totals": self._totals(),
            "window": self._window(since),
            "streak": self._streak(self._active_days()),
            "daily": self._daily(since, labels),
            "by_hour": self._by_hour(since),
            "by_source": self._by_source(since),
            "by_series": self._by_series(since),
            "recent_sessions": self._recent(),
        }


# --- the roll-up's whole-table rebuild -------------------------------------


def backfill_reading_day_stats(
    db: Session, *, user_id: int | None = None, profile_id: int | None = None
) -> int:
    """Rebuild ``reading_day_stats`` from ``reading_sessions``. Returns rows written.

    Whole table by default; pass ``user_id`` and/or ``profile_id`` to rebuild
    one scope. Idempotent -- the rows in scope are deleted and recomputed, so
    running it twice cannot double a count.

    The reader repairs its own scope (:meth:`ReadingStatsService._materialise`),
    so this is not what keeps the table current. It is the whole-table version
    of the same statement, for the two jobs a per-scope read cannot do:
    changing :data:`ROLLUP_TZ_OFFSET_MINUTES` or :data:`SESSION_SECONDS_CAP`,
    both of which invalidate every stored row for every profile at once.

    THE CONTRACT, which any other writer of this table must keep for
    :meth:`ReadingStatsService._rollup_usable` to trust a row:

    * One row per ``(user_id, profile_id, day)`` where ``day`` is
      ``strftime('%Y-%m-%d', started_at, _ROLLUP_MODIFIER)`` -- the string the
      reader compares, at the one offset it will compare it at. It never
      converts a stored day.
    * CLOSED days only. Today has not finished and its summary would be wrong
      the moment it was written, so the reader answers today from the sessions
      and a row for it is a bug, not a head start.
    * ``sessions`` counts EVERY session in the day, mature ones included. The
      roll-up carries no maturity signal on purpose: a series' rating is
      resolved from the profile's ``followed_series`` row and can change after
      the fact, so a rating baked into a summary would be wrong the moment
      someone flips an override. The reader handles this by using the roll-up
      only while the 18+ gate is open.
    * ``sessions`` is also the reader's checksum: ``SUM(sessions)`` over a
      scope must equal ``COUNT(*)`` of that scope's sessions older than today.
      An import that adds rows behind the reader's back breaks that equality,
      and the reader rebuilds (or, failing that, answers from the sessions --
      same numbers, slower). Nothing silently changes; that is the point of
      the checksum.
    * ``seconds_read`` is summed AFTER ``SESSION_SECONDS_CAP`` is applied per
      session, so a cap change needs a rebuild -- which is one of the two
      reasons this function exists.
    * ``series_count`` is that day's DISTINCT ``(source_id, series_key)``
      count. It is not incrementable from the session alone -- a second
      session on a series already read that day must not raise it -- so a
      writer either recomputes the day or checks first.

    Sessions stay the record of truth: this table may be dropped and rebuilt
    from them at any time, and this function is that rebuild.
    """
    today = (utcnow() + timedelta(minutes=ROLLUP_TZ_OFFSET_MINUTES)).date()
    source = _closed_day_source(before=_day_started_at(today))
    stale = delete(ReadingDayStats)
    if user_id is not None:
        source = source.where(ReadingSession.user_id == user_id)
        stale = stale.where(ReadingDayStats.user_id == user_id)
    if profile_id is not None:
        source = source.where(ReadingSession.profile_id == profile_id)
        stale = stale.where(ReadingDayStats.profile_id == profile_id)

    db.execute(stale)
    # One statement, in the database: a decade of sessions never crosses into
    # Python, and the delete and the insert land in the same transaction so a
    # crash between them cannot leave a scope summarised as zero.
    written = db.execute(
        insert(ReadingDayStats).from_select(_ROLLUP_COLUMNS, source)
    ).rowcount
    db.commit()
    return int(written or 0)
