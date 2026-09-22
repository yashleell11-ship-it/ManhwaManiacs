"""Re-check sources nobody follows, so a dead one can come back.

The daily sweep records health for every source the household FOLLOWS, which is
what gives those a recovery path. It can never reach the rest: harimanga and
coffeemanga sat at the failure ceiling from 2026-09-03 with ``last_ok_at`` null
and were never re-checked once, because nobody follows them and the only other
writer was the search fan-out — i.e. the owner personally typing a query while
that source happened to answer.

So the sources most likely to be marked dead were exactly the ones nothing could
ever un-mark. This closes that, cheaply: a small batch per scheduler tick, under
the search HTTP budget, on the scheduler thread.

Deliberately NOT a full registry probe. 91 sources at even a few seconds each
would be minutes of upstream traffic on a 2 vCPU box shared with a Minecraft
stack and another project, for information nobody is waiting on.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from connectors.registry import create_connector, list_installed_connectors
from core.time_utils import utcnow
from services.source_health import (
    MAX_STREAK,
    load_states,
    record_outcomes,
)

logger = logging.getLogger(__name__)

#: A source we have never heard from, or one whose last word is old enough to be
#: worth re-asking.
REPROBE_INTERVAL = timedelta(hours=24)

#: A source at the failure ceiling has earned a longer rest. Re-asking a site
#: that has failed ten times running, every day, is traffic spent to learn
#: nothing — but never re-asking is how one ends up wrong for a fortnight.
#:
#: Two days, not the seven this started at. The rest is also exactly how long a
#: source that has come BACK stays labelled dead, and for a source nobody
#: follows this re-probe is the only thing that can clear it: manhuanext hit
#: the ceiling on 2026-09-20, answered list, search, series and chapters from
#: the VPS on 2026-09-23, and would have read "dead" until 2026-09-27. The
#: saving a week bought was small, because dead sources do not stay registered
#: here (one that fails end to end is deleted), so the ceiling only ever holds
#: a handful, and each probe is one listing page: two days costs a few requests
#: a week against days of a working source shown as gone.
DEAD_BACKOFF = timedelta(days=2)

#: Sources per tick. Small on purpose: this is background work with no reader
#: waiting on it, and the box is shared.
BATCH = 6

#: Wall-clock ceiling for one batch, so a run of wedged sites cannot hold the
#: scheduler thread. Checked between probes, not inside one.
BUDGET_SECONDS = 60.0


def select_reprobe_targets(
    db: Session,
    candidates: list[str],
    *,
    now: datetime | None = None,
    limit: int = BATCH,
    interval: timedelta = REPROBE_INTERVAL,
    dead_backoff: timedelta = DEAD_BACKOFF,
) -> list[str]:
    """Which sources are due a re-check, worst-known first.

    Never-seen sources sort first: an unknown source is the one where a probe
    buys the most. Then the longest-unchecked. A source at the ceiling waits
    ``dead_backoff`` rather than ``interval``.

    Pure selection — no I/O beyond reading the health table — so the ordering
    can be tested without touching a network.
    """
    moment = now or utcnow()
    states = load_states(db)

    due: list[tuple[int, datetime, str]] = []
    for source_id in candidates:
        state = states.get(source_id)
        if state is None or state.last_checked_at is None:
            # Never observed. Rank 0 and a floor timestamp so these come first.
            due.append((0, datetime.min, source_id))
            continue
        wait = dead_backoff if state.consecutive_failures >= MAX_STREAK else interval
        if moment - state.last_checked_at < wait:
            continue
        due.append((1, state.last_checked_at, source_id))

    due.sort(key=lambda row: (row[0], row[1], row[2]))
    return [source_id for _, _, source_id in due[:limit]]


def reprobe_sources(
    db: Session,
    *,
    now: datetime | None = None,
    limit: int = BATCH,
    budget_seconds: float = BUDGET_SECONDS,
    clock=None,
) -> dict[str, str | None]:
    """Probe a batch of due sources and record what they said.

    Returns the outcome map it recorded, so a caller (and a test) can see what
    happened without reading the table back.

    A probe is one listing page — the same call ``scripts/probe_all_connectors``
    makes, and the cheapest thing that distinguishes "the site answers" from
    "the site is gone". An empty listing counts as a FAILURE here, unlike in the
    update sweep: there the empty answer is weighed against a known chapter
    snapshot, whereas a source whose front page has nothing on it is not usable
    for browsing whatever the reason.
    """
    tick = clock or __import__("time").monotonic
    started = tick()

    candidates = [
        descriptor.source_type
        for descriptor in list_installed_connectors(
            browsable_only=True, include_mature=True
        )
    ]
    targets = select_reprobe_targets(db, candidates, now=now, limit=limit)
    if not targets:
        return {}

    outcomes: dict[str, str | None] = {}
    for source_id in targets:
        if tick() - started >= budget_seconds:
            logger.debug("source re-probe stopped at its budget")
            break
        try:
            connector = create_connector(source_id)
            listing = connector.get_series_list(1)
            outcomes[source_id] = (
                None if listing and listing.items else "The source returned nothing."
            )
        except Exception as exc:  # noqa: BLE001 - one bad source never stops the batch
            # A fixed phrase, never str(exc): source_health is GLOBAL and served
            # to every account, and an upstream exception routinely embeds the
            # full request URL with its query string.
            logger.debug("re-probe failed for %s: %s", source_id, exc)
            outcomes[source_id] = "The source could not be reached."

    if outcomes:
        record_outcomes(db, outcomes, now=now)
    return outcomes
