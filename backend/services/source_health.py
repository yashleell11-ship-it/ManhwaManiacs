"""Per-source reachability: recording it, reading it, and deciding demotion.

Roughly 100 of the ~151 installed connectors are dead. Nothing recorded that,
so the owner found out only when a followed series quietly stopped updating.
This module owns the whole story: what counts as a failure, when a row is worth
writing, and when a source has failed often enough to be pushed down the search
results and flagged in listings.

Health is **global** -- a site being down is a property of the site, not of the
account that searched while it was down. It is not globally *disclosed*: callers
build their payloads from their own mature-gated descriptor list and look health
up per source, so a mature source's row never reaches a profile that cannot see
the source (see :func:`states_for`).

Write policy (why the search fan-out does not write on every search)
-------------------------------------------------------------------
The database is SQLite with a single writer that page reads already contend
with, and the fan-out probes *every* source on *every* search. Writing an
outcome per source per search would mean ~151 UPDATEs per search forever, with
the dead majority contributing most of them.

Instead a row is written only when the write would change something a reader can
observe:

* the source has no row yet (first observation),
* the outcome flips the state (ok -> failing, failing -> ok), or
* the streak is still climbing towards the thresholds below.

Skipping the rest is safe precisely because in those cases the stored state
already equals the observed state -- a healthy source that succeeded again, or a
long-dead source that failed again, has nothing new to say. The steady state is
therefore **zero writes per search**; a genuine state change costs one commit
covering every source that moved.

The one thing lost is timestamp precision: ``last_ok_at`` / ``last_checked_at``
would otherwise freeze at the last state change, so :data:`REFRESH_INTERVAL`
forces a refresh of an otherwise-unchanged row. Read those two columns as
"accurate to within that interval", not to the second.

Real traffic (why a reader's own request counts, and which failures do)
----------------------------------------------------------------------
The re-probe fetches one LISTING page, the sweep only reaches followed series,
and search only exercises the search endpoint. A source blocked on its series
pages alone (linkmanga was) answered all three and looked healthy forever,
while every reader who opened a series from it got a 502. So a reader's own
request for a series page, its chapter list, or a search on one source is
evidence too -- recorded through :func:`record_traffic_outcome`, costing no
request the reader was not already making.

That evidence is narrower than the fan-out's on purpose, because it arrives one
reader at a time and a streak demotes the source for everyone:

* Only failures that are the SOURCE's count (:func:`source_side_failure`): an
  HTTP 403 (a Cloudflare challenge is reported as one) or 5xx, or a connection
  the site refused or a host that would not resolve. A timeout never counts --
  it is as likely to be this box's own congestion as the site -- and neither
  does any other 4xx, which is an answer about that one request.
* A failure the connector swallowed counts too. Madara answers a blocked series
  page with None and a blocked chapter list with [], so the failure never
  reaches the reader's request as an exception; the connector notes it through
  ``connectors.http.swallowed`` and the browse service reads it back only when
  the answer came back empty. The reader still sees the None / [] they always
  did.
* A burst is one observation (:data:`TRAFFIC_FAILURE_SPACING`). Opening one
  series fires its series and chapter requests together; without this, a single
  tap on a blocked source would count twice and one retry would demote it.
"""

from __future__ import annotations

import logging
import socket
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Iterable, Mapping

import httpx
from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from connectors.http.client import status_of
from core.time_utils import utcnow
from database.models import SourceHealth

try:  # the Cloudflare-impersonating client's transport errors
    from curl_cffi.const import CurlECode as _CurlECode
    from curl_cffi.requests.exceptions import (
        ConnectionError as _CurlConnectionError,
        DNSError as _CurlDNSError,
        Timeout as _CurlTimeout,
    )
except ImportError:  # pragma: no cover - curl_cffi is a hard dependency today
    _CurlECode = None
    _CurlConnectionError = _CurlDNSError = _CurlTimeout = None

logger = logging.getLogger(__name__)

# --- status vocabulary -------------------------------------------------------
#: Answered on its last probe.
STATUS_OK = "ok"
#: Failing, but not yet often enough to be demoted.
STATUS_FAILING = "failing"
#: Failing long enough to be treated as dead (still listed, never hidden).
STATUS_DEAD = "dead"
#: Never probed. A real third state, not a synonym for "ok" or for "failing":
#: a source installed since the last search has no evidence either way, and
#: presenting that as healthy is how ~100 dead connectors stayed invisible.
STATUS_UNKNOWN = "unknown"

