"""The continue-reading strip answers the shared Continue table.

``tests/fixtures/reading_navigation_cases.json`` is read by the web and the
phone as well, so the strip, the series pages and the history shelf are held
to one set of answers. The two production cases are why the strip moved from
"the newest row" to "the furthest row": re-reading an early chapter is not
where the reader is.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from core.time_utils import utcnow
from services.followed_series_service import FollowedSeriesService
from tests._fakes import FakeBrowse

CASES = json.loads(
    (Path(__file__).parent / "fixtures" / "reading_navigation_cases.json").read_text()
)


@pytest.fixture
def owner(make_user, make_profile):
    user = make_user("continue-rule-owner")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _svc(db, user_id, profile_id):
    return FollowedSeriesService(db, FakeBrowse(), user_id=user_id, profile_id=profile_id)


def _seed_case(case, owner, seed_follow, seed_progress, series_key="book"):
    user_id, profile_id = owner
    chapters = CASES["books"][case["book"]]
    seed_follow(
        user_id,
        profile_id,
        series_key=series_key,
        known_chapters=json.dumps(chapters),
    )
    for row in case["progress"]:
        seed_progress(
            user_id,
            profile_id,
            series_key=series_key,
            chapter_key=row["chapter_key"],
            chapter_number=row["chapter_number"],
            last_page=row["last_page"],
            page_count=row["page_count"],
            is_completed=row["is_completed"],
            last_read_at=datetime.fromisoformat(row["last_read_at"]),
        )


@pytest.mark.parametrize("case", CASES["continue"], ids=lambda case: case["name"])
def test_the_strip_answers_the_shared_continue_table(
    case, db_session, owner, seed_follow, seed_progress
):
    _seed_case(case, owner, seed_follow, seed_progress)

    strip = _svc(db_session, *owner).continue_reading()

    expect = case["expect"]
    if expect in ("caught_up", "start"):
        # Caught up has no chapter to name, and a book never opened has no
        # row to resume — the strip leaves both out rather than guess.
        assert strip == []
    else:
        assert [(r["chapter_key"], r["last_page"]) for r in strip] == [
            (expect["chapter_key"], expect["page"])
        ]


def test_the_strip_is_ordered_by_when_the_series_was_last_read(
    db_session, owner, seed_follow, seed_progress
):
    """Resuming on the furthest row must not re-sort the strip by it.

    Shadow Slave's resume row (chapter 5) was last touched on 09-04, but the
    book itself was read on 09-21 — re-reading chapter 1 is still reading it.
    Sorted by the resume row it would drop below a series read on 09-10.
    """
    shadow = next(c for c in CASES["continue"] if c["book"] == "shadow_slave")
    _seed_case(shadow, owner, seed_follow, seed_progress, series_key="shadow")
    user_id, profile_id = owner
    seed_follow(user_id, profile_id, series_key="other")
    seed_progress(
        user_id,
        profile_id,
        series_key="other",
        chapter_key="o-1",
        last_page=3,
        page_count=10,
        last_read_at=datetime.fromisoformat("2026-09-10T12:00:00"),
    )

    strip = _svc(db_session, user_id, profile_id).continue_reading()

    assert [(r["series_key"], r["chapter_key"]) for r in strip] == [
        ("shadow", "5"),
        ("other", "o-1"),
    ]
    # The timestamp the strip shows is the series' own last read.
    assert strip[0]["last_read_at"] == "2026-09-21T09:12:00"


def test_a_numberless_newest_row_is_placed_by_the_chapter_list(
    db_session, owner, seed_follow, seed_progress
):
    """The phone sends ``chapter_number = null`` for a chapter whose number it
    never learned. That row is placed through ``known_chapters``: re-opening
    chapter 3 without a number is still going back, and must not beat the
    half-read chapter 9. (Placed PAST the furthest row it wins, which
    ``test_progress_resume_order`` pins from the other side.)"""
    user_id, profile_id = owner
    now = utcnow()
    known = [
        {"key": f"ch-{n}", "number": float(n), "title": f"Chapter {n}"} for n in range(1, 11)
    ]
    seed_follow(user_id, profile_id, series_key="s1", known_chapters=json.dumps(known))
    seed_progress(
        user_id, profile_id, series_key="s1", chapter_key="ch-9",
        chapter_number=9.0, last_page=4, page_count=20,
        last_read_at=now - timedelta(days=2),
    )
    seed_progress(
        user_id, profile_id, series_key="s1", chapter_key="ch-3",
        chapter_number=None, last_page=2, page_count=20, last_read_at=now,
    )

    strip = _svc(db_session, user_id, profile_id).continue_reading()

    assert [(r["chapter_key"], r["last_page"]) for r in strip] == [("ch-9", 4)]
