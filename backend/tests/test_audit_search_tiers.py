"""Search asks the caller's own sources first.

A federated search fans out to every browsable connector at once — 91 with
novels on — under a 12s budget, measured at 10.8s in browse_service's own
comment. Nearly every hit worth having comes from the few sources the owner
pinned or already follows, and those answer in under two seconds.

The rules that matter here are not about speed, they are about what the split
must never do: leak past the 18+ gate, leak across profiles, or come out
different on the two requests of one search.
"""

from __future__ import annotations

import pytest
from connectors.registry import REQUIRED_BROWSABLE_CONNECTORS
from database.models import SourcePin
from services.search_tiers import TIER_ONE_LIMIT, tier_one_source_ids

VISIBLE = {"asurascans", "mangadex", "novelarchive", "mangabuddy", "flamescans"}


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("reader")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _pin(db, uid, pid, source_id, order=0):
    db.add(
        SourcePin(user_id=uid, profile_id=pid, source_id=source_id, sort_order=order)
    )
    db.commit()


def test_a_new_account_gets_a_usable_fast_lane(db_session, acct):
    # No pins, no follows — this instance has such an account. An empty tier 1
    # would mean a blank screen until tier 2 lands, which is worse than not
    # tiering at all.
    uid, pid = acct

    ids = tier_one_source_ids(
        db_session, user_id=uid, profile_id=pid, visible_ids=VISIBLE
    )

    assert set(ids) == REQUIRED_BROWSABLE_CONNECTORS & VISIBLE
    assert ids


def test_pins_come_first_in_the_order_they_were_arranged(db_session, acct):
    uid, pid = acct
    _pin(db_session, uid, pid, "novelarchive", order=1)
    _pin(db_session, uid, pid, "mangadex", order=0)

    ids = tier_one_source_ids(
        db_session, user_id=uid, profile_id=pid, visible_ids=VISIBLE
    )

    assert ids[:2] == ["mangadex", "novelarchive"]


def test_followed_sources_join_the_fast_lane(db_session, acct, seed_follow):
    uid, pid = acct
    seed_follow(uid, pid, source_id="asurascans", series_key="a")
    seed_follow(uid, pid, source_id="asurascans", series_key="b")
    seed_follow(uid, pid, source_id="novelarchive", series_key="c")

    ids = tier_one_source_ids(
        db_session, user_id=uid, profile_id=pid, visible_ids=VISIBLE
    )

    # Most-followed first, so the source the reader lives in is asked first.
    assert ids == ["asurascans", "novelarchive"]


def test_a_source_the_gate_hides_never_enters_the_fast_lane(db_session, acct):
    # THE security rule. source_pin_service keeps a pin made while the gate was
    # open and only omits it on READ, and followed_series is not filtered at
    # all — so the tier must INTERSECT the visible set, not merely order by it.
    uid, pid = acct
    _pin(db_session, uid, pid, "hentai20")

    ids = tier_one_source_ids(
        db_session, user_id=uid, profile_id=pid, visible_ids=VISIBLE
    )

    assert "hentai20" not in ids


def test_another_profile_pins_do_not_leak(db_session, make_user, make_profile):
    a = make_user("alice")
    b = make_user("bob")
    pa = make_profile(a.id, "A")
    pb = make_profile(b.id, "B")
    _pin(db_session, b.id, pb.id, "novelarchive")

    ids = tier_one_source_ids(
        db_session, user_id=a.id, profile_id=pa.id, visible_ids=VISIBLE
    )

    assert "novelarchive" not in ids


def test_a_null_profile_falls_back_rather_than_erroring(db_session, make_user):
    # resolve_profile_context is lenient — a missing or foreign X-Profile-Id
    # resolves to the unscoped bucket — so this caller reaches here with
    # profile_id None. followed_series.profile_id is NOT NULL, so such a caller
    # can have no follows by construction and the lenient branch mirroring
    # FollowedSeriesService._scope is unreachable for this table; what matters
    # is that the query is still well-formed and the caller gets a usable lane
    # instead of an empty one or a 500.
    user = make_user("nullprof")

    ids = tier_one_source_ids(
        db_session, user_id=user.id, profile_id=None, visible_ids=VISIBLE
    )

    assert set(ids) == REQUIRED_BROWSABLE_CONNECTORS & VISIBLE


def test_the_fast_lane_is_capped(db_session, acct, seed_follow):
    # Someone who follows thirty sources should not get a "fast" tier as slow
    # as querying everything.
    uid, pid = acct
    visible = {f"src{i}" for i in range(TIER_ONE_LIMIT + 8)}
    for i in range(TIER_ONE_LIMIT + 8):
        seed_follow(uid, pid, source_id=f"src{i}", series_key=f"s{i}")

    ids = tier_one_source_ids(
        db_session, user_id=uid, profile_id=pid, visible_ids=visible
    )

    assert len(ids) == TIER_ONE_LIMIT


def test_the_split_is_stable_across_the_two_requests(db_session, acct, seed_follow):
    # Tier 1 and tier 2 are separate requests within ONE search. If the order
    # were not pinned by an explicit ORDER BY, the complement could differ
    # between them and a source would be asked twice or not at all.
    uid, pid = acct
    for i in range(5):
        seed_follow(uid, pid, source_id=f"src{i}", series_key=f"s{i}")
    visible = {f"src{i}" for i in range(5)}

    first = tier_one_source_ids(
        db_session, user_id=uid, profile_id=pid, visible_ids=visible
    )
    again = tier_one_source_ids(
        db_session, user_id=uid, profile_id=pid, visible_ids=visible
    )

    assert first == again


def test_an_anonymous_caller_gets_the_fallback(db_session):
    ids = tier_one_source_ids(
        db_session, user_id=None, profile_id=None, visible_ids=VISIBLE
    )

    assert set(ids) == REQUIRED_BROWSABLE_CONNECTORS & VISIBLE
