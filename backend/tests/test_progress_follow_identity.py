"""Progress and the library agree on WHICH series, not on which spelling of it.

Asura rotates the eight-hex suffix on its slugs every few days and the old one
keeps resolving, so one series reaches a profile under several keys: the
follow keeps the key it was made under (``...-08677664``) while Browse hands
out this week's (``...-05c7df14``). Progress used to be stored under whatever
key the reader was opened with, and the library joined it to the follow on
the exact key -- so a chapter read from Browse never reached the library card
("Not started") or the Continue strip.

Two halves, both covered here:

* WRITE: a push under another key of a followed series is stored under the
  FOLLOW's key, chapter key re-spelled to match, merged furthest-wins with
  what is already there.
* READ: rows already stored under another suffix (before the write fix, or
  for a series followed after it was read) still count toward the follow's
  ``read_state``, the Continue strip and the detail overlay.

Which keys name one series is the connector's call (``series_identity`` /
``chapter_identity``); a source whose keys do not drift is left exactly as it
was and costs no extra query.

Continue-reading items also carry the follow's ``title`` and ``cover_url``, so
a strip card can name its series without a second request.
"""

from __future__ import annotations

import json
from datetime import timedelta

import pytest
from sqlalchemy import event, select

from core.time_utils import utcnow
from database.models import ChapterProgress, ReadingSession
from services.followed_series_service import FollowedSeriesService
from services.progress_service import (
    ProgressInput,
    ProgressService,
    respell_chapter_key,
)
from tests._fakes import FakeBrowse

SRC = "asurascans"
BASE = "the-great-mage-returns-after-4000-years"
OLD = f"{BASE}-08677664"  # the key the follow was made under
NEW = f"{BASE}-05c7df14"  # the key Browse hands out this week
LATER = f"{BASE}-53fc8424"  # yet another rotation
LOOKALIKE = "the-great-mage-05c7df14"  # a different series sharing the prefix


def _known(series_key: str, numbers=range(1, 6)) -> str:
    return json.dumps(
        [
            {"key": f"{series_key}:{n}", "number": float(n), "title": f"Chapter {n}"}
            for n in numbers
        ]
    )


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("identity-reader")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _progress(db, uid, pid) -> ProgressService:
    return ProgressService(db, FakeBrowse(), user_id=uid, profile_id=pid)


def _library(db, uid, pid) -> FollowedSeriesService:
    browse = FakeBrowse()
    browse.down = True  # no source is contacted: detail falls back to known_chapters
    return FollowedSeriesService(db, browse, user_id=uid, profile_id=pid)


def _push(series_key: str, number: int, page: int, *, source_id: str = SRC, **kw):
    return ProgressInput(
        source_id=source_id,
        series_key=series_key,
        chapter_key=f"{series_key}:{number}",
        chapter_number=float(number),
        last_page=page,
        page_count=kw.pop("page_count", 20),
        **kw,
    )


def _rows(db, uid, pid) -> list[ChapterProgress]:
    db.expire_all()
    return list(
        db.execute(
            select(ChapterProgress)
            .where(
                ChapterProgress.user_id == uid, ChapterProgress.profile_id == pid
            )
            .order_by(ChapterProgress.id)
        ).scalars()
    )


def _state(db, uid, pid, series_key=OLD):
    items = _library(db, uid, pid).list_series(per_page=200)["items"]
    return {i["series_key"]: i["read_state"] for i in items}[series_key]


# --- WRITE: a push under another key lands on the follow ----------------------


def test_a_push_under_this_weeks_key_is_stored_under_the_follows_key(
    db_session, acct, seed_follow
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))

    result = _progress(db_session, uid, pid).save_one(_push(NEW, 3, 7))

    rows = _rows(db_session, uid, pid)
    assert [(r.series_key, r.chapter_key, r.last_page) for r in rows] == [
        (OLD, f"{OLD}:3", 7)
    ], "progress read from Browse's key never reaches the follow's card"
    assert result["series_key"] == OLD
    assert result["chapter_key"] == f"{OLD}:3"