# --- thresholds --------------------------------------------------------------
# Consecutive failed probes before a source is demoted in search ordering and
# flagged in listings.
#
# 3, not 1: the fan-out probes every installed source on an 8s budget over a
# home connection, so a single miss is routinely transient -- one Cloudflare
# challenge, one DNS blip, one timeout while 151 requests go out at once.
# Demoting on the first miss would reshuffle the search screen at random. Three
# misses means three *separate* searches with no answer at all.
DEMOTE_AFTER_FAILURES = 3
# The stronger flag: not "flaky", "gone". Ten separate searches without a single
# answer is not a bad afternoon, and this is where the ~100 known-dead
# connectors are expected to sit permanently. Demotion is already in force well
# before this; the second tier exists so the status page can distinguish
# "worth a look" from "delete it".
DEAD_AFTER_FAILURES = 10
# The streak stops counting here. Past the point where the number changes no
# decision, incrementing it would cost one write per dead source per search,
# forever -- precisely the hot-path write this design exists to avoid. How long
# a source has been down is read off last_ok_at, which does not saturate.
MAX_STREAK = DEAD_AFTER_FAILURES
# One success clears the streak, so a source that comes back is un-demoted by
# the very search that finds it working -- no operator action, no cooldown.
# Requiring a *streak* of successes was rejected: it would keep a working source
# buried while proving something the next failure would re-arm instantly anyway.

#: How stale ``last_checked_at`` may get on a row whose state has not moved.
#: Bounds the "nothing changed" write cost at one commit per 6h across the whole
#: registry, instead of one per search.
REFRESH_INTERVAL = timedelta(hours=6)

#: Error text is a diagnostic, not a payload: keep a readable line, drop the
#: 200KB Cloudflare interstitial some connectors raise with.
ERROR_MAX_CHARS = 500

#: "Worst first" ordering for the status page. Unknown sits between failing and
#: ok on purpose: never probed is a thing to go look at, not a clean bill.
_SEVERITY: dict[str, int] = {
    STATUS_DEAD: 0,
    STATUS_FAILING: 1,
    STATUS_UNKNOWN: 2,
    STATUS_OK: 3,
}


@dataclass(frozen=True, slots=True)
class SourceHealthState:
    """Immutable snapshot of one source's health.

    A snapshot rather than the ORM row because callers read it *after* the
    recording commit, and because "no row yet" has to be representable
    (:func:`unknown_state`) without inventing a row for every unprobed source.
    """

    source_id: str
    status: str
    consecutive_failures: int
    last_ok_at: datetime | None = None
    last_error_at: datetime | None = None
    last_error: str | None = None
    last_checked_at: datetime | None = None

    @property
    def demoted(self) -> bool:
        """Whether search ordering should push this source down."""
        return self.consecutive_failures >= DEMOTE_AFTER_FAILURES

    @property
    def severity(self) -> int:
        """Sort key for worst-first listings (lower == worse)."""
        return _SEVERITY.get(self.status, _SEVERITY[STATUS_UNKNOWN])

    def payload(self) -> dict[str, object]:
        """Client-facing block. Timestamps are ISO-8601 UTC or ``null``."""
        return {
            "status": self.status,
            "consecutive_failures": self.consecutive_failures,
            "demoted": self.demoted,
            "last_ok_at": _iso(self.last_ok_at),
            "last_error_at": _iso(self.last_error_at),
            "last_error": self.last_error,
            "last_checked_at": _iso(self.last_checked_at),
        }


def unknown_state(source_id: str) -> SourceHealthState:
    """The state of a source that has never been probed."""
    return SourceHealthState(
        source_id=source_id, status=STATUS_UNKNOWN, consecutive_failures=0
    )


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value is not None else None


def _classify(row: SourceHealth) -> str:
    if row.consecutive_failures >= DEAD_AFTER_FAILURES:
        return STATUS_DEAD
    if row.consecutive_failures > 0:
        return STATUS_FAILING
    # A row only exists because something observed the source, so zero failures
    # means the last observation succeeded. The last_ok_at guard is for rows
    # written by hand or by a restore, where that is not guaranteed.
    return STATUS_OK if row.last_ok_at is not None else STATUS_UNKNOWN


def _snapshot(row: SourceHealth) -> SourceHealthState:
    return SourceHealthState(
        source_id=row.source_id,
        status=_classify(row),
        consecutive_failures=int(row.consecutive_failures or 0),
        last_ok_at=row.last_ok_at,
        last_error_at=row.last_error_at,
        last_error=row.last_error,
        last_checked_at=row.last_checked_at,
    )


def load_states(db: Session | None) -> dict[str, SourceHealthState]:
    """Every recorded health row, keyed by source id.

    One query for the whole (at most ~151-row) table: the callers need health
    for every source they are about to list anyway, so a per-source lookup would
    only multiply reads against the single-writer database.
    """
    if db is None:
        return {}
    try:
        rows = db.execute(select(SourceHealth)).scalars().all()
    except SQLAlchemyError:
        # Health is diagnostic metadata; losing it must never fail a search or
        # a source listing (e.g. a database that predates the migration).
        logger.warning("source health unavailable; continuing without it", exc_info=True)
        db.rollback()
        return {}
    return {row.source_id: _snapshot(row) for row in rows}


