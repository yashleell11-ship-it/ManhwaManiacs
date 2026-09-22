"""HTTP-level tests for ``routes/reader.py`` (spec §4.1, §7).

manifest, progress (+ furthest-wins), progress/batch, progress/series, history,
bookmarks CRUD — real request/response with ``as_user`` + ``X-Profile-Id``.
"""

from __future__ import annotations

from datetime import datetime

import pytest

from services.browse_service import get_browse_service
from tests._fakes import FakeBrowse

SRC = "mangadex"
SERIES = "the-beginning-after-the-end"

FIXTURE = {
    (SRC, SERIES): {
        "meta": {"title": "TBATE"},
        "chapters": [
            {"id": "c1", "number": 1.0, "title": "One"},
            {"id": "c2", "number": 2.0, "title": "Two"},
            {"id": "c3", "number": 3.0, "title": "Three"},
        ],
        "pages": {
            "c2": [
                {"number": 1, "image_url": "/sources/mangadex/pages/p1/image"},
                {"number": 2, "image_url": "/sources/mangadex/pages/p2/image"},
            ],
        },
    }
}


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("reader")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


@pytest.fixture
def api(app, client, acct):
    app.dependency_overrides[get_browse_service] = lambda: FakeBrowse(FIXTURE)
    return client


@pytest.fixture
def h(as_user, acct):
    uid, pid = acct
    return as_user(uid, pid)


# --- manifest --------------------------------------------------------------