def test_a_rekeyed_push_merges_furthest_wins_with_the_follows_row(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_progress(
        uid, pid, source_id=SRC, series_key=OLD, chapter_key=f"{OLD}:3",
        chapter_number=3.0, last_page=12, page_count=20,
        last_read_at=utcnow() - timedelta(hours=1),
    )
    svc = _progress(db_session, uid, pid)

    behind = svc.save_one(_push(NEW, 3, 4))
    assert behind["last_page"] == 12, "a behind push under the new key rewound the row"
    assert behind["advanced"] is False

    ahead = svc.save_one(_push(NEW, 3, 18))
    assert ahead["last_page"] == 18

    rows = _rows(db_session, uid, pid)
    assert len(rows) == 1, "the new key's push inserted a second row for chapter 3"
    assert (rows[0].series_key, rows[0].chapter_key) == (OLD, f"{OLD}:3")


def test_a_batch_rekeys_every_item_and_merges_both_spellings_of_one_chapter(
    db_session, acct, seed_follow
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))

    result = _progress(db_session, uid, pid).save_batch(
        [
            _push(NEW, 2, 20, is_completed=True),
            _push(NEW, 3, 5),
            _push(OLD, 3, 9),  # the same chapter, from the library's reader
            _push(LATER, 4, 2),
        ]
    )

    assert result["saved"] == 4
    rows = _rows(db_session, uid, pid)
    assert sorted((r.series_key, r.chapter_key, r.last_page) for r in rows) == [
        (OLD, f"{OLD}:2", 20),
        (OLD, f"{OLD}:3", 9),
        (OLD, f"{OLD}:4", 2),
    ]


def test_a_chapter_the_follows_list_does_not_carry_yet_is_still_respelled(
    db_session, acct, seed_follow
):
    """A chapter released after the last sweep is not in ``known_chapters``;
    the connector's ``chapter_identity`` still says which spelling it has."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))

    _progress(db_session, uid, pid).save_one(_push(NEW, 276, 1))

    assert [(r.series_key, r.chapter_key) for r in _rows(db_session, uid, pid)] == [
        (OLD, f"{OLD}:276")
    ]


def test_a_rekeyed_push_logs_its_reading_session_under_the_follows_key(
    db_session, acct, seed_follow
):
    """The statistics screen names a session's series by joining it to a
    follow; a session logged under Browse's key would be an untitled stray."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))

    _progress(db_session, uid, pid).save_one(_push(NEW, 3, 7, time_spent_seconds=90))

    sessions = db_session.execute(
        select(ReadingSession.series_key, ReadingSession.chapter_key).where(
            ReadingSession.user_id == uid, ReadingSession.profile_id == pid
        )
    ).all()
    assert [tuple(s) for s in sessions] == [(OLD, f"{OLD}:3")]


def test_respell_chapter_key_puts_the_follows_key_in_place_of_the_sent_one():
    assert (
        respell_chapter_key(SRC, f"{NEW}:3", stored_under=NEW, series_key=OLD)
        == f"{OLD}:3"
    )
    # The same spelling in and out is free and unchanged.
    assert (
        respell_chapter_key(SRC, f"{OLD}:3", stored_under=OLD, series_key=OLD)
        == f"{OLD}:3"
    )


def test_respell_chapter_key_falls_back_to_the_chapter_list():
    """A chapter key that does not literally begin with the series key it was
    sent under (here a stray leading slash on the series key) is found in the
    follow's list by the connector's ``chapter_identity``."""
    chapters = json.loads(_known(OLD))

    assert (
        respell_chapter_key(
            SRC, f"{NEW}:3", stored_under=f"/{NEW}", series_key=OLD, chapters=chapters
        )
        == f"{OLD}:3"
    )
    # Nowhere to be found: kept as it came rather than guessed at.
    assert (
        respell_chapter_key(
            SRC, f"{NEW}:9", stored_under=f"/{NEW}", series_key=OLD, chapters=chapters
        )
        == f"{NEW}:9"
    )


def test_respell_chapter_key_leaves_a_non_drifting_source_alone():
    assert (
        respell_chapter_key("mangadex", "c-3", stored_under="a", series_key="b")
        == "c-3"
    )


