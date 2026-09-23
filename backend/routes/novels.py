"""Novel chapter-text endpoint (spec 2026-09-04-novels-design §3).

DARK IN PRODUCTION: this router is only mounted when MM_NOVELS_ENABLED is on
(see ``create_app``), so on an unflagged deployment ``/novels/*`` is a stock
404 — indistinguishable from a route that was never built, which is the
point. The router-level dependency below re-checks the flag as belt and
braces for any process whose settings flipped after mount.

Browse/search/detail for novel sources need no routes of their own: a novel
source is a source, so the existing ``/sources/*`` surface serves them the
moment the registry gate lets the connectors through.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from typing import Annotated, Literal

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Query,
    Request,
    Response,
)
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session
from pydantic import BaseModel, Field
from starlette.exceptions import HTTPException as StarletteHTTPException

from connectors.ids import fully_unquote
from core.config import get_settings
from core.errors import AppError
from core.rate_limit import bulk_limit, limiter, sources_limit
from database.session import get_db
from services.auth_service import require_admin_user
from services.chapter_audio_m4a import (
    TranscodeFailed,
    TranscodeTimeout,
    ensure_m4a,
)
from services.chapter_audio_store import (
    chapter_paths,
    read_chapter_audio,
    rendered_chapters,
)
from services.novel_attribution_service import (
    UNCHANGED,
    chapter_fingerprint,
    correct_cast_member,
    merge_alias,
    read_attribution,
    set_narrator_voice,
)
from database.models import NovelChapterCache
from sqlalchemy import select
from services.novel_render_queue import (
    active_jobs,
    as_json,
    cancel,
    enqueue,
    series_jobs,
)
from services.novel_service import NovelService, get_novel_service
from services.voice_pack import is_known_voice, load_voices, sample_path


def require_novels_enabled() -> None:
    """404 (the stock not-found shape) when the novels flag is off."""
    if not bool(getattr(get_settings(), "novels_enabled", False)):
        raise StarletteHTTPException(status_code=404, detail="Not Found")


router = APIRouter(
    prefix="/novels",
    tags=["novels"],
    dependencies=[Depends(require_novels_enabled)],
)

NovelDep = Annotated[NovelService, Depends(get_novel_service)]
DbDep = Annotated[Session, Depends(get_db)]

#: For the writes that change a book for EVERYBODY. Casting, the narrator and
#: aliases are per-series rows with no user id, and render jobs have no owner,
#: so without this any signed-in account could recast the owner's book, book
#: the owner's GPU, or cancel every job in the instance (the active list hands
#: out every job id). Reads stay open: anyone may see who speaks and what is
#: being narrated.
OWNER_ONLY = [Depends(require_admin_user)]


@router.get("/chapter")
@limiter.limit(sources_limit)
def get_novel_chapter(
    request: Request,
    response: Response,  # slowapi injects X-RateLimit-* headers into this
    service: NovelDep,
    source: str = Query(..., min_length=1, max_length=64),
    series: str = Query(..., min_length=1, max_length=512),
    chapter: str = Query(..., min_length=1, max_length=512),
) -> dict[str, object]:
    """One chapter as sanitized plain-text paragraphs.

    ``{title, chapter_number, paragraphs: [str], prev, next, word_count}``
    plus the identity triple and the standard ``cache`` block. Query-param
    identity (like ``/reader/chapter/manifest``) because connector keys are
    opaque strings that may contain slashes and percent-encoding.

    Rate-limited on the ``sources`` bucket — a cache miss is a full upstream
    page scrape on the sync threadpool.
    """
    return service.get_chapter(source, series, chapter)


@router.get("/attribution")
@limiter.limit(sources_limit)
def get_novel_attribution(
    request: Request,
    response: Response,  # slowapi injects X-RateLimit-* headers into this
    db: DbDep,
    source: str = Query(..., min_length=1, max_length=64),
    series: str = Query(..., min_length=1, max_length=512),
    chapter: str = Query(..., min_length=1, max_length=512),
) -> dict[str, object]:
    """Who speaks each quoted line of a chapter, when that is already known.

    ``{attributed, text_fingerprint, spans: [{p, s, e, head, speaker}], cast}``.

    READ-ONLY, deliberately. Attribution costs money per chapter, so it is
    bought by an explicit bulk pass and never as a side effect of somebody
    turning a page — otherwise scrolling a chapter list quietly spends.

    An unattributed chapter answers ``attributed: false`` rather than 404: it
    is an ordinary state for most of the library, not a missing resource, and a
    client asking for every chapter should not be reading error paths.

    ``text_fingerprint`` is what lets the client prove the offsets still
    describe the text it is showing. The chapter cache refetches, so they will
    eventually disagree, and tinting against moved offsets is worse than not
    tinting at all.
    """
    return read_attribution(db, source, series, chapter)


@router.get("/audio")
@limiter.limit(sources_limit)
def get_novel_audio(
    request: Request,
    response: Response,  # slowapi injects X-RateLimit-* headers into this
    db: DbDep,
    source: str = Query(..., min_length=1, max_length=64),
    series: str = Query(..., min_length=1, max_length=512),
    chapter: str = Query(..., min_length=1, max_length=512),
) -> dict[str, object]:
    """Whether this chapter has been rendered, and where each sentence sits.

    ``{available, bytes, total_ms, highlight_safe, segments: [{i, start_ms,
    end_ms, p, s, e, voice, speaker, speech}]}``.

    The timings are MEASURED, not estimated: each segment was rendered on its
    own, so its duration is the length of the samples that came back. That is
    what a client follows along with.

    Absence is not an error. Almost nothing in the library is rendered, and a
    client asking about every chapter should not be reading error paths for the
    ordinary case.

    ``highlight_safe`` says whether the segment offsets still point at the
    text a reader is shown. The audio is kept when the chapter is refetched
    and comes back a character different, but its offsets then land on the
    wrong words — so a client still plays it, and only follows along when
    this is true.
    """
    found = read_chapter_audio(source, series, chapter)
    return {
        "available": found.available,
        "bytes": found.bytes,
        "total_ms": found.total_ms,
        "highlight_safe": found.available and _highlight_safe(
            db, source, series, chapter, found.text_fingerprint, found.segments
        ),
        "segments": list(found.segments),
    }


#: What may legitimately follow a paragraph's last spoken segment. The render
#: cuts closing quotation marks off the sentence it voices, so measured over
#: all 488 narrated paragraphs in production (2026-09-23) the leftover was
#: empty 372 times and exactly one closing quote 116 times — never anything
#: else.
_UNSPOKEN_TAIL = frozenset(" \t\n\u201d\u2019\"'\u00bb\u300d\u300f)")


def _highlight_safe(
    db: Session,
    source: str,
    series: str,
    chapter: str,
    recorded: str | None,
    segments: Sequence[dict] = (),
) -> bool:
    """Whether the render was cut from the text ``/novels/chapter`` serves now.

    With a recorded fingerprint, true only when it equals the current text's.
    A chapter no longer in the text cache (the next read would fetch it fresh,
    and it may differ) is "cannot tell" — and a highlight on the wrong words is
    worse than none, so that answers false.

    Without one, the map predates the field: every chapter narrated before
    2026-09-23 was cut by the manual render tool, which never wrote it.
    Answering false there switched follow-along OFF for every chapter anyone
    had — a regression dressed as caution, since nothing checked at all
    before. Those maps are checked STRUCTURALLY instead, against the text:
    every segment inside a real paragraph, every paragraph voiced, and each
    paragraph's last segment ending at the paragraph's end but for closing
    quotes. An edit to a narrated chapter almost always moves a paragraph end
    or the paragraph count; a map that survives all three still points at the
    words it was cut from.

    The cache row is looked up the way ``NovelService.get_chapter`` looks it
    up, keys unquoted, because that is the text a reader is actually shown.
    Read-only: this must not bump the row in the LRU order.
    """
    stored = db.execute(
        select(NovelChapterCache.paragraphs).where(
            NovelChapterCache.source_id == source,
            NovelChapterCache.series_key == fully_unquote(series),
            NovelChapterCache.chapter_key == fully_unquote(chapter),
        )
    ).scalar_one_or_none()
    if stored is None:
        return False
    try:
        paragraphs = json.loads(stored)
    except ValueError:
        return False
    if not isinstance(paragraphs, list):
        return False
    if recorded:
        return chapter_fingerprint(paragraphs) == recorded
    return _segments_fit_text(segments, paragraphs)


def _segments_fit_text(segments: Sequence[dict], paragraphs: list) -> bool:
    """The structural check for a timing map with no fingerprint."""
    if not segments:
        return False
    last_end: dict[int, int] = {}
    for segment in segments:
        try:
            p, s, e = int(segment["p"]), int(segment["s"]), int(segment["e"])
        except (KeyError, TypeError, ValueError):
            return False
        if not (0 <= p < len(paragraphs)) or not isinstance(paragraphs[p], str):
            return False
        if not (0 <= s <= e <= len(paragraphs[p])):
            return False
        last_end[p] = max(last_end.get(p, 0), e)
    voiced_all = all(
        i in last_end
        for i, text in enumerate(paragraphs)
        if isinstance(text, str) and text.strip()
    )
    if not voiced_all:
        return False
    return all(
        set(paragraphs[p][end:]) <= _UNSPOKEN_TAIL for p, end in last_end.items()
    )


@router.get("/audio/series")
@limiter.limit(sources_limit)
def get_novel_series_audio(
    request: Request,
    response: Response,  # slowapi injects X-RateLimit-* headers into this
    db: DbDep,
    source: str = Query(..., min_length=1, max_length=64),
    series: str = Query(..., min_length=1, max_length=512),
) -> dict[str, object]:
    """Which chapters of this book have audio.

    One call so a table of contents can mark what is listenable. Asking per
    chapter would be several hundred round trips for a long book, and every
    one of them would answer "no".

    The chapter list comes from the text cache, which is what bounds the
    answer: audio only ever exists for a chapter that was cached when it was
    rendered. That has an edge the client should not be surprised by — the
    cache is an LRU, so an evicted chapter's audio is still on disk and still
    plays, it just stops being advertised here until the text is fetched
    again. A durable record of what has been rendered arrives with the job
    table; until then this is honest about being derived.
    """
    keys = list(
        db.execute(
            select(NovelChapterCache.chapter_key).where(
                NovelChapterCache.source_id == source,
                NovelChapterCache.series_key == series,
            )
        ).scalars()
    )
    found = rendered_chapters(source, series, keys)
    return {
        "source_id": source,
        "series_key": series,
        "chapters": [
            {"chapter_key": key, "bytes": meta["bytes"],
             "has_timing": bool(meta["has_timing"])}
            for key, meta in sorted(found.items())
        ],
        # Which chapters COULD be narrated. Rendering reads the chapter, and
        # reading one that is not cached makes the server fetch it live — so
        # the client needs this to grey out what it cannot ask for, rather
        # than offering it and having the request refused.
        "narratable": sorted(keys),
        # Whether a render box is configured at all. Without one a queued
        # chapter is never claimed and would read "in progress" forever, so
        # the client hides the request instead of offering it. Configuration
        # rather than a heartbeat because nothing records a heartbeat; this
        # is the same test that decides whether the box's routes are mounted.
        "can_render": _render_worker_configured(),
    }


def _render_worker_configured() -> bool:
    """Whether a render box can claim work from this server at all.

    One definition, used both to tell clients whether to offer narration and
    to refuse a request when they should not have — so the flag and the
    refusal cannot disagree. Configuration rather than a heartbeat because
    nothing records a heartbeat; this is the same test that decides whether
    the box's routes are mounted.
    """
    return bool(str(getattr(get_settings(), "render_worker_token", "") or ""))


class AudioRenderRequest(BaseModel):
    """Ask for chapters to be narrated."""

    model_config = {"extra": "ignore"}

    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)

    #: Bounded because each one is about nine minutes on a shared GPU. A
    #: whole long book is a legitimate ask, but it should be a deliberate one
    #: made in batches rather than a single click that books three days of
    #: card time.
    chapter_keys: list[str] = Field(min_length=1, max_length=200)
    priority: int = Field(default=0, ge=0, le=9)

    #: Queue chapters that already have audio, e.g. after recasting. Off by
    #: default so "narrate the whole book" never re-renders what is done.
    force: bool = False


@router.post("/audio/render", dependencies=OWNER_ONLY)
@limiter.limit(sources_limit)
def request_novel_audio(
    request: Request,
    response: Response,
    body: AudioRenderRequest,
    db: DbDep,
) -> dict[str, object]:
    """Queue chapters for narration.

    POST and not GET for the same reason ``/novels/chapters`` is: the body is
    a list of opaque connector keys that routinely contain slashes, and two
    hundred of them do not belong in a query string.

    Every chapter is answered for — queued with an id, or skipped with a
    reason. Partial success is the ordinary outcome when somebody asks for a
    whole book, and calling it a failure would be wrong.

    Refused outright when no render box is configured. New clients read
    ``can_render`` and never offer this; the refusal is for clients that
    predate the flag — 3.2.0 phones — which would otherwise report chapters
    "queued" that nothing will ever claim, and show them waiting forever.
    """
    if not _render_worker_configured():
        raise AppError(
            "Narration of new chapters is not available right now.",
            code="narration_unavailable",
            status_code=503,
        )
    result = enqueue(
        db, body.source_id, body.series_key, body.chapter_keys,
        priority=body.priority, force=body.force,
    )
    db.commit()
    return {"queued": list(result.queued), "skipped": list(result.skipped)}


@router.get("/audio/jobs")
@limiter.limit(sources_limit)
def list_novel_audio_jobs(
    request: Request,
    response: Response,
    db: DbDep,
    source: str = Query(..., min_length=1, max_length=64),
    series: str = Query(..., min_length=1, max_length=512),
) -> dict[str, object]:
    """Every render asked for on this book, and where each one got to."""
    return {"jobs": [as_json(job) for job in series_jobs(db, source, series)]}


@router.get("/audio/jobs/active")
@limiter.limit(sources_limit)
def list_active_novel_audio_jobs(
    request: Request,
    response: Response,
    db: DbDep,
) -> dict[str, object]:
    """Everything still being narrated, across every book.

    Deliberately not filtered by series: somebody who queued a book and then
    went to read something else still wants to know it is working.
    """
    return {"jobs": [as_json(job) for job in active_jobs(db)]}


@router.delete(
    "/audio/jobs/{job_id}", status_code=204, dependencies=OWNER_ONLY
)
@limiter.limit(sources_limit)
def cancel_novel_audio_job(
    request: Request,
    response: Response,
    job_id: str,
    db: DbDep,
) -> Response:
    """Stop a render.

    A job already on the card is marked cancelled rather than killed — nothing
    here can reach into the render box. It finds out on its next heartbeat.
    Saying "stopped" and meaning "will stop shortly" is the honest version;
    pretending to have killed it is not.
    """
    if not cancel(db, job_id):
        raise StarletteHTTPException(status_code=404, detail="Not Found")
    db.commit()
    return Response(status_code=204)


@router.get("/audio/file")
@limiter.limit(sources_limit)
def get_novel_audio_file(
    request: Request,
    response: Response,
    source: str = Query(..., min_length=1, max_length=64),
    series: str = Query(..., min_length=1, max_length=512),
    chapter: str = Query(..., min_length=1, max_length=512),
    audio_format: Literal["ogg", "m4a"] = Query("ogg", alias="format"),
) -> FileResponse:
    """The rendered chapter, as a file.

    ``format=ogg`` (the default) is the stored Ogg Opus. ``format=m4a`` is
    AAC in MP4, for iOS: AVPlayer cannot open Ogg at all. The m4a is made from
    the opus on the first request and served from disk after that (see
    ``services.chapter_audio_m4a``); this is a plain ``def`` so FastAPI runs
    that first transcode on a worker thread, never on the event loop.

    ``FileResponse`` and not a streamed body on purpose: it sets
    ``Accept-Ranges`` and answers a ``Range`` with a 206, which was verified
    against Starlette's source rather than assumed. Without that, every seek in
    a player re-downloads the whole chapter — and iOS will not play a
    progressive MP4 at all from a server that ignores Range.
    """
    audio, _timing = chapter_paths(source, series, chapter)
    if not audio.is_file():
        raise StarletteHTTPException(status_code=404, detail="Not Found")
    if audio_format == "ogg":
        return FileResponse(audio, media_type="audio/ogg")

    try:
        m4a = ensure_m4a(audio)
    except FileNotFoundError:
        # Removed between the check above and the transcode.
        raise StarletteHTTPException(status_code=404, detail="Not Found")
    except TranscodeTimeout:
        raise AppError(
            "This chapter's audio is still being prepared. Try again shortly.",
            code="audio_preparing",
            status_code=503,
        )
    except TranscodeFailed:
        raise AppError(
            "This chapter's audio could not be prepared for this device.",
            code="audio_convert_failed",
            status_code=500,
        )
    return FileResponse(m4a, media_type="audio/mp4")


@router.get("/voices")
@limiter.limit(sources_limit)
def list_novel_voices(request: Request, response: Response) -> dict[str, object]:
    """Every voice a character can be given, deepest first within each gender.

    Served rather than hard-coded in the clients because the pack is data on
    disk: adding a voice is dropping a clip and a manifest line, and a client
    that shipped its own list would disagree with the renderer the moment that
    happened.

    An empty list is a real answer — a deployment with no pack installed can
    still read novels, it just cannot give anyone a voice yet.
    """
    return {"voices": [voice.as_json() for voice in load_voices()]}


@router.get("/voices/sample")
@limiter.limit(sources_limit)
def get_novel_voice_sample(
    request: Request,
    response: Response,
    voice: str = Query(..., min_length=1, max_length=64),
) -> FileResponse:
    """The clip demonstrating one voice.

    ``FileResponse`` for the same reason the chapter audio uses it: Range and
    206, so scrubbing a preview does not refetch it.

    The path comes from the manifest, never from joining ``voice`` onto the
    directory — it arrives off a query string, and a path built from user input
    is one ``../`` away from serving whatever else is on the box.
    """
    path = sample_path(voice)
    if path is None:
        raise StarletteHTTPException(status_code=404, detail="Not Found")
    return FileResponse(path, media_type="audio/ogg")


class NarratorVoice(BaseModel):
    """Choose the voice that reads narration for a series."""

    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)

    #: Null restores the derived default rather than silencing narration.
    voice_id: str | None = Field(default=None, max_length=64)


@router.post("/narrator", dependencies=OWNER_ONLY)
@limiter.limit(sources_limit)
def set_novel_narrator_voice(
    request: Request,
    response: Response,
    body: NarratorVoice,
    db: DbDep,
) -> dict[str, object]:
    """Pin the narration voice for a whole series.

    Separate from ``/cast`` because the narrator is a property of the BOOK, not
    a character in it. A chapter narrated by somebody in the cast still reads
    in that character's own voice — they are the same person — so this is the
    voice for narration that belongs to nobody.
    """
    if body.voice_id and not is_known_voice(body.voice_id):
        raise HTTPException(status_code=400, detail="unknown voice")
    row = set_narrator_voice(db, body.source_id, body.series_key, body.voice_id)
    db.commit()
    return {"narrator_voice_id": row}


class CastCorrection(BaseModel):
    """Set a character's gender or voice by hand."""

    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)
    name: str = Field(min_length=1, max_length=128)
    gender: str | None = Field(default=None, pattern="^(male|female|unknown)$")

    #: Three states, told apart by whether the field was SENT: a voice id
    #: pins it, an explicit null clears the pin ("Automatic voice"), and
    #: leaving it out changes nothing — which is what a gender-only
    #: correction does.
    voice_id: str | None = Field(default=None, max_length=64)