def test_manifest_shape_and_neighbours(api, h):
    resp = api.get(
        "/reader/chapter/manifest",
        params={"source": SRC, "series": SERIES, "chapter": "c2"},
        headers=h,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["chapter_number"] == 2.0
    assert body["page_count"] == 2
    assert body["pages"][0] == {
        "number": 1,
        "url": "/sources/mangadex/pages/p1/image",
        "width": None,
        "height": None,
    }
    assert body["prev"] == "c1"
    assert body["next"] == "c3"


def test_manifest_unknown_chapter_404(api, h):
    resp = api.get(
        "/reader/chapter/manifest",
        params={"source": SRC, "series": SERIES, "chapter": "nope"},
        headers=h,
    )
    assert resp.status_code == 404


# --- progress + furthest-wins -------------------------------------------


def _save(api, h, **over):
    body = {
        "source_id": SRC, "series_key": SERIES, "chapter_key": "c1",
        "chapter_number": 1.0, "last_page": 1, "page_count": 20,
    }
    body.update(over)
    return api.post("/reader/progress", json=body, headers=h)


def test_progress_never_rewinds(api, h):
    assert _save(api, h, last_page=12).json()["last_page"] == 12
    behind = _save(api, h, last_page=4).json()
    assert behind["last_page"] == 12
    assert behind["advanced"] is False
    ahead = _save(api, h, last_page=18).json()
    assert ahead["last_page"] == 18
    assert ahead["advanced"] is True


def test_progress_completion_is_sticky(api, h):
    _save(api, h, last_page=20, is_completed=True)
    again = _save(api, h, last_page=2, is_completed=False).json()
    assert again["is_completed"] is True


def test_progress_batch(api, h):
    _save(api, h, last_page=10)
    resp = api.post(
        "/reader/progress/batch",
        json=[
            {"source_id": SRC, "series_key": SERIES, "chapter_key": "c1",
             "chapter_number": 1.0, "last_page": 3, "page_count": 20},
            {"source_id": SRC, "series_key": SERIES, "chapter_key": "c1",
             "chapter_number": 1.0, "last_page": 15, "page_count": 20},
            {"source_id": SRC, "series_key": SERIES, "chapter_key": "c2",
             "chapter_number": 2.0, "last_page": 1, "page_count": 20},
        ],
        headers=h,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["saved"] == 3

    series = api.get(
        "/reader/progress/series", params={"source": SRC, "series": SERIES}, headers=h
    ).json()
    by_key = {r["chapter_key"]: r["last_page"] for r in series}
    assert by_key == {"c1": 15, "c2": 1}


def test_progress_batch_requires_profile(api, as_user, acct):
    uid, _pid = acct
    resp = api.post("/reader/progress/batch", json=[], headers=as_user(uid))
    assert resp.status_code == 400
    assert resp.json()["code"] == "profile_required"


def test_history_lists_recent_first(api, h):
    _save(api, h, chapter_key="c1", chapter_number=1.0, last_page=5)
    _save(api, h, chapter_key="c2", chapter_number=2.0, last_page=5)
    hist = api.get("/reader/history", headers=h).json()
    assert [r["chapter_key"] for r in hist] == ["c2", "c1"]


def test_history_says_which_book_each_row_is(api, h, db_session):
    """The reported bug: history rows were unreadable.

    A row renders as a chapter number over a connector id, so fifty books
    produce fifty rows that look identical and none of them says what you
    were reading. The position is useless without the book.
    """
    from database.models import SourceSeriesCache

    db_session.add(
        SourceSeriesCache(
            source_id=SRC,
            series_key=SERIES,
            title="The Beginning After The End",
            cover_url="https://example.test/cover.jpg",
        )
    )
    db_session.commit()
    _save(api, h, chapter_key="c1", chapter_number=1.0, last_page=5)

    row = api.get("/reader/history", headers=h).json()[0]

    assert row["series_title"] == "The Beginning After The End"
    assert row["cover_url"] == "https://example.test/cover.jpg"


def test_history_without_a_cached_title_still_lists_the_row(api, h):
    """A book read months ago may have aged out of the TTL cache.

    The row still opens and still shows its position; it just cannot show a
    title. Fetching one from the source on a history render would be an
    accidental scrape per screenful.
    """
    _save(api, h, chapter_key="c9", chapter_number=9.0, last_page=2)

    row = api.get("/reader/history", headers=h).json()[0]

    assert row["series_title"] is None
    assert row["chapter_key"] == "c9"


def test_history_collapsed_gives_one_row_per_book(api, h):
    """What the screen actually wants: books, not positions.

    Reading forty chapters of one book should not be forty rows with the book
    you read before it pushed onto page two.
    """
    _save(api, h, chapter_key="c1", chapter_number=1.0, last_page=5)
    _save(api, h, chapter_key="c2", chapter_number=2.0, last_page=3)
    _save(api, h, chapter_key="c3", chapter_number=3.0, last_page=9)

    rows = api.get("/reader/history?collapse=series", headers=h).json()

    assert len(rows) == 1
    # The furthest-read one, which is where "continue" should take you.
    assert rows[0]["chapter_key"] == "c3"


def test_history_uncollapsed_is_unchanged(api, h):
    # The raw position list stays available; collapsing is opt-in.
    _save(api, h, chapter_key="c1", chapter_number=1.0, last_page=5)
    _save(api, h, chapter_key="c2", chapter_number=2.0, last_page=3)

    assert len(api.get("/reader/history", headers=h).json()) == 2


def test_progress_isolated_between_profiles(api, h, as_user, acct, make_profile):
    uid, _pid = acct
    _save(api, h, last_page=7)
    other = make_profile(uid, "Other")
    other_hist = api.get("/reader/history", headers=as_user(uid, other.id)).json()
    assert other_hist == []


# --- bookmarks --------------------------------------------------------


def test_bookmarks_crud(api, h):
    created = api.post(
        "/reader/bookmark",
        json={"source_id": SRC, "series_key": SERIES, "chapter_key": "c1",
              "page": 4, "note": "cool panel"},
        headers=h,
    )
    assert created.status_code == 200, created.text
    bm_id = created.json()["id"]

    listed = api.get("/reader/bookmarks", headers=h).json()
    assert [b["id"] for b in listed] == [bm_id]

    scoped = api.get(
        "/reader/bookmarks", params={"source": SRC, "series": "other"}, headers=h
    ).json()
    assert scoped == []

    assert api.delete(f"/reader/bookmarks/{bm_id}", headers=h).status_code == 204
    assert api.get("/reader/bookmarks", headers=h).json() == []

    assert api.delete("/reader/bookmarks/999999", headers=h).status_code == 404


# --- the device's own clock on a progress push -----------------------------


def test_an_offline_push_can_carry_the_time_it_was_actually_recorded(api, h):
    """``ProgressInput.last_read_at`` existed and the merge used it, but no
    route ever populated it — so every push was stamped at flush time.

    That is the one place furthest-wins is genuinely undermined: on a position
    tie the merge takes the incoming scroll offset when the incoming push is
    more recent, and a week-old offline push claiming "now" always is. Replay
    a flight's worth of reading and it overwrites a position set on the web an
    hour ago, and jumps to the head of Continue Reading (ordered by
    ``last_read_at``) on a chapter that is not the one read most recently.
    """
    fresh = _save(api, h, last_page=5, scroll_offset_px=9000).json()
    assert fresh["scroll_offset_px"] == 9000

    stale = _save(
        api,
        h,
        last_page=5,
        scroll_offset_px=100,
        last_read_at="2026-08-29T12:00:00Z",
    ).json()

    # Same position, older push → the newer server value stands.
    assert stale["scroll_offset_px"] == 9000


def test_a_push_without_the_field_still_behaves_as_now(api, h):
    """The shipped clients do not send it yet, so omitting it must keep the
    old semantics: the push is the most recent read."""
    _save(api, h, last_page=5, scroll_offset_px=9000)
    newer = _save(api, h, last_page=5, scroll_offset_px=123).json()
    assert newer["scroll_offset_px"] == 123


def test_a_future_device_clock_cannot_pin_itself_to_the_head_of_the_strip(api, h):
    """``last_read_at`` orders Continue Reading, so an unclamped future stamp
    is not one odd row: it is rank 1 for that series until the date passes."""
    from datetime import timedelta

    from core.time_utils import utcnow

    saved = _save(
        api, h, last_page=5, last_read_at="2099-01-01T00:00:00Z"
    ).json()
    assert saved["last_read_at"] is not None
    stamped = datetime.fromisoformat(saved["last_read_at"].replace("Z", ""))
    assert stamped < utcnow() + timedelta(hours=1)


def test_an_offset_aware_timestamp_is_normalized_rather_than_crashing(api, h):
    """The columns are naive UTC and a client is free to send +05:30;
    comparing the two mid-merge is a TypeError."""
    ok = _save(api, h, last_page=5, last_read_at="2026-08-29T17:30:00+05:30")
    assert ok.status_code == 200, ok.text