def states_for(
    states: Mapping[str, SourceHealthState], source_ids: Iterable[str]
) -> dict[str, SourceHealthState]:
    """Health for exactly ``source_ids``, filling in unknowns.

    This is the no-leak seam: callers pass the source ids their *own* mature
    gate resolved, so health for a source they cannot see is never selected out
    of the global table.
    """
    return {
        source_id: states.get(source_id) or unknown_state(source_id)
        for source_id in source_ids
    }


def _is_stale(row: SourceHealth, now: datetime) -> bool:
    """Whether an otherwise-unchanged row is due its periodic refresh."""
    if row.last_checked_at is None:
        return True
    return (now - row.last_checked_at) >= REFRESH_INTERVAL


def _should_persist(row: SourceHealth | None, ok: bool, now: datetime) -> bool:
    """Whether this outcome is worth a write. See the module docstring."""
    if row is None:
        return True  # first observation of this source
    if ok:
        # Recovery is a state change; a repeat success is not.
        return row.consecutive_failures > 0 or _is_stale(row, now)
    if row.consecutive_failures == 0:
        return True  # ok -> failing
    if row.consecutive_failures < MAX_STREAK:
        return True  # streak still climbing towards the thresholds
    # Already saturated: this failure changes nothing a reader can observe.
    return _is_stale(row, now)


def record_outcomes(
    db: Session | None,
    results: Mapping[str, str | None],
    *,
    now: datetime | None = None,
) -> dict[str, SourceHealthState]:
    """Record one probe per source and return the resulting states.

    ``results`` maps source id to ``None`` for success or a one-line error
    message for failure. Returns the post-outcome state of every source in
    ``results`` -- including the ones no write was needed for, whose stored
    state already matched.

    Writes are batched into a single commit. Callers pass their request-scoped
    session, which at this point has only read; nothing else is pending to be
    committed by surprise. A failed write is logged and swallowed: recording
    diagnostics must not turn a working search into a 500.
    """
    if db is None or not results:
        return {}

    now = now or utcnow()
    try:
        rows = {
            row.source_id: row
            for row in db.execute(
                select(SourceHealth).where(SourceHealth.source_id.in_(list(results)))
            ).scalars()
        }
    except SQLAlchemyError:
        logger.warning("source health not recorded (read failed)", exc_info=True)
        db.rollback()
        return {}

    states: dict[str, SourceHealthState] = {}
    written = 0
    for source_id, error in results.items():
        row = rows.get(source_id)
        ok = error is None
        if _should_persist(row, ok, now):
            if row is None:
                row = SourceHealth(source_id=source_id, consecutive_failures=0)
                db.add(row)
            row.last_checked_at = now
            if ok:
                row.last_ok_at = now
                row.consecutive_failures = 0
            else:
                row.last_error_at = now
                row.last_error = (error or "")[:ERROR_MAX_CHARS] or None
                row.consecutive_failures = min(
                    int(row.consecutive_failures or 0) + 1, MAX_STREAK
                )
            written += 1
        # Snapshot BEFORE the commit: a rollback below would expire (or discard)
        # the ORM objects, and this response still wants the state it observed.
        states[source_id] = _snapshot(row) if row is not None else unknown_state(source_id)

    if written:
        try:
            db.commit()
        except SQLAlchemyError:
            db.rollback()
            logger.warning(
                "source health not recorded (%d row(s) rolled back)",
                written,
                exc_info=True,
            )
    return states


# --- real traffic --------------------------------------------------------------
# See "Real traffic" in the module docstring for why these exist.

#: How long after a recorded traffic failure further failures of the SAME source
#: are not counted again. Collapses one screen's burst (series + chapters, fired
#: together) and an immediate retry into one observation, so a streak from
#: traffic means what a streak from search means: separate occasions on which
#: the source did not answer. Successes are never held back -- one clears the
#: streak, exactly as it does for search.
TRAFFIC_FAILURE_SPACING = timedelta(seconds=60)

#: Fixed phrases, never ``str(exc)``: this row is GLOBAL and served to every
#: account, and an upstream exception routinely embeds the full request URL --
#: for a search, the reader's query string.
TRAFFIC_BLOCKED = "Access blocked (403). This source may use Cloudflare or bot protection."
TRAFFIC_SERVER_ERROR = "The source answered with a server error."
TRAFFIC_UNREACHABLE = "The source could not be reached."

_traffic_failed_at: dict[str, float] = {}
_traffic_lock = threading.Lock()


def reset_traffic_spacing() -> None:
    """Forget when each source last failed a reader's request. For tests."""
    with _traffic_lock:
        _traffic_failed_at.clear()


