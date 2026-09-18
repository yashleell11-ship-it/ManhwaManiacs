"""Database backup export/import.

Export streams a consistent, point-in-time SQLite snapshot (see
``services.backup_service.create_backup_snapshot``). Import validates an
uploaded backup and stages it; the actual file swap only happens the next
time the process starts (``core.backup_restore``), since replacing the live
database file out from under an already-open, process-lifetime SQLAlchemy
engine is not safe to do while the server keeps running. That swap keeps the
database it displaces (``core.backup_restore``), which is what makes a wrong
upload survivable.
"""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

from fastapi import APIRouter, Depends, Request, Response, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel
from starlette.background import BackgroundTask

from core.backup_restore import has_pending_restore, retained_copy_hint
from core.errors import AppError
from core.rate_limit import import_limit, limiter
from services.auth_service import require_admin_user
from services.backup_service import (
    backup_filename,
    clear_pending_restore,
    create_backup_snapshot,
    nightly_status,
    spool_dir,
    stage_restore,
)

router = APIRouter(prefix="/backup", tags=["backup"])


class NightlyBackup(BaseModel):
    """What the nightly job last reported. Absent means it never has."""

    ok: bool
    finished_at: str | None = None
    #: Where the run got to. "done" is clean; anything else names the step that
    #: failed, which separates "backups are broken" from "the disk filled up".
    phase: str | None = None
    bytes: int | None = None


class BackupStatus(BaseModel):
    restore_pending: bool
    #: None means UNKNOWN -- never treat it as healthy. A screen that looked
    #: fine while backups were failing is the thing this field exists to end.
    nightly: NightlyBackup | None = None


class RestoreStaged(BaseModel):
    status: str
    message: str


@router.get("/export", dependencies=[Depends(require_admin_user)])
def export_backup(include_cache: bool = False) -> FileResponse:
    """Download a consistent snapshot of the current database.

    User data by default -- the derived connector caches are emptied out of
    the snapshot (see ``services.backup_service``), so a backup is not mostly
    re-fetchable cover bytes. ``?include_cache=true`` keeps them, for cloning
    a box that should come up warm.
    """
    snapshot_path = create_backup_snapshot(include_cache=include_cache)
    return FileResponse(
        path=snapshot_path,
        media_type="application/octet-stream",
        filename=backup_filename(),
        background=BackgroundTask(
            shutil.rmtree, snapshot_path.parent, ignore_errors=True
        ),
    )


@router.get("/status", response_model=BackupStatus)
def backup_status() -> BackupStatus:
    raw = nightly_status()
    return BackupStatus(
        restore_pending=has_pending_restore(),
        nightly=NightlyBackup(**raw) if raw else None,
    )


@router.post("/import", response_model=RestoreStaged, dependencies=[Depends(require_admin_user)])
@limiter.limit(import_limit)
def import_backup(file: UploadFile, request: Request, response: Response) -> RestoreStaged:
    """Validate an uploaded backup and stage it for restore on next start."""
    # Spooled beside the database, not in the system temp dir: staging is a
    # move to a path in that same directory, and only a same-filesystem move
    # is a rename. Across filesystems it is a copy, so a crash midway leaves a
    # half-written file sitting exactly where the next boot looks for a
    # restore to apply.
    with tempfile.NamedTemporaryFile(
        delete=False, prefix=".mm-upload-", suffix=".db", dir=spool_dir()
    ) as tmp:
        shutil.copyfileobj(file.file, tmp)
        tmp_path = Path(tmp.name)

    try:
        stage_restore(tmp_path)
    except AppError:
        tmp_path.unlink(missing_ok=True)
        raise

    return RestoreStaged(
        status="staged",
        message=(
            "Restore staged. Restart the server to finish applying it. The "
            f"database it replaces is kept beside it as {retained_copy_hint()}, "
            "so a wrong restore can be undone."
        ),
    )


@router.delete("/pending", response_model=BackupStatus, dependencies=[Depends(require_admin_user)])
def cancel_pending_restore() -> BackupStatus:
    """Cancel a staged restore before it's applied on next start."""
    clear_pending_restore()
    return BackupStatus(restore_pending=has_pending_restore())
