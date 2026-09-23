"""AUDIT IL-04 / LDB-04 / LDB-05: the sweep's own housekeeping.

``update_runs`` grew by a row per pass with no retention (104 rows in three
days), a read ``update_notifications`` row was never removed, and every
container boot — every deploy — queued a full sweep whether or not one had
just run (42 ``startup`` runs in the same three days). The sweep now prunes
both tables when it finishes, and a boot-time sweep is skipped while the last
sweep is still inside the check interval.
"""

from __future__ import annotations

import json
from datetime import timedelta

import pytest
from sqlalchemy import func, select

from core.time_utils import utcnow
from database.models import UpdateNotification, UpdateRun
from services import browse_service
from services.update_service import _RUN_HISTORY_KEEP, UpdateService

SRC = "mangadex"


@pytest.fixture
def stub_connector(monkeypatch):
    box: dict = {"chapters": [], "calls": 0}

    def _fake(self, source_id, series_key):  # noqa: ARG001
        box["calls"] += 1
        return list(box["chapters"])

    monkeypatch.setattr(browse_service.BrowseService, "get_chapters", _fake)
    return box


@pytest.fixture
def follow(make_user, make_profile, seed_follow):
    user = make_user("keeper")
    profile = make_profile(user.id, "Main")
    return seed_follow(
        user.id, profile.id, source_id=SRC, series_key="kept",
        known_chapters=json.dumps(
            [{"key": "c1", "number": 1.0, "title": "One", "published_at": None}]
        ),
        notify=True,
    )


def _run(db, *, trigger="scheduled", status="completed", finished_ago, started_at=None):
    finished = utcnow() - finished_ago
    row = UpdateRun(
        trigger=trigger,
        status=status,
        series_checked=1,
        new_chapters_found=0,
        started_at=started_at or finished - timedelta(minutes=1),
        finished_at=None if status == "running" else finished,
    )
    db.add(row)
    db.commit()
    return row


def _notif(db, follow, key, *, is_read, created_at):
    row = UpdateNotification(
        user_id=follow.user_id,
        profile_id=follow.profile_id,
        followed_series_id=follow.id,
        source_id=follow.source_id,
        series_key=follow.series_key,
        chapter_key=key,
        chapter_title=key,
        chapter_number=None,
        is_read=is_read,
        created_at=created_at,
    )
    db.add(row)
    db.commit()
    return row


def _run_count(db) -> int:
    return db.execute(select(func.count()).select_from(UpdateRun)).scalar_one()


# --- IL-04: the run log is a bounded tail ------------------------------


def test_sweep_keeps_only_the_newest_runs(db_session, follow, stub_connector):
    base = utcnow() - timedelta(days=1)
    seeded = [
        _run(
            db_session,
            finished_ago=timedelta(days=1) - timedelta(minutes=i),
            started_at=base + timedelta(minutes=i),
        )
        for i in range(_RUN_HISTORY_KEEP + 50)
    ]

    result = UpdateService(db_session, system=True).run_check(trigger="scheduled")
    assert result["status"] == "completed"

    surviving = set(db_session.execute(select(UpdateRun.id)).scalars().all())
    assert len(surviving) == _RUN_HISTORY_KEEP
    assert result["id"] in surviving  # the pass that just ran is the newest
    assert seeded[0].id not in surviving  # the oldest went first
    assert seeded[-1].id in surviving


def test_a_targeted_check_is_not_the_sweep_and_leaves_history_alone(
    db_session, follow, stub_connector
):
    for i in range(_RUN_HISTORY_KEEP + 10):
        _run(db_session, finished_ago=timedelta(days=1, minutes=i))
    before = _run_count(db_session)

    UpdateService(
        db_session, user_id=follow.user_id, profile_id=follow.profile_id
    ).check_followed_by_id(follow.id)

    assert _run_count(db_session) == before + 1


# --- LDB-04: read notifications expire, unread ones never do --------------


def test_sweep_expires_read_notifications_after_ninety_days_only(
    db_session, follow, stub_connector
):
    old = utcnow() - timedelta(days=91)
    fresh = utcnow() - timedelta(days=89)
    _notif(db_session, follow, "read-old", is_read=True, created_at=old)
    _notif(db_session, follow, "read-fresh", is_read=True, created_at=fresh)
    _notif(db_session, follow, "unread-old", is_read=False, created_at=old)

    UpdateService(db_session, system=True).run_check(trigger="scheduled")

    keys = set(db_session.execute(select(UpdateNotification.chapter_key)).scalars())
    assert keys == {"read-fresh", "unread-old"}


