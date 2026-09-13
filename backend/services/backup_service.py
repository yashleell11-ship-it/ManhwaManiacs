"""Backup export/import: safe, consistent SQLite snapshots.

Export uses SQLite's own ``VACUUM INTO`` to produce a single-file, fully
consistent snapshot regardless of WAL mode or concurrent readers/writers --
the standard, SQLite-native way to hot-backup a live database without
contending with the app's own connection pool. The cache tables' rows are
left out by default (their schema is kept, so the file still restores).

Import never touches the live, already-open (and process-lifetime cached)
SQLAlchemy engine. Restoring a database file while connections are open
against the old one is unsafe, so an uploaded backup is only *validated* and
staged; :mod:`core.backup_restore` swaps it in the next time the process
starts, before anything opens the database.
"""

from __future__ import annotations

import shutil
import sqlite3
import tempfile
from datetime import datetime
from pathlib import Path

from core.cache_tables import CACHE_TABLES
from core.backup_restore import (
    has_pending_restore,
    pending_restore_path,
    read_only_uri,
    unknown_revision_problem,
)
from core.config import get_settings
from core.errors import AppError

# Tables that must exist for an uploaded file to be considered a genuine
# ManhwaManiacs backup, rather than an arbitrary or corrupt SQLite file.
# Source-native schema (spec §3): the catalog tables are gone.
_REQUIRED_TABLES = {"users", "followed_series", "chapter_progress", "alembic_version"}

# Pure derived data that the next connector fetch rebuilds on demand. On the
# live box these four are ~97% of the file, so an export that carried them
# would be dominated by bytes that are worthless the moment they are restored.
# Nothing references them by foreign key, so emptying them leaves no orphans.
#
# Imported rather than written out here, because the nightly host job
# (ops/vps/backup-db.sh) needs the same list and cannot import this module —
# it runs under the VPS's system python with no virtualenv. See
# core/cache_tables for why one tuple, and for what the drift cost.
_CACHE_TABLES = CACHE_TABLES


def spool_dir() -> Path:
    """Where snapshots and uploads are written while being built.

    Beside the database, not in the system temp dir: in the container that
    is the small, shared root overlay rather than the data volume, and only
    a same-filesystem rename makes the final move into place atomic.
    """
    directory = Path(get_settings().db_path).parent
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def backup_filename() -> str:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"manhwamaniacs-backup-{stamp}.db"


def create_backup_snapshot(*, include_cache: bool = False) -> Path:
    """Write a consistent, point-in-time snapshot to a fresh temp file.

    Uses a *separate* sqlite3 connection (not the app's SQLAlchemy engine),
    so this never contends with or blocks the live app's connection pool.
    ``VACUUM INTO`` also compacts the snapshot, so exports are never larger
    than the data actually requires.

    Caller owns the returned path's parent directory and is responsible for
    cleaning it up once the snapshot has been used (e.g. after streaming it
    as a download).
    """
    settings = get_settings()
    source = Path(settings.db_path)
    tmp_dir = Path(tempfile.mkdtemp(prefix=".mm-export-", dir=spool_dir()))
    snapshot_path = tmp_dir / "backup.db"

    # Read-only, like the nightly job (ops/vps/backup-db.sh): VACUUM INTO
    # needs only a read transaction, and this connection must have no way to
    # write to the live database whatever else happens on the way out. It
    # reads through the WAL under a read lock, so the snapshot includes
    # commits the main file has not been checkpointed with yet.
    #
    # A box whose database file does not exist yet snapshots an empty
    # in-memory database instead: the same empty-but-valid file a plain
    # connection would have produced, minus the side effect of that
    # connection *creating* db_path on the way past.
    origin = read_only_uri(source) if source.exists() else "file::memory:"
    connection = sqlite3.connect(origin, uri=True)
    try:
        connection.execute("VACUUM INTO ?", (str(snapshot_path),))
    finally:
        connection.close()

    if not include_cache:
        _drop_cache_rows(snapshot_path)
    return snapshot_path


def _drop_cache_rows(snapshot_path: Path) -> None:
    """Empty the cache tables in the snapshot, keeping their schema.

    A ``DELETE`` alone leaves the freed pages allocated in the file, so the
    snapshot is vacuumed afterwards; that is what actually makes it small.
    """
    connection = sqlite3.connect(str(snapshot_path))
    try:
        present = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        for table in _CACHE_TABLES:
            if table in present:
                connection.execute(f"DELETE FROM {table}")
        connection.commit()
        connection.execute("VACUUM")
    finally:
        connection.close()


def _validate_backup_file(path: Path) -> None:
    """Raise ``AppError`` unless ``path`` is an intact ManhwaManiacs backup
    this build can restore.

    SQLite lazily validates a file's format on first real access rather than
    at ``connect()`` time, so both the connection and the queries are wrapped
    together -- an arbitrary non-database file only fails once queried.

    Listing ``sqlite_master`` only proves page 1 is sane. ``integrity_check``
    walks every b-tree, so a file whose data pages are damaged is caught
    here instead of after it has replaced the live database; and
    ``foreign_key_check`` catches rows that point at nothing, which the
    app's ``foreign_keys=ON`` connections would otherwise trip over one
    cascade at a time.
    """
    try:
        connection = sqlite3.connect(read_only_uri(path), uri=True)
        try:
            table_names = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            missing = _REQUIRED_TABLES - table_names
            if missing:
                raise AppError(
                    "That file doesn't look like a ManhwaManiacs backup "
                    f"(missing tables: {', '.join(sorted(missing))}).",
                    code="invalid_backup_file",
                    status_code=422,
                )

            integrity = [
                row[0] for row in connection.execute("PRAGMA integrity_check")
            ]
            if integrity != ["ok"]:
                raise AppError(
                    "That backup is corrupt and can't be restored "
                    f"(integrity_check: {'; '.join(integrity[:3])}).",
                    code="invalid_backup_file",
                    status_code=422,
                )

            violations = connection.execute("PRAGMA foreign_key_check").fetchall()
            if violations:
                table, rowid, parent, _ = violations[0]
                raise AppError(
                    f"That backup has {len(violations)} row(s) referencing "
                    f"missing parents (first: {table} rowid {rowid} -> {parent}) "
                    "and can't be restored.",
                    code="invalid_backup_file",
                    status_code=422,
                )
        finally:
            connection.close()
    except sqlite3.DatabaseError as exc:
        raise AppError(
            f"That file isn't a valid SQLite database ({exc}).",
            code="invalid_backup_file",
            status_code=422,
        ) from exc

    problem = unknown_revision_problem(path)
    if problem is not None:
        raise AppError(
            f"That backup can't be restored by this server: {problem}.",
            code="backup_schema_unknown",
            status_code=422,
        )


def stage_restore(uploaded_path: Path) -> None:
    """Validate an uploaded backup file, then stage it for restore on next start.

    Raises ``AppError`` (and leaves nothing staged) if the file doesn't look
    like a genuine backup.
    """
    _validate_backup_file(uploaded_path)
    target = pending_restore_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(uploaded_path), str(target))


def restore_pending() -> bool:
    return has_pending_restore()


def clear_pending_restore() -> bool:
    """Cancel a staged restore. Returns ``True`` if one was actually cleared."""
    target = pending_restore_path()
    if not target.exists():
        return False
    target.unlink()
    return True
