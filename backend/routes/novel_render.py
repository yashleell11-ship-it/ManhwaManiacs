"""What the render box talks to.

The box is not a browser and has no session. It presents a shared token on
five literal routes and can do nothing else with it — it can take work, report
progress, and upload audio. It cannot read a library, a user, or another
series' anything. A machine that lives in a house and runs a model somebody
downloaded should hold the smallest credential that lets it do its job.

**No token configured means this router is never mounted.** That is the same
posture as the novels flag itself: a feature that was never built, rather than
an endpoint that exists and refuses. There is nothing here to guess at.

Mounted directly on the app, OUTSIDE the session gate that ``api_router`` and
the novels router carry — so ``require_render_token`` below is the only thing
standing in front of these five paths, not a second line of defence. That is
deliberate and it is why the token is scoped to nothing else, but it means a
route added to this router is exposed the moment it is written. Nothing
belongs here that a session should be required for.

``job_id`` travels in the BODY, never in the path. Keeping every path literal
means there is nothing to pattern-match and no prefix that could widen later.
"""

from __future__ import annotations

import json
import os
from typing import Annotated

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    Header,
    Request,
    Response,
    UploadFile,
)
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
from starlette.exceptions import HTTPException as StarletteHTTPException

from core.auth import tokens_equal
from core.config import get_settings
from database.session import get_db
from routes.novels import require_novels_enabled
from services.chapter_audio_store import chapter_paths
from services.novel_render_plan import build_chapter_plan, plan_digest
from services.voice_pack import load_voices
from services.novel_render_queue import (
    LEASE,
    claim,
    complete,
    fail,
    heartbeat,
    release,
)

#: Chunk size for streaming an upload to disk. Small enough that a 2-core,
#: 3.8 GB box never holds a chapter of audio in memory.
_CHUNK = 64 * 1024

#: A rendered chapter is ~2-3 MB. Ten times that is room for a long chapter at
#: a higher bitrate and still refuses anything that is not audio.
_MAX_UPLOAD = 32 * 1024 * 1024


def require_render_token(
    x_render_token: Annotated[str | None, Header()] = None,
) -> None:
    """The box's shared secret, compared in constant time."""
    configured = str(getattr(get_settings(), "render_worker_token", "") or "")
    if not configured or not x_render_token:
        raise StarletteHTTPException(status_code=401, detail="Unauthorized")
    if not tokens_equal(x_render_token, configured):
        raise StarletteHTTPException(status_code=401, detail="Unauthorized")


router = APIRouter(
    prefix="/novels/render",
    tags=["novels"],
    dependencies=[Depends(require_novels_enabled), Depends(require_render_token)],
)

DbDep = Annotated[Session, Depends(get_db)]


class ClaimRequest(BaseModel):
    worker_id: str = Field(min_length=1, max_length=64)


class JobRef(BaseModel):
    job_id: str = Field(min_length=1, max_length=32)
    worker_id: str = Field(min_length=1, max_length=64)


class Heartbeat(JobRef):
    segments_done: int = Field(default=0, ge=0)


class Failure(JobRef):
    code: str = Field(min_length=1, max_length=48)
    detail: str = Field(default="", max_length=2000)
    retryable: bool = True


class Release(JobRef):
    reason: str = Field(default="", max_length=200)


@router.post("/claim", response_model=None)
def claim_render_job(
    body: ClaimRequest, db: DbDep, response: Response
) -> Response | dict[str, object]:
    """Take the next chapter to narrate, or 204 when there is nothing.

    The plan is built and FROZEN here rather than on the box: planning needs
    the whole series' cast and the owner's voice choices, and the box holds no
    database. It renders exactly what it is given.

    A chapter with no attribution yet is failed back as ``not_attributed``
    rather than held — the worker cannot fix that, and a job that cannot
    progress should not occupy a lease.
    """
    from database.models import NovelChapterCache
    from sqlalchemy import select

    job = claim(db, body.worker_id)
    if job is None:
        db.commit()
        return Response(status_code=204)

    row = db.execute(
        select(NovelChapterCache.paragraphs).where(
            NovelChapterCache.source_id == job.source_id,
            NovelChapterCache.series_key == job.series_key,
            NovelChapterCache.chapter_key == job.chapter_key,
        )
    ).scalar_one_or_none()
    if row is None:
        fail(db, job.id, body.worker_id, "chapter_gone",
             "the chapter left the cache before it could be rendered",
             retryable=False)
        db.commit()
        return Response(status_code=204)

    # Checked separately from the plan so the job says what is actually
    # wrong. A server with no pack installed would otherwise fail every
    # chapter as "not attributed", which is both false and unactionable.
    if not load_voices():
        fail(db, job.id, body.worker_id, "no_voices",
             "no voice pack is installed on the server, so nobody can be cast",
             retryable=False)
        db.commit()
        return Response(status_code=204)

    paragraphs = json.loads(row) or []
    plan = build_chapter_plan(
        db, job.source_id, job.series_key, job.chapter_key, paragraphs
    )
    if plan is None:
        fail(db, job.id, body.worker_id, "not_attributed",
             "this chapter has no attribution, so nobody can be cast in it",
             retryable=False)
        db.commit()
        return Response(status_code=204)

    job.segment_count = len(plan["segments"])
    job.status = "rendering"
    db.commit()
    return {
        "job_id": job.id,
        "lease_seconds": int(LEASE.total_seconds()),
        "source_id": job.source_id,
        "series_key": job.series_key,
        "chapter_key": job.chapter_key,
        "text_fingerprint": job.text_fingerprint,
        "plan": plan,
        "plan_hash": plan_digest(plan),
    }


