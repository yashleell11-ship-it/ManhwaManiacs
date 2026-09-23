"""A second device's late push is logged at its own time, with its own seconds.

The phone reads a chapter offline late at night; next morning the web opens
the same chapter at an earlier page and that push lands first; then the phone
syncs. Furthest-wins takes the phone's position, which is right. The reading
session it wrote was not: it was dated at the row's newest read (the web's,
this morning), and the phone's minutes were refused as a replay because its
stamp was older than the row's. Last night showed no reading, the streak
broke, and this morning got the pages with zero time.
"""

from __future__ import annotations

from datetime import timedelta

import pytest

from core.time_utils import utcnow
from database.models import ChapterProgress, ReadingSession
from services.progress_service import ProgressInput, ProgressService, merge_progress


@pytest.fixture
def svc(db_session, make_user, make_profile):
    user = make_user("twodevices")
    profile = make_profile(user.id, "Main")
    return ProgressService(db_session, user_id=user.id, profile_id=profile.id)


def _push(**kw) -> ProgressInput:
    base = dict(
        source_id="mangadex",
        series_key="series-1",
        chapter_key="ch-12",
        chapter_number=12.0,
        page_count=20,
    )
    base.update(kw)
    return ProgressInput(**base)


def test_late_forward_push_is_dated_and_paid_as_itself(svc, db_session):
    morning = utcnow() - timedelta(minutes=5)
    last_night = morning - timedelta(hours=9, minutes=30)

    # The web opens ch12 at page 5 this morning: that push lands first.
    svc.save_one(_push(last_page=5, last_read_at=morning, time_spent_seconds=0))
    # Then the phone syncs last night's offline read, pages 1-20, ten minutes.
    svc.save_one(_push(last_page=20, last_read_at=last_night, time_spent_seconds=600))

    row = db_session.query(ChapterProgress).one()
    assert row.last_page == 20
    assert row.time_spent_seconds == 600

    sessions = db_session.query(ReadingSession).order_by(ReadingSession.id).all()
    late = sessions[-1]
    assert (late.start_page, late.end_page) == (6, 20)
    assert late.ended_at == last_night
    assert late.started_at == last_night - timedelta(seconds=600)


def test_a_replay_of_an_applied_push_is_still_paid_once(svc, db_session):
    """The exception is for pushes that MOVE the position, which a replay cannot."""
    t0 = utcnow() - timedelta(minutes=30)
    first = _push(last_page=20, last_read_at=t0, time_spent_seconds=600)
    svc.save_one(first)
    svc.save_one(_push(last_page=20, last_read_at=t0 + timedelta(minutes=10), time_spent_seconds=60))
    svc.save_one(first)  # the outbox re-sends it: older stamp, no advance

    assert db_session.query(ChapterProgress).one().time_spent_seconds == 660


def test_merge_reports_the_pushes_own_instant():
    now = utcnow()
    earlier = now - timedelta(hours=2)
    stored = merge_progress(None, _push(last_page=5, last_read_at=now), now=now)
    merged = merge_progress(
        stored, _push(last_page=20, last_read_at=earlier, time_spent_seconds=300), now=now
    )
    assert merged.advanced
    assert merged.last_read_at == now
    assert merged.read_at == earlier
    assert merged.time_spent_seconds == 300