# --- LDB-05: a boot inside the interval does not sweep again ---------------


def test_first_boot_sweeps(db_session, follow, stub_connector):
    assert UpdateService(db_session).startup_sweep_due() is True

    result = UpdateService(db_session, system=True).run_check(trigger="startup")

    assert result["status"] == "completed"
    assert stub_connector["calls"] == 1
    assert _run_count(db_session) == 1


def test_boot_inside_the_interval_skips_the_sweep(db_session, follow, stub_connector):
    _run(db_session, trigger="scheduled", finished_ago=timedelta(minutes=5))

    assert UpdateService(db_session).startup_sweep_due() is False
    result = UpdateService(db_session, system=True).run_check(trigger="startup")

    assert result["status"] == "skipped"
    assert result["id"] is None
    assert stub_connector["calls"] == 0
    assert _run_count(db_session) == 1  # nothing happened, so no run row either
    db_session.refresh(follow)
    assert follow.last_checked_at is None


def test_boot_after_the_interval_sweeps(db_session, follow, stub_connector):
    interval = UpdateService(db_session).get_global_settings().check_interval_minutes
    _run(db_session, trigger="startup", finished_ago=timedelta(minutes=interval + 1))

    result = UpdateService(db_session, system=True).run_check(trigger="startup")

    assert result["status"] == "completed"
    assert stub_connector["calls"] == 1


@pytest.mark.parametrize(
    ("trigger", "status"),
    [
        ("scheduled", "failed"),  # a failed pass swept nothing
        ("scheduled", "running"),  # never finished
        ("manual", "completed"),  # may be one member's per-series check
    ],
)
def test_only_a_completed_sweep_counts_as_evidence(
    db_session, follow, stub_connector, trigger, status
):
    _run(db_session, trigger=trigger, status=status, finished_ago=timedelta(minutes=5))

    result = UpdateService(db_session, system=True).run_check(trigger="startup")

    assert result["status"] == "completed", (trigger, status)
    assert stub_connector["calls"] == 1


def test_the_interval_is_the_configured_one(db_session, follow, stub_connector):
    settings = UpdateService(db_session).get_global_settings()
    settings.check_interval_minutes = 240
    db_session.commit()
    _run(db_session, trigger="scheduled", finished_ago=timedelta(minutes=120))

    result = UpdateService(db_session, system=True).run_check(trigger="startup")

    assert result["status"] == "skipped"
    assert stub_connector["calls"] == 0


def test_a_scheduled_pass_is_never_skipped(db_session, follow, stub_connector):
    """The gate is for boots. The scheduler's own tick is the cadence itself."""
    _run(db_session, trigger="scheduled", finished_ago=timedelta(minutes=5))

    result = UpdateService(db_session, system=True).run_check(trigger="scheduled")

    assert result["status"] == "completed"
    assert stub_connector["calls"] == 1


# --- a skipped boot sweep must not delay the next one -----------------------


@pytest.fixture
def first_sleep(db_session, session_factory, monkeypatch):
    """The scheduler's first wait after boot, read against the test DB."""
    from services import update_scheduler

    monkeypatch.setattr(update_scheduler, "SessionLocal", session_factory)
    settings = UpdateService(db_session).get_global_settings()
    settings.enabled = True
    settings.check_interval_minutes = 60
    db_session.commit()
    return lambda: update_scheduler.UpdateSchedulerManager()._first_sleep_seconds()


def test_a_skipped_boot_wakes_when_the_last_sweeps_interval_runs_out(
    db_session, first_sleep
):
    """Production: a sweep at 21:29, a deploy at 22:22 skipped its startup
    check, and the scheduler then slept a full hour from the boot — the next
    sweep came at 23:22, 113 minutes after the last. It is due at 22:29."""
    _run(db_session, trigger="startup", finished_ago=timedelta(minutes=53))

    wait = first_sleep()

    assert 6 * 60 <= wait <= 7 * 60 + 5, wait


def test_a_boot_that_sweeps_waits_a_full_interval(db_session, first_sleep):
    # No recent sweep, so the startup check is running one now.
    _run(db_session, trigger="scheduled", finished_ago=timedelta(minutes=90))

    assert first_sleep() == 60 * 60


def test_the_first_wait_is_never_shorter_than_a_minute(db_session, first_sleep):
    _run(db_session, trigger="scheduled", finished_ago=timedelta(minutes=59, seconds=50))

    assert first_sleep() == 60
