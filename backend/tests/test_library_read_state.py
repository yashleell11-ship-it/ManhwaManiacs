"""``read_state`` on the library list: where this profile stands in each series.

Every follow used to say "Reading" — the follow default nobody changes — so a
library used as a to-read list could not tell a started series from one never
opened. The list now carries, per card, whether the profile has opened a
chapter, the furthest one (by reading order), and how many lie past it.
"""

from __future__ import annotations

import json
from datetime import timedelta

import pytest
from sqlalchemy import event

from core.time_utils import utcnow
from services.followed_series_service import FollowedSeriesService
from tests._fakes import FakeBrowse


def _chapters(numbers, *, prefix="ch"):
    return json.dumps(
        [
            {"key": f"{prefix}-{n}", "number": n, "title": f"Chapter {n}"}
            for n in numbers
        ]
    )


FIVE = _chapters([1.0, 2.0, 3.0, 4.0, 5.0])


@pytest.fixture
def owner(make_user, make_profile):
    user = make_user("read-state-owner")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _svc(db, user_id, profile_id):
    return FollowedSeriesService(
        db, FakeBrowse(), user_id=user_id, profile_id=profile_id
    )


def _states(db, user_id, profile_id):
    items = _svc(db, user_id, profile_id).list_series(per_page=200)["items"]
    return {item["series_key"]: item["read_state"] for item in items}


def test_a_series_never_opened_is_not_started(db_session, owner, seed_follow):
    user_id, profile_id = owner
    seed_follow(user_id, profile_id, series_key="s1", known_chapters=FIVE)

    state = _states(db_session, user_id, profile_id)["s1"]

    assert state == {
        "started": False,
        "chapter_key": None,
        "chapter_number": None,
        "position": None,
        "total": 5,
        "latest_number": None,
        "new_count": None,
    }


def test_the_furthest_chapter_wins_over_the_most_recent_one(
    db_session, owner, seed_follow, seed_progress
):
    """Going back to reread chapter 2 does not move the reader off chapter 4."""
    user_id, profile_id = owner
    now = utcnow()
    seed_follow(user_id, profile_id, series_key="s1", known_chapters=FIVE)
    seed_progress(
        user_id, profile_id, series_key="s1", chapter_key="ch-4.0",
        chapter_number=4.0, last_read_at=now - timedelta(days=2),
    )
    seed_progress(
        user_id, profile_id, series_key="s1", chapter_key="ch-2.0",
        chapter_number=2.0, last_read_at=now,
    )

    state = _states(db_session, user_id, profile_id)["s1"]

    assert state["started"] is True
    assert state["chapter_key"] == "ch-4.0"
    assert state["chapter_number"] == 4.0
    assert state["position"] == 4
    assert state["total"] == 5
    assert state["latest_number"] == 5.0
    assert state["new_count"] == 1


def test_a_newest_first_listing_still_counts_forward(
    db_session, owner, seed_follow, seed_progress
):
    """Connectors that list newest-first must not make chapter 1 the furthest."""
    user_id, profile_id = owner
    seed_follow(
        user_id, profile_id, series_key="s1",
        known_chapters=_chapters([5.0, 4.0, 3.0, 2.0, 1.0]),
    )
    seed_progress(user_id, profile_id, series_key="s1", chapter_key="ch-2.0",
                  chapter_number=2.0)

    state = _states(db_session, user_id, profile_id)["s1"]

    assert state["position"] == 2
    assert state["new_count"] == 3
    assert state["latest_number"] == 5.0


def test_position_is_list_position_and_number_is_the_printed_one(
    db_session, owner, seed_follow, seed_progress
):
    """A prologue puts the list one ahead of the printed numbers."""
    user_id, profile_id = owner
    seed_follow(
        user_id, profile_id, series_key="s1",
        known_chapters=_chapters([0.0, 1.0, 2.0, 3.0]),
    )
    seed_progress(user_id, profile_id, series_key="s1", chapter_key="ch-2.0",
                  chapter_number=2.0)

    state = _states(db_session, user_id, profile_id)["s1"]

    assert state["position"] == 3
    assert state["chapter_number"] == 2.0
    assert state["latest_number"] == 3.0
    assert state["total"] == 4
    assert state["new_count"] == 1


