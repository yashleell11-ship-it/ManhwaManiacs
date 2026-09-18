"""Backend tests for database backup export/import.

Covers three layers:
- services.backup_service: snapshot creation, validation, staging (direct calls)
- core.backup_restore: applying a staged restore at "process start"
- routes.backup: the HTTP surface, tested against a minimal, isolated FastAPI
  app (the backup router has no dependency on the SQLAlchemy engine/get_db,
  so it's tested without ever touching the full create_app()/lifespan, which
  would otherwise open the real production database).
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import core.backup_restore as backup_restore
import services.backup_service as backup_service
from core.errors import AppError, register_error_handlers
from routes.backup import router as backup_router

# Source-native: the backup validator now requires the new baseline tables
# (services.backup_service._REQUIRED_TABLES).
_REQUIRED_TABLES = ("users", "followed_series", "chapter_progress", "alembic_version")


def _make_real_db(path: Path, *, with_tables: bool = True) -> None:
    connection = sqlite3.connect(str(path))
    try:
        if with_tables:
            for table in _REQUIRED_TABLES:
                connection.execute(f"CREATE TABLE {table} (id INTEGER PRIMARY KEY)")
            connection.execute("ALTER TABLE users ADD COLUMN username TEXT")
            connection.execute(
                "INSERT INTO users (id, username) VALUES (1, 'owner')"
            )
        else:
            connection.execute("CREATE TABLE unrelated (id INTEGER PRIMARY KEY)")
        connection.commit()
    finally:
        connection.close()


@pytest.fixture
def real_db_path(tmp_path: Path) -> Path:
    path = tmp_path / "app.db"
    _make_real_db(path)
    return path


@pytest.fixture(autouse=True)
def _patch_settings_db_path(real_db_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Point every settings lookup the backup code makes at a throwaway db file
    -- this must never be able to touch the real production database."""
    from core.config import get_settings

    patched = get_settings().model_copy(update={"db_path": str(real_db_path)})
    monkeypatch.setattr(backup_service, "get_settings", lambda: patched)
    monkeypatch.setattr(backup_restore, "get_settings", lambda: patched)


@pytest.fixture(autouse=True)
def _clean_pending_marker(real_db_path: Path):
    marker = Path(f"{real_db_path}.pending-restore")
    marker.unlink(missing_ok=True)
    yield
    marker.unlink(missing_ok=True)


# ── services.backup_service ──────────────────────────────────────────────────


def test_create_backup_snapshot_is_a_consistent_copy(real_db_path):
    snapshot_path = backup_service.create_backup_snapshot()
    try:
        assert snapshot_path.exists()
        connection = sqlite3.connect(str(snapshot_path))
        try:
            row = connection.execute(
                "SELECT username FROM users WHERE id = 1"
            ).fetchone()
        finally:
            connection.close()
        assert row == ("owner",)
    finally:
        snapshot_path.unlink(missing_ok=True)
        snapshot_path.parent.rmdir()


def test_create_backup_snapshot_does_not_mutate_the_source(real_db_path):
    original_bytes = real_db_path.read_bytes()
    snapshot_path = backup_service.create_backup_snapshot()
    snapshot_path.unlink(missing_ok=True)
    snapshot_path.parent.rmdir()
    assert real_db_path.read_bytes() == original_bytes


def test_stage_restore_accepts_a_valid_backup(tmp_path, real_db_path):
    upload = tmp_path / "uploaded.db"
    _make_real_db(upload)

    assert backup_service.restore_pending() is False
    backup_service.stage_restore(upload)
    assert backup_service.restore_pending() is True
    # The uploaded temp file was moved into place, not merely copied.
    assert not upload.exists()


def test_stage_restore_rejects_a_backup_missing_required_tables(tmp_path, real_db_path):
    upload = tmp_path / "uploaded.db"
    _make_real_db(upload, with_tables=False)

    with pytest.raises(AppError) as excinfo:
        backup_service.stage_restore(upload)
    assert excinfo.value.code == "invalid_backup_file"
    assert excinfo.value.status_code == 422
    assert backup_service.restore_pending() is False


def test_stage_restore_rejects_a_non_sqlite_file(tmp_path, real_db_path):
    upload = tmp_path / "uploaded.db"
    upload.write_text("definitely not a database")

    with pytest.raises(AppError):
        backup_service.stage_restore(upload)
    assert backup_service.restore_pending() is False


