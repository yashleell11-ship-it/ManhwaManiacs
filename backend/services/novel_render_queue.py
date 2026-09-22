"""The audiobook render queue: what has been asked for, and what became of it.

The server cannot make audio. A chapter of speech is roughly nine minutes on a
GPU that lives in the owner's house, behind a home NAT, asleep half the time
and frequently busy training something else. So this is a pull queue: the
server records what is wanted, the box comes and asks for work.

Two rules do most of the work here.

**Only chapters already in the text cache may be queued.** Rendering reads the
chapter, and reading a chapter that is not cached makes the server fetch it
live from the source. A two-hundred-chapter queue would therefore be a
two-hundred-request scrape, which is precisely how this project already lost
Toonily and Bbato. The same SELECT that proves the row exists yields the
fingerprint the job is pinned to.

**A chapter already in flight cannot be queued twice.** Pressing the button
again is cheap and idempotent rather than two renders racing to write one
file. The database enforces it with a partial unique index, so the guard holds
even against two requests in the same millisecond — this is not a check-then-
act in Python.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from connectors.ids import fully_unquote
from database.models import NovelAudioJob, NovelChapterCache
from services.chapter_audio_store import chapter_paths
from services.novel_attribution_service import chapter_fingerprint

#: In flight. A chapter in any of these has a render either waiting or
#: happening, and must not be queued again.
ACTIVE = ("queued", "planning", "rendering")

#: Nothing further will happen to a job in one of these without a new request.
TERMINAL = ("done", "failed", "cancelled")

#: How long a claim is good for. Long enough that a slow chapter does not lose
#: its lease mid-render, short enough that a box which simply slept does not
#: wedge a chapter for an hour.
LEASE = timedelta(minutes=10)

#: A render that has failed this many times stops being retried. Three is
#: enough to ride out a reboot and a dropped connection, and few enough that a
#: chapter which genuinely cannot be rendered does not burn the card forever.
MAX_ATTEMPTS = 3


@dataclass(frozen=True, slots=True)
class Enqueued:
    """What came of one request to render a list of chapters."""

    queued: tuple[dict[str, str], ...]
    skipped: tuple[dict[str, str], ...]


def _now() -> datetime:
    from database.models import utcnow

    return utcnow()


def enqueue(
    db: Session,
    source_id: str,
    series_key: str,
    chapter_keys: list[str],
    *,
    priority: int = 0,
    force: bool = False,
) -> Enqueued:
    """Ask for these chapters to be narrated.

    Every chapter is answered for: either it is queued with a job id, or it is
    skipped with a reason the UI can show. A partial success is the ordinary
    outcome — asking for a whole book will usually find some chapters already
    rendered — and reporting it as a failure would be wrong.

    ``force`` queues a chapter even though it already has audio. That is the
    case the partial unique index was made partial for: a chapter rendered
    last week must be askable again after the cast or the narrator changed,
    or the new choice never reaches the audio. The old file keeps playing
    until ``complete`` replaces it atomically. It does NOT bypass the
    in-flight guard — two renders racing for one file is never wanted.
    """
    series_key = fully_unquote(series_key)
    queued: list[dict[str, str]] = []
    skipped: list[dict[str, str]] = []

    for raw_key in chapter_keys:
        key = fully_unquote(raw_key)

        audio, _timing = chapter_paths(source_id, series_key, key)
        if not force and audio.is_file():
            skipped.append({"chapter_key": key, "reason": "already_rendered"})
            continue

        cached = db.execute(
            select(
                NovelChapterCache.paragraphs, NovelChapterCache.chapter_number
            ).where(
                NovelChapterCache.source_id == source_id,
                NovelChapterCache.series_key == series_key,
                NovelChapterCache.chapter_key == key,
            )
        ).first()
        if cached is None:
            # Never enqueue a chapter the server would have to fetch. See the
            # module docstring: a bulk queue over cache misses is a scrape.
            skipped.append({"chapter_key": key, "reason": "chapter_not_cached"})
            continue

        try:
            paragraphs = json.loads(cached[0]) or []
        except ValueError:
            skipped.append({"chapter_key": key, "reason": "chapter_unreadable"})
            continue

        job = NovelAudioJob(
            id=uuid.uuid4().hex,
            source_id=source_id,
            series_key=series_key,
            chapter_key=key,
            chapter_number=cached[1],
            text_fingerprint=chapter_fingerprint(paragraphs),
            status="queued",
            priority=priority,
        )
        try:
            # Flushed per job so the unique index answers now: a failure here
            # is one chapter's "already queued", not a lost batch. That is
            # only true inside a SAVEPOINT. A session-level rollback would
            # discard every job flushed earlier in this request while they
            # sat in ``queued`` with ids, and the route would then commit
            # nothing for them. The add goes inside too, so the rejected
            # object leaves the session with its savepoint rather than being
            # flushed again at commit.
            with db.begin_nested():
                db.add(job)
                db.flush()
        except IntegrityError:
            # Caught outside the block so the savepoint has already rolled
            # back just this one insert.
            skipped.append({"chapter_key": key, "reason": "already_queued"})
            continue
        # Only now, after the savepoint closed cleanly, is this row real.
        queued.append({"job_id": job.id, "chapter_key": key})

    return Enqueued(queued=tuple(queued), skipped=tuple(skipped))


def series_jobs(
    db: Session, source_id: str, series_key: str
) -> list[NovelAudioJob]:
    """Every job for one book, newest request first."""
    return list(
        db.execute(
            select(NovelAudioJob)
            .where(
                NovelAudioJob.source_id == source_id,
                NovelAudioJob.series_key == fully_unquote(series_key),
            )
            .order_by(NovelAudioJob.created_at.desc())
        ).scalars()
    )


def active_jobs(db: Session) -> list[NovelAudioJob]:
    """Everything still in flight, across every book.

    For the badge that says something is being narrated. Deliberately small
    and unfiltered by series: a reader who queued a book then went somewhere
    else still wants to know it is working.
    """
    return list(
        db.execute(
            select(NovelAudioJob)
            .where(NovelAudioJob.status.in_(ACTIVE))
            .order_by(NovelAudioJob.priority.desc(), NovelAudioJob.created_at)
        ).scalars()
    )


def cancel(db: Session, job_id: str) -> bool:
    """Stop a job. Returns whether there was one to stop.

    A job being rendered right now is marked cancelled rather than killed —
    nothing here can reach into the box. The worker finds out on its next
    heartbeat and drops the work it has done, which is the right trade: the
    alternative is a server that lies about having stopped.
    """
    job = db.get(NovelAudioJob, job_id)
    if job is None or job.status in TERMINAL:
        return False
    job.status = "cancelled"
    job.finished_at = _now()
    job.updated_at = _now()
    return True


def as_json(job: NovelAudioJob) -> dict[str, object]:
    """One job, as a client reads it."""
    total = job.segment_count or 0
    return {
        "job_id": job.id,
        "chapter_key": job.chapter_key,
        "chapter_number": job.chapter_number,
        "status": job.status,
        # A fraction rather than a count: the client shows a bar, and the
        # number of segments in a chapter is meaningless to a reader.
        "progress": (job.progress_segments / total) if total else 0.0,
        "attempts": job.attempts,
        "error_code": job.error_code,
        "error_detail": job.error_detail,
    }


# --------------------------------------------------------------------------
# What the render box drives. Everything below is reached with the worker
# token, never a session.
# --------------------------------------------------------------------------


def claim(
    db: Session, worker_id: str, *, lease: timedelta = LEASE
) -> NovelAudioJob | None:
    """Take the next queued job, or None when there is nothing to do.

    A conditional UPDATE and nothing else, so two workers cannot take the same
    row: the second one's ``WHERE status='queued'`` matches nothing. The
    in-process ``threading.Lock`` the update scheduler uses is no help here —
    the renderer is a different machine.

    Ordered by priority then age, so "do this chapter next" works and nothing
    starves behind it.
    """
    now = _now()
    candidate = db.execute(
        select(NovelAudioJob.id)
        .where(NovelAudioJob.status == "queued")
        .order_by(NovelAudioJob.priority.desc(), NovelAudioJob.created_at)
        .limit(1)
    ).scalar_one_or_none()
    if candidate is None:
        return None

    taken = db.execute(
        update(NovelAudioJob)
        .where(NovelAudioJob.id == candidate, NovelAudioJob.status == "queued")
        .values(
            status="planning",
            worker_id=worker_id,
            lease_until=now + lease,
            attempts=NovelAudioJob.attempts + 1,
            started_at=func.coalesce(NovelAudioJob.started_at, now),
            updated_at=now,
        )
    )
    if taken.rowcount == 0:
        # Somebody else got there first. The caller tries again or answers
        # "nothing to do"; it must not block.
        return None
    return db.get(NovelAudioJob, candidate)


def _held(db: Session, job_id: str, worker_id: str) -> NovelAudioJob | None:
    """The job, if this worker still holds its lease."""
    job = db.get(NovelAudioJob, job_id)
    if job is None or job.worker_id != worker_id:
        return None
    return job


def heartbeat(
    db: Session,
    job_id: str,
    worker_id: str,
    segments_done: int,
    *,
    lease: timedelta = LEASE,
) -> dict[str, object] | None:
    """Extend the lease and report progress. None when the lease is gone.

    Also how a worker learns it has been cancelled. Nothing on the server can
    reach into the box, so the box has to ask — and it asks often enough that
    "cancel" means within half a minute rather than at the end of the chapter.
    """
    job = _held(db, job_id, worker_id)
    if job is None:
        return None
    if job.status == "cancelled":
        return {"cancelled": True, "lease_seconds": 0}
    if job.status not in ("planning", "rendering"):
        return None
    job.status = "rendering"
    job.progress_segments = max(0, segments_done)
    job.lease_until = _now() + lease
    job.updated_at = _now()
    return {"cancelled": False, "lease_seconds": int(lease.total_seconds())}


def complete(db: Session, job_id: str, worker_id: str) -> bool:
    """Mark a render finished. The BYTES are written by the caller first.

    Ordering matters and is the route's job, not this function's: the files
    must be in place before the row says done, or a reader can be told there
    is audio a moment before there is.
    """
    job = _held(db, job_id, worker_id)
    if job is None or job.status not in ("planning", "rendering"):
        return False
    job.status = "done"
    job.progress_segments = job.segment_count or job.progress_segments
    job.lease_until = None
    job.finished_at = _now()
    job.updated_at = _now()
    return True


def fail(
    db: Session,
    job_id: str,
    worker_id: str,
    code: str,
    detail: str,
    *,
    retryable: bool = True,
) -> bool:
    """Record that a render did not work.

    A retryable failure goes back in the queue until it has burned
    [MAX_ATTEMPTS]; anything else stops immediately. The distinction matters
    because the two common failures are opposites — a dropped connection
    should be tried again, and a chapter the model cannot read never will be.
    """
    job = _held(db, job_id, worker_id)
    if job is None or job.status in TERMINAL:
        return False
    job.error_code = code[:48]
    # Truncated at write: a raw traceback in a row a client reads is both a
    # disclosure and an unbounded column.
    job.error_detail = (detail or "")[:500]
    job.worker_id = None
    job.lease_until = None
    if retryable and job.attempts < MAX_ATTEMPTS:
        job.status = "queued"
    else:
        job.status = "failed"
        job.finished_at = _now()
    job.updated_at = _now()
    return True


def release(db: Session, job_id: str, worker_id: str, reason: str) -> bool:
    """Put a job back untouched, without charging an attempt.

    This is the GPU being wanted by something else, or the owner pausing
    rendering — not a failure. Charging an attempt would mean three training
    runs permanently burn a chapter's retries.
    """
    job = _held(db, job_id, worker_id)
    if job is None or job.status in TERMINAL:
        return False
    job.status = "queued"
    job.worker_id = None
    job.lease_until = None
    job.attempts = max(0, job.attempts - 1)
    job.error_code = None
    job.error_detail = reason[:500] if reason else None
    job.updated_at = _now()
    return True


def reap_expired(db: Session) -> int:
    """Return jobs whose worker went away. Returns how many.

    Without this a box that slept mid-render wedges that chapter forever: the
    row says ``rendering`` and no worker will ever claim it again. The lease
    is a wall clock precisely so this can run in a different process, after a
    restart, and still be right.
    """
    now = _now()
    stale = list(
        db.execute(
            select(NovelAudioJob).where(
                NovelAudioJob.status.in_(("planning", "rendering")),
                NovelAudioJob.lease_until.is_not(None),
                NovelAudioJob.lease_until < now,
            )
        ).scalars()
    )
    for job in stale:
        job.worker_id = None
        job.lease_until = None
        if job.attempts >= MAX_ATTEMPTS:
            job.status = "failed"
            job.error_code = "lease_expired"
            job.error_detail = "the render box stopped answering"
            job.finished_at = now
        else:
            job.status = "queued"
        job.updated_at = now
    return len(stale)
