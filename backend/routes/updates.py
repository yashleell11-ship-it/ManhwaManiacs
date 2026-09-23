"""Automatic update system API routes (source-native, spec §4.5).

Following a series is ``POST /library/follow`` now; this router is the
update-check settings, the resulting notifications, and the run log.

A notification names a series and a chapter title, so every notification path
here — list, count, mark-one, mark-all — is scoped to the caller's
(user, profile) *and* passed through that profile's 18+ gate; a withheld one is
absent, never a 403. See ``UpdateService._visible_notifications``.
"""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Query, Response
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.errors import AppError
from core.profile_context import ProfileContext, resolve_profile_context
from database.models import User
from database.session import get_db
from services.auth_service import get_current_user, require_admin_user
from services.update_scheduler import get_update_manager
from services.update_service import UpdateService, get_update_service
from utils.api_pagination import set_list_total_header

router = APIRouter(prefix="/updates", tags=["updates"])


def _service(
    db: Session = Depends(get_db),
    ctx: ProfileContext = Depends(resolve_profile_context),
) -> UpdateService:
    return get_update_service(db, user_id=ctx.user_id, profile_id=ctx.profile_id)


UpdateDep = Annotated[UpdateService, Depends(_service)]


class GlobalSettingsUpdate(BaseModel):
    enabled: bool | None = None
    check_interval_minutes: int | None = Field(default=None, ge=5)
    notify_enabled: bool | None = None
    check_on_startup: bool | None = None


class MarkAllReadRequest(BaseModel):
    # The content mode the screen is showing; omitted means every mode.
    content_kind: Literal["manga", "novel"] | None = None


class ManualCheckRequest(BaseModel):
    followed_ids: list[int] | None = None


@router.get("/settings")
def get_settings(service: UpdateDep) -> dict[str, object]:
    return service.serialize_settings(service.get_global_settings())


@router.put("/settings", dependencies=[Depends(require_admin_user)])
def put_settings(body: GlobalSettingsUpdate, service: UpdateDep) -> dict[str, object]:
    """Rewrite the instance-global update scheduler settings. **Admin only**:
    this is the singleton row that governs the sweep, its interval, and
    notification creation for *every* account — an ungated write let any
    authenticated user silently disable everyone's notifications (audit
    findings 1/5/7). ``GET /updates/settings`` stays user-visible."""
    return service.update_global_settings(body.model_dump(exclude_none=True))


@router.get("/sources")
def list_sources(service: UpdateDep) -> list[dict[str, str]]:
    return service.list_sources()


@router.get("/notifications")
def list_notifications(
    service: UpdateDep,
    response: Response,
    unread_only: bool = Query(default=False),
    limit: int = Query(default=100, ge=1, le=500),
) -> list[dict[str, object]]:
    items = service.list_notifications(unread_only=unread_only, limit=limit)
    set_list_total_header(
        response, service.count_notifications(unread_only=unread_only)
    )
    return items


@router.get("/notifications/unread-count")
def unread_count(service: UpdateDep) -> dict[str, int]:
    return {"count": service.unread_count()}


@router.patch("/notifications/{notification_id}/read")
def mark_read(notification_id: int, service: UpdateDep) -> dict[str, object]:
    return service.mark_notification_read(notification_id)


@router.post("/notifications/read-all")
def mark_all_read(
    service: UpdateDep, body: MarkAllReadRequest | None = None
) -> dict[str, int]:
    """Mark every visible unread notification read — or, with
    ``content_kind``, only those of the mode the client's screen shows. The
    body is optional so a client that sends none keeps the old behaviour."""
    return service.mark_all_notifications_read(
        content_kind=body.content_kind if body is not None else None
    )


@router.get("/runs", dependencies=[Depends(require_admin_user)])
def list_runs(
    service: UpdateDep,
    response: Response,
    limit: int = Query(default=20, ge=1, le=100),
) -> list[dict[str, object]]:
    """The run log. **Admin only**: ``update_runs`` has no owner column — a
    row's ``series_checked`` / ``new_chapters_found`` aggregate every account
    on the instance — so it is gated with the settings that drive the sweep.
    A member's own check returns its run inline from ``POST /updates/check``."""
    items = service.list_runs(limit=limit)
    set_list_total_header(response, service.count_runs())
    return items


@router.get("/runs/{run_id}", dependencies=[Depends(require_admin_user)])
def get_run(run_id: int, service: UpdateDep) -> dict[str, object]:
    return service.get_run(run_id)


@router.post("/check")
def manual_check(
    body: ManualCheckRequest,
    service: UpdateDep,
    user: Annotated[User, Depends(get_current_user)],
) -> dict[str, object]:
    """Trigger an update check. Runs on a worker thread when the pool is up.

    The worker path hands the ids to ``run_check_in_new_session``, which runs a
    *system*-scoped service on its own session — so the ownership check has to
    happen here, before the ids leave the request. Without it any authenticated
    caller could force a check on another account's followed series.

    An id-less request is the instance-wide sweep only for an admin. For a
    member it used to be exactly that as well — every account's rows, with the
    aggregate readable off the run log — so it now resolves to the caller's own
    library, which is what the client's "check now" button means anyway. The
    resolved list is passed through even when empty: ``None`` is the sweep.
    """
    manager = get_update_manager()
    if body.followed_ids:
        followed_ids = service.resolve_followed_ids(body.followed_ids)
    elif user.is_admin:
        followed_ids = None
    else:
        followed_ids = service.owned_followed_ids()
    if not manager.is_running:
        return service.run_check(trigger="manual", followed_ids=followed_ids)
    if manager.trigger_check(trigger="manual", tracker_ids=followed_ids):
        return {"queued": True, "trigger": "manual"}
    raise AppError(
        "An update check is already running.",
        code="check_already_running",
        status_code=409,
    )


@router.post("/followed/{followed_id}/check")
def check_followed(followed_id: int, service: UpdateDep) -> dict[str, object]:
    return service.check_followed_by_id(followed_id)
