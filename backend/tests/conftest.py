from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from core.time_utils import utcnow
from database.models import (
    Base,
    Bookmark,
    ChapterProgress,
    FollowedSeries,
    ReadingProfile,
    ReadingSession,
    User,
)
from database.session import get_db, install_sqlite_pragmas
from services.update_scheduler import reset_update_manager_for_tests


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------


@pytest.fixture
def db_engine(tmp_path: Path):
    """A fresh SQLite database with the full ORM schema.

    ``create_all`` (not Alembic) — fast, and the schema is single-baseline now
    so there is no migration path to exercise here. ``test_migrations_alembic``
    covers the baseline itself.
    """
    db_path = tmp_path / "test.db"
    engine = create_engine(
        f"sqlite:///{db_path}",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    # Same connect pragmas as production, WAL + ``foreign_keys=ON`` above all.
    # Without this the whole suite ran with FK enforcement OFF (SQLite's
    # per-connection default) against a schema whose per-profile isolation is
    # held up by ``ON DELETE CASCADE`` alone, so cascades never fired here and
    # a row pointing at a deleted parent was simply accepted.
    install_sqlite_pragmas(engine)
    # ``create_all`` also emits the ``chapter_ocr_fts`` virtual table + triggers
    # via the ``after_create`` hook in ``database.models`` (spec §3.12), so the
    # test schema matches what Alembic builds — no local DDL mirror needed.
    Base.metadata.create_all(bind=engine)
    return engine


@pytest.fixture
def session_factory(db_engine):
    """A sessionmaker configured **exactly** like production ``SessionLocal``.

    ``expire_on_commit=False`` matters: with the SQLAlchemy default, every
    instance is expired at commit and silently reloaded on next access, so a
    relationship read before a write is refreshed for free and stale-read bugs
    never reproduce here. Production does not do that. Keep these flags in
    sync with ``database.session.SessionLocal`` or the suite stops testing the
    server that actually ships.
    """
    return sessionmaker(
        bind=db_engine,
        autoflush=False,
        autocommit=False,
        expire_on_commit=False,
    )


@pytest.fixture
def db_session(session_factory):
    session = session_factory()
    try:
        yield session
    finally:
        session.close()


# ---------------------------------------------------------------------------
# Global-singleton hygiene
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _isolate_process_db(tmp_path_factory, monkeypatch):
    """Keep the process-wide engine off the developer's real ``manhwamaniacs.db``.

    Every test either overrides ``get_db`` or drives its own engine, and
    ``create_app(run_migrations=False)`` no longer touches the DB in its lifespan
    (``main.init_db`` is gated on ``run_migrations``). This is just belt-and-braces
    so a stray ``get_settings()`` / ``get_engine()`` during a test resolves to a
    throwaway path rather than the real file.
    """
    import database.session as dbs
    from core.config import get_settings

    db_file = tmp_path_factory.mktemp("procdb") / "process.db"
    monkeypatch.setenv("MM_DB_PATH", str(db_file))
    # Background browse prefetch stays off suite-wide: a warm thread outliving
    # its test would race the next test's patches (and try to hit the network
    # through the real registry). The warm tests re-enable it explicitly and
    # run the warm inline.
    monkeypatch.setenv("MM_BROWSE_PREFETCH_ENABLED", "false")
    get_settings.cache_clear()
    dbs.get_engine.cache_clear()
    yield
    get_settings.cache_clear()
    dbs.get_engine.cache_clear()


@pytest.fixture(autouse=True)
def reset_session_sweep_counter():
    """Start every test with the expired-session sweep counter at zero.

    ``AuthService._resolves_since_sweep`` is class-level on purpose (the
    service is built per request), so it also survives from one TEST to the
    next: every 20th ``resolve_session`` in the whole process runs a bulk
    sweep, and which test that lands in depends on how many resolves every
    earlier test happened to make. A test asserting what resolve does to one
    expired row then passed alone and failed in the full suite — the sweep's
    ``synchronize_session=False`` delete removed the row behind the test's
    identity map. Resetting here makes each test's resolves count from zero.
    """
    from services.auth_service import AuthService

    AuthService._resolves_since_sweep = 0
    yield


@pytest.fixture(autouse=True)
def reset_update_manager():
    """Reset the process-wide update scheduler around every test."""
    reset_update_manager_for_tests()
    yield
    reset_update_manager_for_tests()


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def default_auth(monkeypatch, request):
    """Resolve every request to a default in-memory admin (``id is None``).

    The per-user query scoping then renders ``WHERE user_id IS NULL`` — the
    pre-auth behaviour, minus the 401 gate. Nothing is persisted.

    Opt out with ``@pytest.mark.real_auth`` (unauthenticated == 401, drive
    register/login yourself), or use the ``as_user`` fixture to resolve
    requests to specific seeded accounts via a bearer token.
    """
    if request.node.get_closest_marker("real_auth"):
        yield
        return
    if "as_user" in request.fixturenames:
        # as_user installs its own resolver.
        yield
        return

    from services import auth_service

    def _resolve_default_admin(self, token):  # noqa: ARG001
        return User(
            username="testadmin",
            password_hash="x",
            is_admin=True,
            is_active=True,
        )

    monkeypatch.setattr(
        auth_service.AuthService, "resolve_session", _resolve_default_admin
    )
    yield


@pytest.fixture
def as_user(monkeypatch, session_factory):
    """Resolve requests to a specific seeded account.

    The test sends ``Authorization: Bearer uid:<id>`` (or passes
    ``headers=as_user(uid)``); ``resolve_session`` looks the user up by id in a
    fresh session on the test engine and returns a detached ``User`` carrying
    the real id, so per-user / per-profile scoping and ``X-Profile-Id``
    ownership checks all work.
    """
    from services import auth_service

    def _resolve(self, token):  # noqa: ARG001
        if not token or not token.startswith("uid:"):
            return None
        try:
            uid = int(token.split(":", 1)[1])
        except ValueError:
            return None
        with session_factory() as s:
            row = s.get(User, uid)
            if row is None:
                return None
            return User(
                id=row.id,
                username=row.username,
                password_hash=row.password_hash,
                is_admin=bool(row.is_admin),
                is_active=bool(row.is_active),
            )

    monkeypatch.setattr(auth_service.AuthService, "resolve_session", _resolve)

    def _headers(user_id: int, profile_id: int | None = None) -> dict[str, str]:
        h = {"Authorization": f"Bearer uid:{user_id}"}
        if profile_id is not None:
            h["X-Profile-Id"] = str(profile_id)
        return h

    return _headers


# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def rate_limit_toggle(request, monkeypatch):
    """Inbound rate limiter is OFF for the suite; opt in with
    ``@pytest.mark.rate_limit`` (and get a fresh limiter storage)."""
    from core.rate_limit import limiter

    enabled = request.node.get_closest_marker("rate_limit") is not None
    monkeypatch.setattr(limiter, "enabled", enabled)
    if enabled and hasattr(limiter, "reset"):
        limiter.reset()
    yield


# ---------------------------------------------------------------------------
# App / client
# ---------------------------------------------------------------------------


@pytest.fixture
def app(session_factory):
    from main import create_app

    def override_get_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    application = create_app(run_migrations=False, run_workers=False)
    application.dependency_overrides[get_db] = override_get_db
    return application


@pytest.fixture
def client(app):
    from fastapi.testclient import TestClient

    with TestClient(app) as test_client:
        yield test_client


# ---------------------------------------------------------------------------
# Seed helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def make_user(db_session: Session) -> Callable[..., User]:
    counter = {"n": 0}

    def _make(username: str | None = None, *, is_admin: bool = False) -> User:
        counter["n"] += 1
        row = User(
            username=username or f"user{counter['n']}",
            password_hash="x",
            is_admin=is_admin,
            is_active=True,
        )
        db_session.add(row)
        db_session.commit()
        db_session.refresh(row)
        return row

    return _make


@pytest.fixture
def make_profile(db_session: Session) -> Callable[..., ReadingProfile]:
    def _make(
        user_id: int,
        name: str = "Profile",
        *,
        mature_content_enabled: bool = False,
        sort_order: int = 0,
    ) -> ReadingProfile:
        row = ReadingProfile(
            user_id=user_id,
            name=name,
            mature_content_enabled=mature_content_enabled,
            sort_order=sort_order,
        )
        db_session.add(row)
        db_session.commit()
        db_session.refresh(row)
        return row

    return _make


@pytest.fixture
def seed_follow(db_session: Session) -> Callable[..., FollowedSeries]:
    def _make(
        user_id: int,
        profile_id: int,
        *,
        source_id: str = "mangadex",
        series_key: str = "series-1",
        title: str = "Series One",
        known_chapters: str = "[]",
        **extra: Any,
    ) -> FollowedSeries:
        row = FollowedSeries(
            user_id=user_id,
            profile_id=profile_id,
            source_id=source_id,
            series_key=series_key,
            title=title,
            known_chapters=known_chapters,
            **extra,
        )
        db_session.add(row)
        db_session.commit()
        db_session.refresh(row)
        return row

    return _make


@pytest.fixture
def seed_progress(db_session: Session) -> Callable[..., ChapterProgress]:
    def _make(
        user_id: int,
        profile_id: int,
        *,
        source_id: str = "mangadex",
        series_key: str = "series-1",
        chapter_key: str = "ch-1",
        chapter_number: float | None = 1.0,
        last_page: int = 1,
        **extra: Any,
    ) -> ChapterProgress:
        row = ChapterProgress(
            user_id=user_id,
            profile_id=profile_id,
            source_id=source_id,
            series_key=series_key,
            chapter_key=chapter_key,
            chapter_number=chapter_number,
            last_page=last_page,
            **extra,
        )
        db_session.add(row)
        db_session.commit()
        db_session.refresh(row)
        return row

    return _make


@pytest.fixture
def seed_session(db_session: Session) -> Callable[..., ReadingSession]:
    """Insert one ``reading_sessions`` row.

    ``ended_at`` defaults to ``started_at + duration_seconds`` so the common
    case reads as "a session that lasted N seconds"; pass ``ended_at=None``
    explicitly for a session the client never closed.
    """

    def _make(
        user_id: int,
        profile_id: int,
        *,
        source_id: str = "mangadex",
        series_key: str = "series-1",
        chapter_key: str = "ch-1",
        chapter_number: float | None = 1.0,
        pages_read: int = 10,
        started_at: datetime | None = None,
        duration_seconds: int | None = 600,
        **extra: Any,
    ) -> ReadingSession:
        start = started_at or utcnow()
        if "ended_at" not in extra:
            extra["ended_at"] = (
                start + timedelta(seconds=duration_seconds)
                if duration_seconds is not None
                else None
            )
        row = ReadingSession(
            user_id=user_id,
            profile_id=profile_id,
            source_id=source_id,
            series_key=series_key,
            chapter_key=chapter_key,
            chapter_number=chapter_number,
            start_page=1,
            end_page=max(1, pages_read),
            pages_read=pages_read,
            started_at=start,
            **extra,
        )
        db_session.add(row)
        db_session.commit()
        db_session.refresh(row)
        return row

    return _make


@pytest.fixture
def seed_bookmark(db_session: Session) -> Callable[..., Bookmark]:
    """Insert one ``bookmarks`` row directly.

    ``page`` is accepted as the alias it is everywhere else — it lands in
    ``anchor_index``, which is the page number for manga and the paragraph
    index for novels (1-based either way).
    """
    counter = {"n": 0}

    def _make(
        user_id: int,
        profile_id: int,
        *,
        source_id: str = "mangadex",
        series_key: str = "series-1",
        chapter_key: str = "ch-1",
        page: int | None = None,
        media_type: str = "manga",
        anchor_index: int = 3,
        anchor_fraction: float = 0.0,
        anchor_total: int = 0,
        chapter_number: float | None = None,
        client_id: str | None = None,
        note: str | None = None,
        **extra: Any,
    ) -> Bookmark:
        counter["n"] += 1
        row = Bookmark(
            user_id=user_id,
            profile_id=profile_id,
            client_id=client_id or f"seed-{counter['n']}",
            source_id=source_id,
            series_key=series_key,
            chapter_key=chapter_key,
            chapter_number=chapter_number,
            media_type=media_type,
            anchor_index=page if page is not None else anchor_index,
            anchor_fraction=anchor_fraction,
            anchor_total=anchor_total,
            note=note,
            **extra,
        )
        db_session.add(row)
        db_session.commit()
        db_session.refresh(row)
        return row

    return _make
