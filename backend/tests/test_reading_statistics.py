"""``GET /library/statistics`` over ``reading_sessions`` (spec §5.2, §7).

One test per metric, plus the two invariants that outrank every metric: the
numbers are scoped to one ``(user_id, profile_id)``, and a mature series stays
out of every one of them while the 18+ gate is shut.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from core.time_utils import utcnow
from services.followed_series_service import FollowedSeriesService
from services.reading_stats_service import SESSION_SECONDS_CAP, ReadingStatsService
from tests._fakes import FakeBrowse

MATURE_SOURCE = "nhentai"


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("statsowner")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _stats(db, user_id, profile_id, *, gate_open=True, tz=0):
    return ReadingStatsService(
        db,
        user_id=user_id,
        profile_id=profile_id,
        gate_open=gate_open,
        tz_offset_minutes=tz,
    )


def _days_ago(n: int, *, hour: int = 12) -> datetime:
    return datetime.combine(
        (utcnow() - timedelta(days=n)).date(), datetime.min.time()
    ) + timedelta(hours=hour)


# --- empty profile -------------------------------------------------------


def test_empty_profile_returns_a_dense_zeroed_payload(db_session, acct):
    uid, pid = acct
    out = _stats(db_session, uid, pid).build(14)

    assert out["totals"] == {
        "sessions": 0,
        "pages_read": 0,
        "chapters_read": 0,
        "series_read": 0,
        "seconds_read": 0,
        "first_session_at": None,
        "last_session_at": None,
    }
    assert out["streak"] == {
        "current_days": 0,
        "longest_days": 0,
        "last_active_date": None,
    }
    # Dense even with nothing to show: a chart must be able to draw 14 columns.
    assert len(out["daily"]) == 14
    assert {d["pages_read"] for d in out["daily"]} == {0}
    assert len(out["by_hour"]) == 24
    assert out["by_source"] == []
    assert out["by_series"] == []
    assert out["recent_sessions"] == []


# --- totals ---------------------------------------------------------------


def test_totals_count_pages_and_deduplicate_chapters_and_series(
    db_session, acct, seed_session
):
    uid, pid = acct
    # Same chapter read twice: two sessions, one chapter.
    seed_session(uid, pid, series_key="a", chapter_key="c1", pages_read=10)
    seed_session(uid, pid, series_key="a", chapter_key="c1", pages_read=4)
    seed_session(uid, pid, series_key="a", chapter_key="c2", pages_read=20)
    seed_session(uid, pid, series_key="b", chapter_key="c1", pages_read=7)

    totals = _stats(db_session, uid, pid).build(30)["totals"]
    assert totals["sessions"] == 4
    assert totals["pages_read"] == 41
    assert totals["chapters_read"] == 3  # (a,c1) (a,c2) (b,c1)
    assert totals["series_read"] == 2


def test_chapter_identity_survives_keys_that_collide_naively(
    db_session, acct, seed_session
):
    """Connector keys are opaque and may contain slashes/percent-escapes.

    Folding the composite key into one string for ``COUNT(DISTINCT ...)`` must
    not let ``("a/b", "c")`` and ``("a", "b/c")`` collapse into one chapter.
    """
    uid, pid = acct
    seed_session(uid, pid, series_key="a/b", chapter_key="c")
    seed_session(uid, pid, series_key="a", chapter_key="b/c")

    totals = _stats(db_session, uid, pid).build(30)["totals"]
    assert totals["chapters_read"] == 2
    assert totals["series_read"] == 2


def test_first_and_last_session_timestamps(db_session, acct, seed_session):
    uid, pid = acct
    seed_session(uid, pid, chapter_key="old", started_at=_days_ago(200))
    seed_session(uid, pid, chapter_key="new", started_at=_days_ago(1))

    totals = _stats(db_session, uid, pid).build(7)["totals"]
    assert totals["first_session_at"].startswith(_days_ago(200).date().isoformat())
    assert totals["last_session_at"].startswith(_days_ago(1).date().isoformat())
    # ...while the 7-day window sees only the recent one.
    assert _stats(db_session, uid, pid).build(7)["window"]["sessions"] == 1


# --- time spent -----------------------------------------------------------


def test_session_duration_is_capped(db_session, acct, seed_session):
    """A chapter left open overnight is a client that stopped talking."""
    uid, pid = acct
    seed_session(uid, pid, chapter_key="c1", duration_seconds=9 * 3600)

    assert (
        _stats(db_session, uid, pid).build(7)["totals"]["seconds_read"]
        == SESSION_SECONDS_CAP
    )


def test_unclosed_and_backwards_sessions_contribute_no_time(
    db_session, acct, seed_session
):
    uid, pid = acct
    start = _days_ago(1)
    seed_session(uid, pid, chapter_key="open", started_at=start, duration_seconds=None)
    # A skewed client clock: ended before started. Must clamp to 0, never
    # subtract from the day's total.
    seed_session(
        uid,
        pid,
        chapter_key="backwards",
        started_at=start,
        ended_at=start - timedelta(minutes=30),
    )
    seed_session(uid, pid, chapter_key="real", started_at=start, duration_seconds=300)

    out = _stats(db_session, uid, pid).build(7)
    assert out["totals"]["seconds_read"] == 300
    assert out["totals"]["sessions"] == 3
    assert out["range"]["session_cap_seconds"] == SESSION_SECONDS_CAP


# --- daily series + timezone ---------------------------------------------


def test_daily_series_is_dense_and_bucketed(db_session, acct, seed_session):
    uid, pid = acct
    seed_session(uid, pid, chapter_key="c0", started_at=_days_ago(0), pages_read=5)
    seed_session(uid, pid, chapter_key="c2a", started_at=_days_ago(2), pages_read=6)
    seed_session(uid, pid, chapter_key="c2b", started_at=_days_ago(2), pages_read=1)

    daily = _stats(db_session, uid, pid).build(5)["daily"]
    assert [d["date"] for d in daily] == [
        (utcnow() - timedelta(days=n)).date().isoformat() for n in (4, 3, 2, 1, 0)
    ]
    by_date = {d["date"]: d for d in daily}
    today = utcnow().date().isoformat()
    two = (utcnow() - timedelta(days=2)).date().isoformat()
    assert by_date[today]["pages_read"] == 5
    assert by_date[two]["pages_read"] == 7
    assert by_date[two]["sessions"] == 2
    assert by_date[two]["chapters_read"] == 2
    one = (utcnow() - timedelta(days=1)).date().isoformat()
    assert by_date[one]["pages_read"] == 0  # zero-filled, not omitted


def test_days_are_bucketed_at_the_requested_offset_not_server_local(
    db_session, acct, seed_session
):
    """22:30 UTC is "tomorrow" in Kolkata (+05:30) and "today" in UTC."""
    uid, pid = acct
    utc_day = utcnow().date() - timedelta(days=1)
    seed_session(
        uid,
        pid,
        chapter_key="late",
        started_at=datetime.combine(utc_day, datetime.min.time())
        + timedelta(hours=22, minutes=30),
    )

    at_utc = _stats(db_session, uid, pid, tz=0).build(3)
    at_ist = _stats(db_session, uid, pid, tz=330).build(3)

    assert at_utc["range"]["timezone_offset_minutes"] == 0
    assert at_ist["range"]["timezone_offset_minutes"] == 330
    assert {d["date"] for d in at_utc["daily"] if d["sessions"]} == {
        utc_day.isoformat()
    }
    assert {d["date"] for d in at_ist["daily"] if d["sessions"]} == {
        (utc_day + timedelta(days=1)).isoformat()
    }


def test_hour_histogram_follows_the_offset(db_session, acct, seed_session):
    uid, pid = acct
    seed_session(uid, pid, chapter_key="c1", started_at=_days_ago(0, hour=3))

    utc_hours = {h["hour"] for h in _stats(db_session, uid, pid).build(7)["by_hour"] if h["sessions"]}
    ist_hours = {
        h["hour"]
        for h in _stats(db_session, uid, pid, tz=330).build(7)["by_hour"]
        if h["sessions"]
    }
    assert utc_hours == {3}
    assert ist_hours == {8}  # 03:00Z + 05:30


# --- streaks --------------------------------------------------------------


def test_streak_counts_consecutive_days_and_keeps_the_longest(
    db_session, acct, seed_session
):
    uid, pid = acct
    # A 4-day run that ended a week ago, then a 2-day run ending today.
    for n in (12, 11, 10, 9, 1, 0):
        seed_session(uid, pid, chapter_key=f"c{n}", started_at=_days_ago(n))

    streak = _stats(db_session, uid, pid).build(30)["streak"]
    assert streak["longest_days"] == 4
    assert streak["current_days"] == 2
    assert streak["last_active_date"] == utcnow().date().isoformat()


def test_current_streak_survives_a_day_that_has_not_finished(
    db_session, acct, seed_session
):
    """Read yesterday, nothing yet today: the streak is alive, not broken."""
    uid, pid = acct
    for n in (2, 1):
        seed_session(uid, pid, chapter_key=f"c{n}", started_at=_days_ago(n))

    streak = _stats(db_session, uid, pid).build(30)["streak"]
    assert streak["current_days"] == 2


def test_current_streak_is_zero_after_a_missed_day(db_session, acct, seed_session):
    uid, pid = acct
    for n in (4, 3, 2):
        seed_session(uid, pid, chapter_key=f"c{n}", started_at=_days_ago(n))

    streak = _stats(db_session, uid, pid).build(30)["streak"]
    assert streak["longest_days"] == 3
    assert streak["current_days"] == 0
    assert streak["last_active_date"] == (utcnow() - timedelta(days=2)).date().isoformat()


# --- breakdowns -----------------------------------------------------------


def test_by_source_rolls_up_and_labels_the_source(db_session, acct, seed_session):
    uid, pid = acct
    seed_session(uid, pid, source_id="mangadex", series_key="a", chapter_key="c1", pages_read=30)
    seed_session(uid, pid, source_id="mangadex", series_key="b", chapter_key="c1", pages_read=10)
    seed_session(uid, pid, source_id="weebcentral", series_key="c", chapter_key="c1", pages_read=5)

    rows = _stats(db_session, uid, pid).build(30)["by_source"]
    assert [r["source_id"] for r in rows] == ["mangadex", "weebcentral"]
    assert rows[0]["pages_read"] == 40
    assert rows[0]["series_read"] == 2
    assert rows[0]["name"]  # a human label from the connector registry


def test_by_series_carries_the_follow_row_and_survives_an_unfollow(
    db_session, acct, seed_session, seed_follow
):
    uid, pid = acct
    seed_follow(
        uid, pid, series_key="followed", title="Followed One", cover_url="http://c/1.jpg"
    )
    seed_session(uid, pid, series_key="followed", chapter_key="c1", pages_read=40)
    seed_session(uid, pid, series_key="gone", chapter_key="c1", pages_read=9)

    rows = _stats(db_session, uid, pid).build(30)["by_series"]
    assert [r["series_key"] for r in rows] == ["followed", "gone"]
    assert rows[0]["title"] == "Followed One"
    assert rows[0]["cover_url"] == "http://c/1.jpg"
    assert rows[0]["pages_read"] == 40
    assert "series_read" not in rows[0]  # meaningless inside a per-series group
    # History of an unfollowed series is still history — it just has no title.
    assert rows[1]["title"] is None
    assert rows[1]["pages_read"] == 9


def test_an_unfollowed_series_is_named_from_the_series_cache(
    db_session, acct, seed_session, seed_follow
):
    """Read-but-not-followed history keeps its title when the cache has it.

    Without this the owner's "Most read" led with two raw novelarchive ids,
    though ``source_series_cache`` held "Shadow Slave" for one of them. A
    follow title still wins, and a cache miss still comes back empty rather
    than triggering a source fetch.
    """
    from database.models import SourceSeriesCache

    uid, pid = acct
    seed_follow(uid, pid, series_key="followed", title="Followed One")
    db_session.add_all(
        [
            SourceSeriesCache(
                source_id="mangadex",
                series_key="unfollowed",
                title="Shadow Slave",
                cover_url="http://c/ss.jpg",
            ),
            SourceSeriesCache(
                source_id="mangadex", series_key="followed", title="Cached Name"
            ),
        ]
    )
    db_session.commit()
    seed_session(uid, pid, series_key="unfollowed", chapter_key="c1", pages_read=50)
    seed_session(uid, pid, series_key="followed", chapter_key="c1", pages_read=20)
    seed_session(uid, pid, series_key="uncached", chapter_key="c1", pages_read=5)

    out = _stats(db_session, uid, pid).build(30)
    by_key = {r["series_key"]: r for r in out["by_series"]}
    assert by_key["unfollowed"]["title"] == "Shadow Slave"
    assert by_key["unfollowed"]["cover_url"] == "http://c/ss.jpg"
    assert by_key["followed"]["title"] == "Followed One"
    assert by_key["uncached"]["title"] is None

    recent = {r["series_key"]: r["title"] for r in out["recent_sessions"]}
    assert recent == {
        "unfollowed": "Shadow Slave",
        "followed": "Followed One",
        "uncached": None,
    }


def test_recent_sessions_are_not_clipped_by_the_window(
    db_session, acct, seed_session, seed_follow
):
    uid, pid = acct
    seed_follow(uid, pid, series_key="a", title="A Series")
    seed_session(
        uid, pid, series_key="a", chapter_key="old", started_at=_days_ago(90), pages_read=3
    )

    out = _stats(db_session, uid, pid).build(7)
    assert out["window"]["sessions"] == 0
    assert [r["chapter_key"] for r in out["recent_sessions"]] == ["old"]
    assert out["recent_sessions"][0]["title"] == "A Series"
    assert out["recent_sessions"][0]["seconds_read"] == 600


# --- profile isolation ----------------------------------------------------


def test_sessions_never_cross_profiles_or_accounts(
    db_session, make_user, make_profile, seed_session
):
    """The invariant that outranks every metric on this screen.

    Reading on a sibling profile (or another account) must not move a single
    number here — the project has shipped and fixed a cross-profile leak once.
    """
    u1 = make_user("iso1")
    u2 = make_user("iso2")
    a = make_profile(u1.id, "A")
    b = make_profile(u1.id, "B")
    c = make_profile(u2.id, "C")

    seed_session(u1.id, a.id, series_key="a-series", chapter_key="c1", pages_read=10)
    for n in range(3):
        seed_session(
            u1.id, b.id, series_key="b-series", chapter_key=f"c{n}", pages_read=100
        )
    seed_session(u2.id, c.id, series_key="c-series", chapter_key="c1", pages_read=999)

    a_out = _stats(db_session, u1.id, a.id).build(30)
    b_out = _stats(db_session, u1.id, b.id).build(30)
    c_out = _stats(db_session, u2.id, c.id).build(30)

    assert a_out["totals"]["sessions"] == 1
    assert a_out["totals"]["pages_read"] == 10
    assert b_out["totals"]["pages_read"] == 300
    assert c_out["totals"]["pages_read"] == 999
    for out, key in ((a_out, "a-series"), (b_out, "b-series"), (c_out, "c-series")):
        assert {r["series_key"] for r in out["by_series"]} == {key}
        assert {r["series_key"] for r in out["recent_sessions"]} == {key}
    assert sum(d["pages_read"] for d in a_out["daily"]) == 10


def test_a_caller_with_no_profile_sees_nothing(db_session, acct, seed_session):
    """``None`` is the unscoped bucket, not a wildcard over the account."""
    uid, pid = acct
    seed_session(uid, pid, chapter_key="c1", pages_read=42)

    out = _stats(db_session, uid, None).build(30)
    assert out["totals"]["sessions"] == 0
    assert out["totals"]["pages_read"] == 0


# --- the 18+ gate ---------------------------------------------------------


def _seed_mature_world(uid, pid, seed_follow, seed_session):
    seed_follow(uid, pid, series_key="safe", title="Safe One")
    seed_follow(uid, pid, series_key="adult", title="Adult One", content_rating="smut")
    seed_session(uid, pid, series_key="safe", chapter_key="s1", pages_read=10)
    seed_session(uid, pid, series_key="adult", chapter_key="a1", pages_read=500)


def test_mature_series_are_excluded_from_every_number_when_the_gate_is_shut(
    db_session, acct, seed_follow, seed_session
):
    """Not just from the named breakdowns.

    A total that silently carries 500 invisible pages tells the reader that
    hidden content exists, which is the thing the gate is for.
    """
    uid, pid = acct
    _seed_mature_world(uid, pid, seed_follow, seed_session)

    shut = _stats(db_session, uid, pid, gate_open=False).build(30)
    assert shut["totals"]["pages_read"] == 10
    assert shut["totals"]["series_read"] == 1
    assert {r["series_key"] for r in shut["by_series"]} == {"safe"}
    assert {r["series_key"] for r in shut["recent_sessions"]} == {"safe"}
    assert shut["by_source"][0]["pages_read"] == 10
    assert sum(d["pages_read"] for d in shut["daily"]) == 10
    assert sum(h["pages_read"] for h in shut["by_hour"]) == 10

    open_ = _stats(db_session, uid, pid, gate_open=True).build(30)
    assert open_["totals"]["pages_read"] == 510
    assert {r["series_key"] for r in open_["by_series"]} == {"safe", "adult"}


def test_a_mature_source_is_gated_even_with_no_rating_on_the_follow(
    db_session, acct, seed_follow, seed_session
):
    """Rule 3 of ``resolve_tracker_rating``: an 18+ source is 18+ by construction."""
    uid, pid = acct
    seed_session(uid, pid, source_id=MATURE_SOURCE, series_key="x", chapter_key="c1")

    assert _stats(db_session, uid, pid, gate_open=False).build(30)["totals"][
        "sessions"
    ] == 0
    assert _stats(db_session, uid, pid, gate_open=True).build(30)["totals"][
        "sessions"
    ] == 1


def test_mature_override_wins_over_the_source_in_both_directions(
    db_session, acct, seed_follow, seed_session
):
    uid, pid = acct
    # "not 18+" on an 18+ source: the user said so, so it counts.
    seed_follow(
        uid, pid, source_id=MATURE_SOURCE, series_key="tame", title="Tame",
        mature_override=False,
    )
    seed_session(uid, pid, source_id=MATURE_SOURCE, series_key="tame", chapter_key="c1")
    # "18+" on a safe source: hidden.
    seed_follow(uid, pid, series_key="flagged", title="Flagged", mature_override=True)
    seed_session(uid, pid, series_key="flagged", chapter_key="c1")

    shut = _stats(db_session, uid, pid, gate_open=False).build(30)
    assert {r["series_key"] for r in shut["by_series"]} == {"tame"}


def test_chapters_completed_is_gated_and_profile_scoped(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    seed_follow(uid, pid, series_key="safe", title="Safe One")
    seed_follow(uid, pid, series_key="adult", title="Adult One", content_rating="smut")
    seed_progress(uid, pid, series_key="safe", chapter_key="s1", is_completed=True)
    seed_progress(uid, pid, series_key="adult", chapter_key="a1", is_completed=True)
    seed_progress(uid, pid, series_key="safe", chapter_key="s2", is_completed=False)

    assert _stats(db_session, uid, pid, gate_open=True).chapters_completed() == 2
    assert _stats(db_session, uid, pid, gate_open=False).chapters_completed() == 1


# --- the service + HTTP surface -------------------------------------------


def test_service_keeps_the_original_four_fields(
    db_session, acct, seed_follow, seed_session
):
    """Clients migrate at their own pace; the old keys keep their meaning."""
    uid, pid = acct
    seed_follow(uid, pid, series_key="a", title="A", is_favorite=True,
                reading_status="reading")
    seed_follow(uid, pid, series_key="b", title="B", reading_status="completed")
    seed_session(uid, pid, series_key="a", chapter_key="c1", pages_read=12)

    out = FollowedSeriesService(
        db_session, FakeBrowse(), user_id=uid, profile_id=pid
    ).statistics()

    assert out["followed_total"] == 2
    assert out["favorites"] == 1
    assert out["by_reading_status"] == {"reading": 1, "completed": 1}
    assert out["chapters_completed"] == 0
    assert out["totals"]["pages_read"] == 12
    assert out["range"]["days"] == 30


def test_endpoint_returns_the_full_payload(client, as_user, acct, seed_session):
    uid, pid = acct
    seed_session(uid, pid, series_key="a", chapter_key="c1", pages_read=11)

    resp = client.get(
        "/library/statistics",
        params={"days": 7, "tz_offset_minutes": 330},
        headers=as_user(uid, pid),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert set(body) == {
        "followed_total",
        "favorites",
        "by_reading_status",
        "chapters_completed",
        "range",
        "totals",
        "window",
        "streak",
        "daily",
        "by_hour",
        "by_source",
        "by_series",
        "recent_sessions",
    }
    assert body["range"] == {
        "days": 7,
        "since": body["range"]["since"],
        "until": body["range"]["until"],
        "timezone_offset_minutes": 330,
        "session_cap_seconds": SESSION_SECONDS_CAP,
    }
    assert len(body["daily"]) == 7
    assert body["totals"]["pages_read"] == 11


@pytest.mark.parametrize(
    "params",
    [
        {"days": 0},
        {"days": 366},
        {"tz_offset_minutes": -900},
        {"tz_offset_minutes": 900},
    ],
)
def test_endpoint_rejects_an_out_of_range_window(client, as_user, acct, params):
    uid, pid = acct
    resp = client.get(
        "/library/statistics", params=params, headers=as_user(uid, pid)
    )
    assert resp.status_code == 422, resp.text


def test_endpoint_is_isolated_between_profiles(
    client, as_user, acct, make_profile, seed_session
):
    uid, pid = acct
    other = make_profile(uid, "Other")
    seed_session(uid, pid, series_key="a", chapter_key="c1", pages_read=77)

    mine = client.get("/library/statistics", headers=as_user(uid, pid)).json()
    theirs = client.get("/library/statistics", headers=as_user(uid, other.id)).json()

    assert mine["totals"]["pages_read"] == 77
    assert theirs["totals"]["pages_read"] == 0
    assert theirs["recent_sessions"] == []