@router.post("/heartbeat")
def render_heartbeat(body: Heartbeat, db: DbDep) -> dict[str, object]:
    """Still working. Answers whether to stop.

    This is the only way a cancel reaches the box — nothing here can call out
    to a machine behind a home NAT. Called often enough that "cancel" means
    within half a minute rather than at the end of the chapter.
    """
    state = heartbeat(db, body.job_id, body.worker_id, body.segments_done)
    if state is None:
        db.commit()
        raise StarletteHTTPException(status_code=409, detail="lease_lost")
    db.commit()
    return state


@router.post("/complete", response_model=None)
async def complete_render(
    request: Request,
    db: DbDep,
    job_id: Annotated[str, Form(max_length=32)],
    worker_id: Annotated[str, Form(max_length=64)],
    audio: Annotated[UploadFile, File()],
    timing: Annotated[UploadFile, File()],
) -> dict[str, object]:
    """The finished chapter, as bytes.

    Multipart and streamed in chunks, NOT a JSON body: audio never goes
    through SQLite (see ``chapter_audio_store``) and a base64 chapter is a
    needless multi-megabyte spike on a 3.8 GB box.

    Written to ``.tmp`` beside the destination and renamed, so a reader can
    never see a half-written file. The TIMING map lands first, because
    ``read_chapter_audio`` already tolerates audio without a map — "it just
    cannot highlight" — and nothing tolerates a map without audio.
    """
    from services.novel_render_queue import _held

    job = _held(db, job_id, worker_id)
    if job is None or job.status not in ("planning", "rendering"):
        raise StarletteHTTPException(status_code=409, detail="lease_lost")

    audio_path, timing_path = chapter_paths(
        job.source_id, job.series_key, job.chapter_key
    )
    audio_path.parent.mkdir(parents=True, exist_ok=True)
    audio_tmp = audio_path.with_suffix(audio_path.suffix + ".tmp")
    timing_tmp = timing_path.with_suffix(timing_path.suffix + ".tmp")

    try:
        written = await _spool(audio, audio_tmp)
        await _spool(timing, timing_tmp)
        os.replace(timing_tmp, timing_path)
        os.replace(audio_tmp, audio_path)
    except StarletteHTTPException:
        raise
    except OSError as exc:
        fail(db, job_id, worker_id, "upload_failed", str(exc), retryable=True)
        db.commit()
        raise StarletteHTTPException(status_code=500, detail="upload_failed") from exc
    finally:
        for leftover in (audio_tmp, timing_tmp):
            try:
                leftover.unlink(missing_ok=True)
            except OSError:
                pass

    complete(db, job_id, worker_id)
    db.commit()
    return {"available": True, "bytes": written}


async def _spool(upload: UploadFile, target) -> int:
    """Stream one part to disk, refusing anything implausible."""
    total = 0
    with target.open("wb") as handle:
        while chunk := await upload.read(_CHUNK):
            total += len(chunk)
            if total > _MAX_UPLOAD:
                raise StarletteHTTPException(status_code=413, detail="too_large")
            handle.write(chunk)
        handle.flush()
        os.fsync(handle.fileno())
    return total


@router.post("/fail", status_code=204)
def render_failed(body: Failure, db: DbDep) -> Response:
    """This chapter did not render."""
    fail(db, body.job_id, body.worker_id, body.code, body.detail,
         retryable=body.retryable)
    db.commit()
    return Response(status_code=204)


@router.post("/release", status_code=204)
def render_released(body: Release, db: DbDep) -> Response:
    """Give the job back without charging an attempt.

    The GPU was wanted by something else, or rendering was paused. Charging an
    attempt here would mean three training runs permanently exhaust a
    chapter's retries.
    """
    release(db, body.job_id, body.worker_id, body.reason)
    db.commit()
    return Response(status_code=204)
