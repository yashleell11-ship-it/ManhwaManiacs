"""Which sources a search should ask FIRST.

A federated search fans out to every browsable connector at once — 91 of them
with novels on — under a 12s whole-request budget, measured at 10.8s. Almost
every hit the owner actually wants comes from the handful of sources he has
pinned or already follows, and those answer in under two seconds. So the search
asks those first and returns them, then fills in the rest behind.

The set is per-(user, profile), and it is INTERSECTED with the visible
descriptor list rather than merely ordered by it. That intersection is what
holds the 18+ gate: ``source_pin_service`` says in its own docstring that a pin
made while the gate was open is retained in the row and only omitted on read,
and ``followed_series`` rows are not filtered at all. Ordering a tier by those
rows would therefore walk a mature source straight past a shut gate.
"""

from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from connectors.registry import REQUIRED_BROWSABLE_CONNECTORS
from database.models import FollowedSeries, SourcePin

#: How many sources the fast lane may hold. Someone who has pinned thirty
#: sources should not get a "fast" tier as slow as querying everything.
TIER_ONE_LIMIT = 12


def tier_one_source_ids(
    db: Session,
    *,
    user_id: int | None,
    profile_id: int | None,
    visible_ids: set[str],
    limit: int = TIER_ONE_LIMIT,
) -> list[str]:
    """The caller's own sources, in the order worth asking them.

    Pins first, in the order the owner arranged them, then the sources they
    follow most series from. The ORDER BY clauses are load-bearing rather than
    cosmetic: tier 1 and tier 2 are two separate requests within one search, and
    the split between them must be identical across both, so it can never depend
    on SQLite's natural row order.

    Falls back to the required browsable connectors when the caller has neither
    pins nor follows. A brand-new account — this instance has one — would
    otherwise get an empty fast lane, i.e. a blank screen until tier 2 lands,
    which is strictly worse than not tiering at all.
    """
    if user_id is None or not visible_ids:
        return sorted(REQUIRED_BROWSABLE_CONNECTORS & visible_ids)

    pinned = list(
        db.execute(
            select(SourcePin.source_id)
            .where(
                SourcePin.user_id == user_id,
                SourcePin.profile_id == profile_id,
            )
            .order_by(SourcePin.sort_order, SourcePin.id)
        ).scalars()
    )

    # Mirrors FollowedSeriesService._scope, which is LENIENT about a null
    # profile: resolve_profile_context lets a missing or foreign X-Profile-Id
    # resolve to the unscoped bucket, and an exact `== None` comparison would
    # quietly match nothing for those callers.
    follows_stmt = select(
        FollowedSeries.source_id, func.count().label("n")
    ).where(FollowedSeries.user_id == user_id)
    if profile_id is None:
        follows_stmt = follows_stmt.where(FollowedSeries.profile_id.is_(None))
    else:
        follows_stmt = follows_stmt.where(FollowedSeries.profile_id == profile_id)
    followed = list(
        db.execute(
            follows_stmt.group_by(FollowedSeries.source_id).order_by(
                func.count().desc(), FollowedSeries.source_id.asc()
            )
        ).scalars()
    )

    ordered: list[str] = []
    seen: set[str] = set()
    for source_id in (*pinned, *followed):
        if source_id in seen or source_id not in visible_ids:
            continue
        seen.add(source_id)
        ordered.append(source_id)
        if len(ordered) >= limit:
            break

    if ordered:
        return ordered
    return sorted(REQUIRED_BROWSABLE_CONNECTORS & visible_ids)
