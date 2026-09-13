"""Recent activity lists SITTINGS, not pings.

``progress_service`` appends a ``reading_sessions`` row per advance, which is
right for the totals and wrong for a list a human reads. The live table showed
what that costs: twelve rows for one chapter, "1 page" each, 06:27 to 06:50 on
one evening -- and the three chapters read before it pushed off a ten-row list
by a single sitting.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest
from services.reading_stats_service import SESSION_SECONDS_CAP, ReadingStatsService

SRC = "asurascans"
SERIES = "the-great-mage-returns"

#: A fixed instant so nothing here depends on when the suite runs.
NOON = datetime(2026, 9, 9, 12, 0, 0)


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("reader")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _stats(db, uid, pid, *, tz=0):
    return ReadingStatsService(
        db, user_id=uid, profile_id=pid, gate_open=True, tz_offset_minutes=tz
    )


def test_one_evening_with_one_chapter_is_one_row(
    db_session, acct, seed_follow, seed_session
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    for i in range(12):
        seed_session(
            uid, pid,
            source_id=SRC, series_key=SERIES, chapter_key="ch-273",
            chapter_number=273.0, pages_read=1,
            started_at=NOON + timedelta(minutes=2 * i), duration_seconds=120,
        )

    recent = _stats(db_session, uid, pid)._recent()

    assert len(recent) == 1, f"twelve pings rendered as {len(recent)} rows"
    assert recent[0]["pages_read"] == 12
    assert recent[0]["sessions"] == 12
    assert recent[0]["seconds_read"] == 12 * 120


def test_the_seconds_cap_is_per_ping_and_is_not_reapplied_to_the_sitting(
    db_session, acct, seed_follow, seed_session
):
    # THE trap. SESSION_SECONDS_CAP is a per-row policy -- duration is stored
    # raw precisely so the cap stays a read-time decision. Capping the MERGED
    # group instead would silently shrink every long sitting to one hour, and
    # nothing would report an error.
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    for i, seconds in enumerate((5000, 4000, 100)):
        seed_session(
            uid, pid,
            source_id=SRC, series_key=SERIES, chapter_key="ch-1",
            started_at=NOON + timedelta(minutes=i), duration_seconds=seconds,
        )

    recent = _stats(db_session, uid, pid)._recent()

    # 5000 and 4000 each clamp to 3600; 100 stays 100.
    expected = SESSION_SECONDS_CAP + SESSION_SECONDS_CAP + 100
    assert len(recent) == 1
    assert recent[0]["seconds_read"] == expected, (
        "the cap was applied to the merged sitting rather than to each ping"
    )
    assert recent[0]["seconds_read"] > SESSION_SECONDS_CAP


def test_sittings_sort_by_their_last_ping(
    db_session, acct, seed_follow, seed_session
):
    # A bare column beside a GROUP BY is legal in SQLite and picks an arbitrary
    # row from the group, which would order this list by nothing in particular.
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    # A started EARLIER but ran LATER; B is a single ping in between.
    seed_session(uid, pid, source_id=SRC, series_key=SERIES, chapter_key="A",
                 started_at=NOON, duration_seconds=60)
    seed_session(uid, pid, source_id=SRC, series_key=SERIES, chapter_key="B",
                 started_at=NOON + timedelta(minutes=30), duration_seconds=60)
    seed_session(uid, pid, source_id=SRC, series_key=SERIES, chapter_key="A",
                 started_at=NOON + timedelta(minutes=50), duration_seconds=60)

    recent = _stats(db_session, uid, pid)._recent()

    assert [r["chapter_key"] for r in recent] == ["A", "B"]
    assert recent[0]["started_at"].startswith("2026-09-09T12:00"), (
        "a sitting should start at its FIRST ping"
    )


def test_a_sitting_is_split_at_the_reader_own_midnight(
    db_session, acct, seed_follow, seed_session
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    # 18:00Z and 19:00Z on one UTC date. In IST (+330) those straddle midnight.
    seed_session(uid, pid, source_id=SRC, series_key=SERIES, chapter_key="ch-1",
                 started_at=datetime(2026, 9, 9, 18, 0), duration_seconds=60)
    seed_session(uid, pid, source_id=SRC, series_key=SERIES, chapter_key="ch-1",
                 started_at=datetime(2026, 9, 9, 19, 0), duration_seconds=60)

    assert len(_stats(db_session, uid, pid, tz=0)._recent()) == 1
    ist = _stats(db_session, uid, pid, tz=330)._recent()
    assert len(ist) == 2, "grouped on the UTC day rather than the reader's"
    assert ist[0]["day"] != ist[1]["day"]


def test_keys_containing_slashes_stay_distinct(
    db_session, acct, seed_follow, seed_session
):
    # Connector keys routinely contain slashes. Folding the group key into
    # source||series||chapter would merge ("a/b","c") with ("a","b/c").
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key="a/b")
    seed_follow(uid, pid, source_id=SRC, series_key="a")
    seed_session(uid, pid, source_id=SRC, series_key="a/b", chapter_key="c",
                 started_at=NOON, duration_seconds=60)
    seed_session(uid, pid, source_id=SRC, series_key="a", chapter_key="b/c",
                 started_at=NOON + timedelta(minutes=1), duration_seconds=60)

    recent = _stats(db_session, uid, pid)._recent()

    assert len(recent) == 2, "two different chapters folded into one sitting"


def test_one_sitting_does_not_crowd_out_older_chapters(
    db_session, acct, seed_follow, seed_session
):
    # The observed failure: a ten-row list entirely consumed by one evening.
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    for i in range(12):
        seed_session(
            uid, pid, source_id=SRC, series_key=SERIES, chapter_key="ch-273",
            started_at=NOON + timedelta(minutes=i), duration_seconds=60,
        )
    for n in (270, 271, 272):
        seed_session(
            uid, pid, source_id=SRC, series_key=SERIES, chapter_key=f"ch-{n}",
            started_at=NOON - timedelta(days=273 - n), duration_seconds=60,
        )

    recent = _stats(db_session, uid, pid)._recent()

    keys = [r["chapter_key"] for r in recent]
    assert keys[0] == "ch-273"
    for n in (270, 271, 272):
        assert f"ch-{n}" in keys, (
            f"ch-{n} was pushed off the list by one evening's pings"
        )


def test_another_profile_sittings_are_not_merged_in(
    db_session, make_user, make_profile, seed_follow, seed_session
):
    # _sessions() is the only thing applying the profile scope and the 18+
    # predicate; a hand-written GROUP BY that skipped it would merge two
    # people's reading into one row.
    a = make_user("alice")
    b = make_user("bob")
    pa = make_profile(a.id, "A")
    pb = make_profile(b.id, "B")
    seed_follow(a.id, pa.id, source_id=SRC, series_key=SERIES)
    seed_follow(b.id, pb.id, source_id=SRC, series_key=SERIES)
    seed_session(a.id, pa.id, source_id=SRC, series_key=SERIES, chapter_key="ch-1",
                 pages_read=3, started_at=NOON, duration_seconds=60)
    seed_session(b.id, pb.id, source_id=SRC, series_key=SERIES, chapter_key="ch-1",
                 pages_read=99, started_at=NOON, duration_seconds=60)

    recent = _stats(db_session, a.id, pa.id)._recent()

    assert len(recent) == 1
    assert recent[0]["pages_read"] == 3, "Bob's pages were counted as Alice's"