class AliasMerge(BaseModel):
    """Declare that one name is another character."""

    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)
    alias: str = Field(min_length=1, max_length=128)
    canonical: str = Field(min_length=1, max_length=128)


@router.post("/cast", dependencies=OWNER_ONLY)
@limiter.limit(sources_limit)
def correct_cast(
    request: Request,
    response: Response,
    body: CastCorrection,
    db: DbDep,
) -> dict[str, object]:
    """Pin a character's gender or voice.

    Marks the row ``locked``, which is the point: gender is otherwise
    recomputed from pronoun counts on every recast, and somebody who has
    listened to the book knows things the counts do not.
    """
    # A voice the renderer does not have is not a preference, it is a chapter
    # that silently reads as narrator. Refuse it here rather than storing it.
    if body.voice_id and not is_known_voice(body.voice_id):
        raise HTTPException(status_code=400, detail="unknown voice")
    # A default of None cannot tell "null" from "absent", so ask pydantic
    # which fields actually arrived. Reading null as "no change" made the
    # clients' clear-the-voice option answer 200 and keep the old voice.
    voice = body.voice_id if "voice_id" in body.model_fields_set else UNCHANGED
    try:
        row = correct_cast_member(
            db, body.source_id, body.series_key, body.name,
            gender=body.gender, voice_id=voice,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    db.commit()
    return {
        "name": row.display_name, "gender": row.gender,
        "voice_id": row.voice_id, "locked": row.locked,
    }


@router.post("/cast/alias", dependencies=OWNER_ONLY)
@limiter.limit(sources_limit)
def merge_cast_alias(
    request: Request,
    response: Response,
    body: AliasMerge,
    db: DbDep,
) -> dict[str, object]:
    """Declare that one name is another character.

    The affordance the storage design exists for: spans hold a LABEL rather
    than a foreign key and resolve at serve time, so this single row corrects
    every chapter ever attributed — including ones bought months ago — without
    re-attributing or rewriting anything.

    404 when the target character is unknown, because an alias pointing at
    nobody resolves to nothing and is harder to notice than an error.
    """
    try:
        row = merge_alias(
            db, body.source_id, body.series_key, body.alias, body.canonical
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    db.commit()
    return {"alias": row.alias_display, "resolves_to": body.canonical}


class BulkChapterRequest(BaseModel):
    """A WINDOW of one novel's chapters (spec 2026-09-05 R5).

    Explicit keys rather than a numeric range, for the same reason the manga
    window uses them: ``chapter_key`` is an opaque connector string, the client
    already holds the ordered list, and neither side should be parsing keys.
    """

    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)
    chapter_keys: list[str] = Field(min_length=1)


@router.post("/chapters")
@limiter.limit(bulk_limit)
def get_novel_chapters_bulk(
    body: BulkChapterRequest,
    request: Request,
    response: Response,  # slowapi injects X-RateLimit-* headers into this
    service: NovelDep,
) -> dict[str, object]:
    """Chapter text for a bounded window of one novel, in one round trip.

    ``{source_id, series_key, max_chapters, requested, ok_count, failed_count,
    items: [{chapter_key, status, chapter, error}]}`` where each ``chapter`` is
    exactly the ``GET /novels/chapter`` payload for that chapter, ``cache``
    block included — the same service method builds both. ``status`` is
    ``"ok"`` or ``"error"``; exactly one of ``chapter`` / ``error`` is non-null.

    This is what makes "download a whole novel" (R5) reasonable: chapter text
    is kilobytes, so 300 separate requests are almost entirely round-trip
    overhead. Over ``max_chapters`` keys is a 413 ``batch_too_large`` naming the
    cap; every success echoes ``max_chapters`` so a download paces itself by the
    server's stride.

    Rate-limited on the ``bulk`` bucket — a window whose chapters all miss the
    cache is that many upstream page scrapes on the sync threadpool.
    """
    return service.get_chapters_bulk(
        body.source_id, body.series_key, body.chapter_keys
    )