def test_the_rekeyed_write_shows_in_the_library_list_endpoint(
    client, as_user, db_session, acct, seed_follow
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    headers = as_user(uid, pid)

    pushed = client.post(
        "/reader/progress",
        json={
            "source_id": SRC,
            "series_key": NEW,
            "chapter_key": f"{NEW}:3",
            "chapter_number": 3,
            "last_page": 6,
            "page_count": 20,
        },
        headers=headers,
    )
    assert pushed.status_code == 200, pushed.text

    body = client.get("/library/series", headers=headers).json()
    state = {i["series_key"]: i["read_state"] for i in body["items"]}[OLD]
    assert state["started"] is True
    assert state["chapter_key"] == f"{OLD}:3"
    assert state["position"] == 3
    assert state["new_count"] == 2


def test_the_series_page_under_the_new_key_still_sees_what_it_read(
    client, as_user, db_session, acct, seed_follow
):
    """The series page (web and phone) reads ``GET /reader/progress/series``
    under the key it was opened with and matches rows to its own chapter list.
    Storing the push under the follow's key must not blank that page."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    svc = _progress(db_session, uid, pid)
    svc.save_one(_push(NEW, 3, 6))

    rows = svc.get_series_progress(SRC, NEW)
    assert [(r["series_key"], r["chapter_key"], r["last_page"]) for r in rows] == [
        (NEW, f"{NEW}:3", 6)
    ]
    # ...and the follow's own key reads the same row in its own spelling.
    rows = svc.get_series_progress(SRC, OLD)
    assert [(r["series_key"], r["chapter_key"]) for r in rows] == [(OLD, f"{OLD}:3")]

    over_http = client.get(
        "/reader/progress/series",
        params={"source": SRC, "series": NEW},
        headers=as_user(uid, pid),
    ).json()
    assert [r["chapter_key"] for r in over_http] == [f"{NEW}:3"]


def test_series_progress_keeps_the_furthest_of_two_spellings_of_one_chapter(
    db_session, acct, seed_progress
):
    uid, pid = acct
    seed_progress(uid, pid, source_id=SRC, series_key=OLD, chapter_key=f"{OLD}:3",
                  chapter_number=3.0, last_page=4)
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:3",
                  chapter_number=3.0, last_page=15, is_completed=True)

    rows = _progress(db_session, uid, pid).get_series_progress(SRC, LATER)

    assert [(r["chapter_key"], r["last_page"], r["is_completed"]) for r in rows] == [
        (f"{LATER}:3", 15, True)
    ]


def test_another_profiles_follow_is_not_a_target(
    db_session, make_user, make_profile, seed_follow
):
    user = make_user("identity-household")
    a = make_profile(user.id, "A")
    b = make_profile(user.id, "B")
    seed_follow(user.id, a.id, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))

    _progress(db_session, user.id, b.id).save_one(_push(NEW, 3, 7))

    assert [(r.series_key, r.chapter_key) for r in _rows(db_session, user.id, b.id)] == [
        (NEW, f"{NEW}:3")
    ]


def test_a_follow_under_the_exact_key_keeps_the_push_where_it_is(
    db_session, acct, seed_follow
):
    """Two follows of one series (made before ``follow`` deduplicated them):
    the push belongs to the one whose key it names."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_follow(uid, pid, source_id=SRC, series_key=NEW, known_chapters=_known(NEW))

    _progress(db_session, uid, pid).save_one(_push(NEW, 3, 7))

    assert [r.series_key for r in _rows(db_session, uid, pid)] == [NEW]


def test_a_series_that_only_shares_the_prefix_is_not_rekeyed(
    db_session, acct, seed_follow
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))

    _progress(db_session, uid, pid).save_one(_push(LOOKALIKE, 3, 7))

    assert [r.series_key for r in _rows(db_session, uid, pid)] == [LOOKALIKE]
    assert _state(db_session, uid, pid)["started"] is False


# --- a source whose keys do not drift ----------------------------------------


def test_a_non_rotating_source_is_stored_and_joined_exactly(
    db_session, acct, seed_follow
):
    uid, pid = acct
    seed_follow(uid, pid, source_id="mangadex", series_key=OLD,
                known_chapters=_known(OLD))

    _progress(db_session, uid, pid).save_one(_push(NEW, 3, 7, source_id="mangadex"))

    assert [r.series_key for r in _rows(db_session, uid, pid)] == [NEW]
    assert _state(db_session, uid, pid)["started"] is False
    assert _library(db_session, uid, pid).continue_reading() == []