def _exception_chain(exc: BaseException) -> list[BaseException]:
    """``exc`` and what it was raised from, outermost first.

    Connector HTTP clients wrap every transport failure in a
    ``ConnectorHttpError`` raised ``from`` the original, so the reason a request
    failed (a refused connection, a timeout) is one link down. Follows the chain
    Python itself would print, and stops on a cycle.
    """
    chain: list[BaseException] = []
    current: BaseException | None = exc
    while current is not None and len(chain) < 8 and all(
        current is not seen for seen in chain
    ):
        chain.append(current)
        if current.__cause__ is not None:
            current = current.__cause__
        elif not current.__suppress_context__:
            current = current.__context__
        else:
            current = None
    return chain


def _is_timeout(exc: BaseException) -> bool:
    if isinstance(exc, (TimeoutError, httpx.TimeoutException)):
        return True
    return _CurlTimeout is not None and isinstance(exc, _CurlTimeout)


def _is_unreachable(exc: BaseException) -> bool:
    """Connection refused, or a host that does not resolve -- and nothing else.

    Deliberately not "any network error": a reset or a failed read mid-response
    is as often this end's connection as the site's.
    """
    if isinstance(exc, (httpx.ConnectError, ConnectionRefusedError, socket.gaierror)):
        return True
    if _CurlDNSError is not None and isinstance(exc, _CurlDNSError):
        return True
    if _CurlConnectionError is not None and isinstance(exc, _CurlConnectionError):
        return getattr(exc, "code", None) in {
            _CurlECode.COULDNT_CONNECT,
            _CurlECode.QUIC_CONNECT_ERROR,
        }
    return False


def source_side_failure(exc: BaseException) -> str | None:
    """The fixed health message for ``exc``, or None if it says nothing about
    the source.

    Counts: an upstream 403 (Cloudflare and DDoS-Guard challenges are raised as
    403) or 5xx, and a connection refused or a host that will not resolve.

    Does not count, whatever else is true:

    * a timeout anywhere in the chain -- including a 5xx a connector synthesised
      from one. A slow answer is as likely to be this box, busy with every other
      reader's fan-out, as the site; and one reader's bad afternoon must not
      demote a source for the whole household.
    * any other 4xx. A 404 is the site working and saying that page is gone; a
      429 is the site working and asking us to slow down.
    * everything without an upstream status or a transport cause: a parser
      that found nothing, a gate refusal, a bug. Those are real, but they are
      not reachability, and reachability is all this table claims to measure.
    """
    chain = _exception_chain(exc)
    if any(_is_timeout(link) for link in chain):
        return None
    for link in chain:
        status = status_of(link)
        if status is None:
            continue
        if status == 403:
            return TRAFFIC_BLOCKED
        if 500 <= status <= 599:
            return TRAFFIC_SERVER_ERROR
        return None
    if any(_is_unreachable(link) for link in chain):
        return TRAFFIC_UNREACHABLE
    return None


def record_traffic_outcome(
    bind,
    source_id: str,
    error: str | None,
    *,
    clock=time.monotonic,
) -> None:
    """Record what one reader's own request just learned about a source.

    ``error`` is None for a success or a message from
    :func:`source_side_failure`; callers pass nothing at all for an outcome that
    says nothing (a timeout, a 404, an empty answer).

    Writes through a session of its OWN on ``bind``, never the caller's: the
    request's session may be partway through work of its own that this commit
    must not publish, and it may be the one a bulk fan-out is sharing across
    threads. The write policy is ``record_outcomes``', so a source whose state
    already matches costs one indexed read and no write.

    Never raises. Recording a diagnostic must not turn a reader's successful
    request into an error, nor replace the upstream error they should see.
    """
    if bind is None:
        return
    if error is not None:
        now = clock()
        with _traffic_lock:
            last = _traffic_failed_at.get(source_id)
            if last is not None and now - last < TRAFFIC_FAILURE_SPACING.total_seconds():
                return
            _traffic_failed_at[source_id] = now
    try:
        with Session(bind=bind, autoflush=False, expire_on_commit=False) as db:
            record_outcomes(db, {source_id: error})
    except Exception:  # noqa: BLE001 - diagnostics never fail a read
        logger.warning("source health not recorded for %s", source_id, exc_info=True)


def summarize(states: Iterable[SourceHealthState]) -> dict[str, int]:
    """Counts by status for a status page, plus how many are demoted.

    Callers pass the states of the sources *they* can see, so the summary is
    scoped by the caller's mature gate like everything else.
    """
    counts = {
        "total": 0,
        STATUS_OK: 0,
        STATUS_FAILING: 0,
        STATUS_DEAD: 0,
        STATUS_UNKNOWN: 0,
        "demoted": 0,
    }
    for state in states:
        counts["total"] += 1
        counts[state.status] = counts.get(state.status, 0) + 1
        if state.demoted:
            counts["demoted"] += 1
    return counts