def test_clear_pending_restore_removes_a_staged_file(tmp_path, real_db_path):
    upload = tmp_path / "uploaded.db"
    _make_real_db(upload)
    backup_service.stage_restore(upload)
    assert backup_service.restore_pending() is True

    assert backup_service.clear_pending_restore() is True
    assert backup_service.restore_pending() is False


def test_clear_pending_restore_is_a_noop_when_nothing_staged(real_db_path):
    assert backup_service.clear_pending_restore() is False


# ── core.backup_restore ───────────────────────────────────────────────────────


def test_apply_pending_restore_swaps_the_file_in(tmp_path, real_db_path):
    upload = tmp_path / "uploaded.db"
    _make_real_db(upload)
    connection = sqlite3.connect(str(upload))
    connection.execute("UPDATE users SET username = 'restored' WHERE id = 1")
    connection.commit()
    connection.close()

    backup_service.stage_restore(upload)
    assert backup_restore.apply_pending_restore_if_present() is True

    connection = sqlite3.connect(str(real_db_path))
    try:
        row = connection.execute("SELECT username FROM users WHERE id = 1").fetchone()
    finally:
        connection.close()
    assert row == ("restored",)
    assert backup_restore.pending_restore_path().exists() is False


def test_apply_pending_restore_is_a_noop_without_a_staged_file(real_db_path):
    assert backup_restore.apply_pending_restore_if_present() is False


def test_apply_pending_restore_clears_stale_wal_sidecars(tmp_path, real_db_path):
    wal = Path(f"{real_db_path}-wal")
    shm = Path(f"{real_db_path}-shm")
    wal.write_bytes(b"stale wal frames")
    shm.write_bytes(b"stale shm")

    upload = tmp_path / "uploaded.db"
    _make_real_db(upload)
    backup_service.stage_restore(upload)

    assert backup_restore.apply_pending_restore_if_present() is True
    assert not wal.exists()
    assert not shm.exists()


# ── routes.backup (HTTP surface) ─────────────────────────────────────────────


@pytest.fixture
def client():
    """A minimal app hosting only the backup router -- it has no dependency
    on the SQLAlchemy engine, so this never risks opening the real database
    the way create_app() would."""
    app = FastAPI()
    register_error_handlers(app)
    app.include_router(backup_router)
    with TestClient(app) as test_client:
        yield test_client


def test_export_streams_a_downloadable_sqlite_file(client, real_db_path):
    response = client.get("/backup/export")
    assert response.status_code == 200
    assert response.headers["content-type"] == "application/octet-stream"
    assert ".db" in response.headers.get("content-disposition", "")
    assert response.content.startswith(b"SQLite format 3")


def test_status_reports_no_pending_restore_initially(client):
    response = client.get("/backup/status")
    assert response.status_code == 200
    assert response.json()["restore_pending"] is False


def test_import_stages_a_valid_uploaded_backup(client, tmp_path):
    upload = tmp_path / "uploaded.db"
    _make_real_db(upload)

    with upload.open("rb") as handle:
        response = client.post(
            "/backup/import",
            files={"file": ("backup.db", handle, "application/octet-stream")},
        )
    assert response.status_code == 200
    assert response.json()["status"] == "staged"
    assert client.get("/backup/status").json()["restore_pending"] is True


def test_import_rejects_an_invalid_upload_and_reports_422(client, tmp_path):
    upload = tmp_path / "not-a-db.txt"
    upload.write_text("hello")

    with upload.open("rb") as handle:
        response = client.post(
            "/backup/import",
            files={"file": ("not-a-db.txt", handle, "text/plain")},
        )
    assert response.status_code == 422
    body = response.json()
    assert body["code"] == "invalid_backup_file"
    assert client.get("/backup/status").json()["restore_pending"] is False


def test_cancel_pending_restore_clears_the_staged_file(client, tmp_path):
    upload = tmp_path / "uploaded.db"
    _make_real_db(upload)
    with upload.open("rb") as handle:
        client.post(
            "/backup/import",
            files={"file": ("backup.db", handle, "application/octet-stream")},
        )
    assert client.get("/backup/status").json()["restore_pending"] is True

    response = client.delete("/backup/pending")
    assert response.status_code == 200
    assert response.json()["restore_pending"] is False


# Admin gating for the backup routes now goes through the session-based
# require_admin_user dependency (not the old MM_ADMIN_TOKEN header). Those
# authorization paths — unauthenticated → 401, non-admin → 403, admin → 200 —
# are covered against the full app in tests/test_auth_enforcement.py. The tests
# above run under the suite's default-admin auto-auth and exercise backup
# *mechanics* only.