def test_a_non_rotating_push_costs_no_follow_lookup(db_session, acct, seed_follow):
    uid, pid = acct
    seed_follow(uid, pid, source_id="mangadex", series_key=OLD)
    svc = _progress(db_session, uid, pid)
    svc.save_one(_push(NEW, 3, 1, source_id="mangadex"))

    seen: list[str] = []

    @event.listens_for(db_session.bind, "before_cursor_execute")
    def _capture(conn, cursor, statement, params, context, many):  # noqa: ANN001
        seen.append(statement)

    try:
        svc.save_one(_push(NEW, 3, 5, source_id="mangadex"))
        svc.save_batch([_push(NEW, n, 2, source_id="mangadex") for n in range(4, 9)])
    finally:
        event.remove(db_session.bind, "before_cursor_execute", _capture)

    assert not [s for s in seen if "followed_series" in s], seen


# --- READ: rows already stored under another suffix ----------------------------


def test_an_old_suffix_row_counts_toward_the_follows_read_state(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:4",
                  chapter_number=4.0, last_page=3)
    seed_progress(uid, pid, source_id=SRC, series_key=OLD, chapter_key=f"{OLD}:2",
                  chapter_number=2.0, last_page=20)

    state = _state(db_session, uid, pid)

    assert state["started"] is True
    assert state["chapter_key"] == f"{OLD}:4", "the furthest chapter is spelled as the follow's list spells it"
    assert state["position"] == 4
    assert state["new_count"] == 1