def test_a_chapter_the_list_no_longer_carries_is_started_without_a_position(
    db_session, owner, seed_follow, seed_progress
):
    user_id, profile_id = owner
    seed_follow(user_id, profile_id, series_key="s1", known_chapters=FIVE)
    seed_progress(user_id, profile_id, series_key="s1", chapter_key="pulled",
                  chapter_number=7.0)

    state = _states(db_session, user_id, profile_id)["s1"]

    assert state["started"] is True
    assert state["position"] is None
    assert state["new_count"] is None
    assert state["chapter_number"] == 7.0
    assert state["total"] == 5


def test_another_profiles_reading_does_not_start_this_profiles_card(
    db_session, owner, make_user, make_profile, seed_follow, seed_progress
):
    user_id, profile_id = owner
    sibling = make_profile(user_id, "Sibling")
    stranger = make_user("read-state-stranger")
    stranger_profile = make_profile(stranger.id, "Theirs")
    for uid, pid in ((user_id, profile_id), (user_id, sibling.id),
                     (stranger.id, stranger_profile.id)):
        seed_follow(uid, pid, series_key="s1", known_chapters=FIVE)
    seed_progress(user_id, sibling.id, series_key="s1", chapter_key="ch-3.0",
                  chapter_number=3.0)
    seed_progress(stranger.id, stranger_profile.id, series_key="s1",
                  chapter_key="ch-5.0", chapter_number=5.0)

    assert _states(db_session, user_id, profile_id)["s1"]["started"] is False
    assert _states(db_session, user_id, sibling.id)["s1"]["position"] == 3


def test_the_whole_page_costs_one_progress_query(
    db_session, owner, seed_follow, seed_progress
):
    """Hundreds of follows must not mean hundreds of queries."""
    user_id, profile_id = owner
    for n in range(30):
        seed_follow(user_id, profile_id, series_key=f"s{n}", known_chapters=FIVE)
        seed_progress(user_id, profile_id, series_key=f"s{n}",
                      chapter_key="ch-3.0", chapter_number=3.0)

    seen: list[str] = []

    @event.listens_for(db_session.bind, "before_cursor_execute")
    def _capture(conn, cursor, statement, params, context, many):  # noqa: ANN001
        seen.append(statement)

    try:
        items = _svc(db_session, user_id, profile_id).list_series(per_page=200)[
            "items"
        ]
    finally:
        event.remove(db_session.bind, "before_cursor_execute", _capture)

    assert len(items) == 30
    assert all(i["read_state"]["position"] == 3 for i in items)
    progress_reads = [s for s in seen if "chapter_progress" in s]
    assert len(progress_reads) == 1, progress_reads


def test_only_the_requested_page_is_computed(
    db_session, owner, seed_follow, seed_progress
):
    user_id, profile_id = owner
    for n in range(3):
        seed_follow(user_id, profile_id, series_key=f"s{n}", title=f"T{n}",
                    known_chapters=FIVE)
    seed_progress(user_id, profile_id, series_key="s1", chapter_key="ch-1.0")

    page = _svc(db_session, user_id, profile_id).list_series(page=2, per_page=1)

    assert [(i["series_key"], i["read_state"]["started"]) for i in page["items"]] == [
        ("s1", True)
    ]


def test_patch_answers_with_the_read_state_the_list_had(
    db_session, owner, seed_follow, seed_progress
):
    """The phone swaps a patched row into its list as-is."""
    user_id, profile_id = owner
    row = seed_follow(user_id, profile_id, series_key="s1", known_chapters=FIVE)
    seed_progress(user_id, profile_id, series_key="s1", chapter_key="ch-4.0",
                  chapter_number=4.0)

    patched = _svc(db_session, user_id, profile_id).patch(row.id, is_favorite=True)

    assert patched["read_state"]["position"] == 4
    assert patched["read_state"]["new_count"] == 1


def test_the_list_endpoint_carries_read_state(
    client, as_user, db_session, owner, seed_follow, seed_progress
):
    user_id, profile_id = owner
    seed_follow(user_id, profile_id, series_key="s1", known_chapters=FIVE)
    seed_follow(user_id, profile_id, series_key="s2", title="Other",
                known_chapters=FIVE)
    seed_progress(user_id, profile_id, series_key="s1", chapter_key="ch-5.0",
                  chapter_number=5.0)

    body = client.get("/library/series", headers=as_user(user_id, profile_id)).json()

    by_key = {i["series_key"]: i["read_state"] for i in body["items"]}
    assert by_key["s1"]["position"] == 5
    assert by_key["s1"]["new_count"] == 0
    assert by_key["s2"]["started"] is False
