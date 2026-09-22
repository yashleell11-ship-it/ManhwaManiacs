"""Data-layer audit (shard: indexes) -- query-plan proofs.

Each test captures the SQL a service actually emits, runs ``EXPLAIN QUERY
PLAN`` on it against the ORM schema, and asserts the plan shape a careful
operator would expect. They FAIL on the current schema on purpose: each
failure is one audit finding, and the assertion message names the fix.
"""
from __future__ import annotations

import pytest
from sqlalchemy import event, text

from database.models import (
    ChapterProgress,
    FollowedSeries,
    ReadingProfile,
    ReadingSession,
    UpdateNotification,
    User,
)
from services.browse_service import BrowseService
from services.followed_series_service import FollowedSeriesService
from services.update_service import UpdateService


@pytest.fixture
def seeded(db_session):
    user = User(username="audit", password_hash="x", is_admin=False, is_active=True)
    db_session.add(user)
    db_session.flush()
    profile = ReadingProfile(
        user_id=user.id, name="p", avatar_key="a", mood="m", sort_order=0,
        mature_content_enabled=True,
    )
    db_session.add(profile)
    db_session.flush()
    follow = FollowedSeries(
        user_id=user.id, profile_id=profile.id, source_id="mangadex",
        series_key="s1", title="S1", known_chapters="[]",
    )
    db_session.add(follow)
    db_session.flush()
    db_session.add(
        ChapterProgress(
            user_id=user.id, profile_id=profile.id, source_id="mangadex",
            series_key="s1", chapter_key="c1",
        )
    )
    db_session.add(
        ReadingSession(
            user_id=user.id, profile_id=profile.id, source_id="mangadex",
            series_key="s1", chapter_key="c1",
        )
    )
    db_session.add(
        UpdateNotification(
            user_id=user.id, profile_id=profile.id, followed_series_id=follow.id,
            source_id="mangadex", series_key="s1", chapter_key="c2",
            chapter_title="c2", is_read=False,
        )
    )
    db_session.commit()
    return user, profile


def _capture(db_session, fn):
    """Run ``fn`` and return the SELECT statements (sql, params) it emitted."""
    seen: list[tuple[str, tuple]] = []

    def _listen(conn, cursor, statement, parameters, context, executemany):
        if statement.lstrip().upper().startswith("SELECT"):
            seen.append((statement, tuple(parameters)))

    engine = db_session.get_bind()
    event.listen(engine, "before_cursor_execute", _listen)
    try:
        fn()
    finally:
        event.remove(engine, "before_cursor_execute", _listen)
    return seen


def _plan(db_session, sql: str, params: tuple) -> list[str]:
    raw = db_session.connection().connection.driver_connection
    return [row[3] for row in raw.execute("EXPLAIN QUERY PLAN " + sql, params)]


def test_notification_listing_needs_no_sort_step(db_session, seeded):
    """Finding: update_notifications has five single-column indexes and no
    (user_id, profile_id, created_at). The listing filters on the scope and
    orders by created_at DESC, so SQLite walks ix_update_notifications_profile_id
    and sorts every row of the profile in a temp b-tree on each call.
    Fix: CREATE INDEX ix_update_notifications_scope_created
         ON update_notifications (user_id, profile_id, created_at)."""
    user, profile = seeded
    svc = UpdateService(db_session, user_id=user.id, profile_id=profile.id)
    stmts = _capture(db_session, lambda: svc.list_notifications(limit=100))
    sql, params = next(s for s in stmts if "FROM update_notifications" in s[0])
    plan = _plan(db_session, sql, params)
    assert not any("TEMP B-TREE" in line for line in plan), plan
    assert any("user_id=? AND profile_id=?" in line for line in plan), plan


def test_continue_reading_window_sort_is_index_ordered(db_session, seeded):
    """Finding: the continue_reading window function orders each partition by
    (last_read_at DESC, id DESC) but ix_chapter_progress_series ends at
    series_key, so SQLite sorts the profile's whole progress history
    ('USE TEMP B-TREE FOR LAST 2 TERMS OF ORDER BY'). Measured on 6k progress
    rows: 15.6 ms; with the index extended to (..., last_read_at DESC, id DESC)
    and the query driven from followed_series: 0.9 ms.
    Fix: extend ix_chapter_progress_series with last_read_at DESC, id DESC.

    Since 3.3.x the strip resumes at the FURTHEST chapter, not the newest
    (production rows sent the owner back to chapter 1 after a re-read), so one
    of its two windows now orders by chapter_number and sorts in a temp b-tree
    by design. Re-measured on 6k rows across 300 follows: ~20 ms. What must
    still hold is that the profile's rows are REACHED through the scope index
    rather than by scanning every profile's history."""
    user, profile = seeded
    browse = BrowseService(mature_enabled=True, db=db_session, user_id=user.id, profile_id=profile.id)
    svc = FollowedSeriesService(db_session, browse, user_id=user.id, profile_id=profile.id)
    stmts = _capture(db_session, lambda: svc.continue_reading(limit=10))
    sql, params = next(s for s in stmts if "row_number" in s[0])
    plan = _plan(db_session, sql, params)
    assert any(
        line.startswith("SEARCH chapter_progress USING INDEX ix_chapter_progress_series")
        and "user_id=? AND profile_id=?" in line
        for line in plan
    ), plan
    assert not any(line.startswith("SCAN chapter_progress") for line in plan), plan


def test_profile_delete_cascade_does_not_scan_history_tables(db_session, seeded):
    """Finding: chapter_progress and reading_sessions carry
    profile_id FK ON DELETE CASCADE, but every index on them starts with
    user_id, so the cascade from a profile delete is a full scan of both
    tables (measured: 127 ms vs 61 ms for one profile at 180k/240k rows).
    Fix: CREATE INDEX ix_chapter_progress_profile_id ON chapter_progress (profile_id);
         CREATE INDEX ix_reading_sessions_profile_id ON reading_sessions (profile_id)."""
    _user, profile = seeded
    raw = db_session.connection().connection.driver_connection
    raw.execute("PRAGMA foreign_keys=ON")
    plan = [
        row[3]
        for row in raw.execute(
            "EXPLAIN QUERY PLAN DELETE FROM reading_profiles WHERE id = ?", (profile.id,)
        )
    ]
    scans = [line for line in plan if line.startswith("SCAN") and (
        "chapter_progress" in line or "reading_sessions" in line)]
    assert not scans, plan