def test_an_old_suffix_row_alone_starts_the_card(
    db_session, acct, seed_follow, seed_progress
):
    """The production case: every chapter read under Browse's key, none under
    the follow's, so the exact join found nothing at all."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:2",
                  chapter_number=2.0, last_page=3)

    state = _state(db_session, uid, pid)

    assert state["started"] is True
    assert state["position"] == 2
    assert state["chapter_key"] == f"{OLD}:2"


def test_an_old_suffix_row_shows_in_continue_reading_under_the_follows_key(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, title="TGMR",
                known_chapters=_known(OLD), cover_url="/covers/tgmr.jpg")
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:3",
                  chapter_number=3.0, last_page=5, page_count=20)

    strip = _library(db_session, uid, pid).continue_reading()

    assert len(strip) == 1
    item = strip[0]
    assert (item["series_key"], item["chapter_key"], item["last_page"]) == (
        OLD, f"{OLD}:3", 5
    )
    assert item["title"] == "TGMR"
    assert item["cover_url"] == "/covers/tgmr.jpg"


def test_continue_reading_resumes_the_furthest_row_across_suffixes_once(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    now = utcnow()
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_progress(uid, pid, source_id=SRC, series_key=OLD, chapter_key=f"{OLD}:2",
                  chapter_number=2.0, last_page=9, page_count=20, last_read_at=now)
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:4",
                  chapter_number=4.0, last_page=6, page_count=20,
                  last_read_at=now - timedelta(days=1))

    strip = _library(db_session, uid, pid).continue_reading()

    assert [(r["series_key"], r["chapter_key"], r["last_page"]) for r in strip] == [
        (OLD, f"{OLD}:4", 6)
    ]
    # Ordered and stamped by the series' newest read, whichever key it was under.
    assert strip[0]["last_read_at"] == now.isoformat()


def test_a_finished_old_suffix_chapter_moves_the_strip_forward(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:3",
                  chapter_number=3.0, last_page=20, page_count=20, is_completed=True)

    strip = _library(db_session, uid, pid).continue_reading()

    assert [(r["series_key"], r["chapter_key"]) for r in strip] == [(OLD, f"{OLD}:4")]


def test_the_strip_orders_old_suffix_series_by_their_newest_read(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    now = utcnow()
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_follow(uid, pid, source_id="mangadex", series_key="md", title="MD")
    seed_progress(uid, pid, source_id="mangadex", series_key="md", chapter_key="md-1",
                  last_page=2, last_read_at=now - timedelta(hours=2))
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:3",
                  chapter_number=3.0, last_page=5, last_read_at=now)

    strip = _library(db_session, uid, pid).continue_reading()

    assert [r["series_key"] for r in strip] == [OLD, "md"]


def test_the_detail_overlay_counts_old_suffix_rows_under_the_follows_keys(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id=SRC, series_key=OLD,
                         known_chapters=_known(OLD))
    seed_progress(uid, pid, source_id=SRC, series_key=OLD, chapter_key=f"{OLD}:3",
                  chapter_number=3.0, last_page=4)
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:3",
                  chapter_number=3.0, last_page=11)
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:4",
                  chapter_number=4.0, last_page=20, is_completed=True)
    seed_progress(uid, pid, source_id=SRC, series_key=LOOKALIKE,
                  chapter_key=f"{LOOKALIKE}:1", chapter_number=1.0, last_page=2)

    overlay = _library(db_session, uid, pid).get_detail(follow.id)["progress"]

    assert overlay == {
        f"{OLD}:3": {"last_page": 11, "is_completed": False},
        f"{OLD}:4": {"last_page": 20, "is_completed": True},
    }


def test_another_profiles_old_suffix_rows_do_not_count(
    db_session, make_user, make_profile, seed_follow, seed_progress
):
    user = make_user("identity-siblings")
    a = make_profile(user.id, "A")
    b = make_profile(user.id, "B")
    seed_follow(user.id, a.id, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_progress(user.id, b.id, source_id=SRC, series_key=NEW,
                  chapter_key=f"{NEW}:3", chapter_number=3.0)

    assert _state(db_session, user.id, a.id)["started"] is False
    assert _library(db_session, user.id, a.id).continue_reading() == []


def test_a_lookalike_series_row_does_not_count(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_progress(uid, pid, source_id=SRC, series_key=LOOKALIKE,
                  chapter_key=f"{LOOKALIKE}:3", chapter_number=3.0)

    assert _state(db_session, uid, pid)["started"] is False
    assert _library(db_session, uid, pid).continue_reading() == []


def _selects(db, fn) -> list[tuple[str, tuple]]:
    seen: list[tuple[str, tuple]] = []

    def _listen(conn, cursor, statement, parameters, context, executemany):  # noqa: ANN001
        if statement.lstrip().upper().startswith("SELECT"):
            seen.append((statement, tuple(parameters)))

    event.listen(db.bind, "before_cursor_execute", _listen)
    try:
        fn()
    finally:
        event.remove(db.bind, "before_cursor_execute", _listen)
    return seen


def test_a_library_page_without_a_drifting_follow_costs_no_extra_query(
    db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    for n in range(5):
        seed_follow(uid, pid, source_id="mangadex", series_key=f"s{n}",
                    known_chapters=_known(f"s{n}"))
        seed_progress(uid, pid, source_id="mangadex", series_key=f"s{n}",
                      chapter_key=f"s{n}:2", chapter_number=2.0)

    seen = _selects(db_session, lambda: _library(db_session, uid, pid).list_series())

    assert len([s for s, _ in seen if "chapter_progress" in s]) == 1, seen

    seen = _selects(
        db_session, lambda: _library(db_session, uid, pid).continue_reading()
    )

    assert len([s for s, _ in seen if "chapter_progress" in s]) == 1, seen


def test_the_other_key_lookup_reaches_rows_through_the_scope_index(
    db_session, acct, seed_follow, seed_progress
):
    """The rows under another key are found per profile and source, never by
    scanning every profile's reading history."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, known_chapters=_known(OLD))
    seed_progress(uid, pid, source_id=SRC, series_key=NEW, chapter_key=f"{NEW}:3",
                  chapter_number=3.0)
    library = _library(db_session, uid, pid)

    seen = _selects(
        db_session, lambda: (library.list_series(), library.continue_reading())
    )

    raw = db_session.connection().connection.driver_connection
    alias = [(s, p) for s, p in seen if "LEFT OUTER JOIN followed_series" in s]
    assert len(alias) == 2, "one lookup for read_state, one for the strip"
    for sql, params in alias:
        plan = [row[3] for row in raw.execute("EXPLAIN QUERY PLAN " + sql, params)]
        assert any(
            line.startswith("SEARCH chapter_progress USING INDEX ix_chapter_progress_series")
            and "user_id=? AND profile_id=?" in line
            for line in plan
        ), plan
        assert not any(line.startswith("SCAN chapter_progress") for line in plan), plan


# --- 18+ gating is unchanged ------------------------------------------------------


def test_a_hidden_follow_hides_its_old_suffix_rows_everywhere(
    db_session, make_user, make_profile, seed_follow, seed_progress
):
    user = make_user("identity-gated")
    shut = make_profile(user.id, "Kid", mature_content_enabled=False)
    seed_follow(user.id, shut.id, source_id=SRC, series_key=OLD,
                known_chapters=_known(OLD), mature_override=True)
    seed_progress(user.id, shut.id, source_id=SRC, series_key=NEW,
                  chapter_key=f"{NEW}:3", chapter_number=3.0, last_page=5)

    library = _library(db_session, user.id, shut.id)
    assert library.list_series()["items"] == []
    assert library.continue_reading() == []
    # The series page under this week's key must not show the hidden follow's
    # reading either: it names the same series.
    svc = _progress(db_session, user.id, shut.id)
    assert svc.get_series_progress(SRC, NEW) == []
    assert svc.get_series_progress(SRC, LATER) == []


def test_a_push_is_not_rekeyed_onto_a_follow_the_gate_hides(
    db_session, make_user, make_profile, seed_follow
):
    """Re-keying onto a hidden follow would hand its key back in the response:
    the push stays where it was sent, exactly as before."""
    user = make_user("identity-gated-write")
    shut = make_profile(user.id, "Kid", mature_content_enabled=False)
    seed_follow(user.id, shut.id, source_id=SRC, series_key=OLD,
                known_chapters=_known(OLD), mature_override=True)

    result = _progress(db_session, user.id, shut.id).save_one(_push(NEW, 3, 7))

    assert result["series_key"] == NEW
    assert [r.series_key for r in _rows(db_session, user.id, shut.id)] == [NEW]


def test_an_open_gate_shows_the_mature_follows_old_suffix_rows(
    db_session, make_user, make_profile, seed_follow, seed_progress
):
    user = make_user("identity-open")
    open_ = make_profile(user.id, "Adult", mature_content_enabled=True)
    seed_follow(user.id, open_.id, source_id=SRC, series_key=OLD,
                known_chapters=_known(OLD), mature_override=True)
    seed_progress(user.id, open_.id, source_id=SRC, series_key=NEW,
                  chapter_key=f"{NEW}:3", chapter_number=3.0, last_page=5)

    library = _library(db_session, user.id, open_.id)
    assert _state(db_session, user.id, open_.id)["position"] == 3
    assert [r["chapter_key"] for r in library.continue_reading()] == [f"{OLD}:3"]
    assert [r["chapter_key"] for r in _progress(
        db_session, user.id, open_.id
    ).get_series_progress(SRC, NEW)] == [f"{NEW}:3"]


# --- the continue-reading payload names its series -------------------------------


def test_continue_reading_items_carry_the_follows_title_and_cover(
    client, as_user, db_session, acct, seed_follow, seed_progress
):
    uid, pid = acct
    seed_follow(uid, pid, source_id="mangadex", series_key="s1", title="Solo Leveling",
                cover_url="/covers/solo.jpg")
    seed_follow(uid, pid, source_id="mangadex", series_key="s 2", title="No Cover")
    now = utcnow()
    seed_progress(uid, pid, source_id="mangadex", series_key="s1", chapter_key="c1",
                  last_page=3, last_read_at=now)
    seed_progress(uid, pid, source_id="mangadex", series_key="s 2", chapter_key="c1",
                  last_page=2, last_read_at=now - timedelta(hours=1))

    body = client.get("/library/continue-reading", headers=as_user(uid, pid)).json()

    assert [(i["series_key"], i["title"], i["cover_url"]) for i in body] == [
        ("s1", "Solo Leveling", "/covers/solo.jpg"),
        # Straight from the follow row: a follow with no captured cover says
        # so, and the client draws its own placeholder.
        ("s 2", "No Cover", None),
    ]
    # Every other field is still there, unchanged.
    assert set(body[0]) == {
        "source_id", "series_key", "chapter_key", "chapter_number", "last_page",
        "page_count", "last_read_at", "title", "cover_url",
    }
