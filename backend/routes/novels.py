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

from typing import Annotated

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

from core.config import get_settings
from core.rate_limit import bulk_limit, limiter, sources_limit
from database.session import get_db
from services.chapter_audio_store import (
    chapter_paths,
    read_chapter_audio,
    rendered_chapters,
)
from services.novel_attribution_service import (
    correct_cast_member,
    merge_alias,
    read_attribution,
    set_narrator_voice,
)
from database.models import NovelChapterCache
from sqlalchemy import select
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
    source: str = Query(..., min_length=1, max_length=64),
    series: str = Query(..., min_length=1, max_length=512),
    chapter: str = Query(..., min_length=1, max_length=512),
) -> dict[str, object]:
    """Whether this chapter has been rendered, and where each sentence sits.

    ``{available, bytes, total_ms, segments: [{i, start_ms, end_ms, p, s, e,
    voice, speaker, speech}]}``.

    The timings are MEASURED, not estimated: each segment was rendered on its
    own, so its duration is the length of the samples that came back. That is
    what a client follows along with.

    Absence is not an error. Almost nothing in the library is rendered, and a
    client asking about every chapter should not be reading error paths for the
    ordinary case.
    """
    found = read_chapter_audio(source, series, chapter)
    return {
        "available": found.available,
        "bytes": found.bytes,
        "total_ms": found.total_ms,
        "segments": list(found.segments),
    }


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
    }


@router.get("/audio/file")
@limiter.limit(sources_limit)
def get_novel_audio_file(
    request: Request,
    response: Response,
    source: str = Query(..., min_length=1, max_length=64),
    series: str = Query(..., min_length=1, max_length=512),
    chapter: str = Query(..., min_length=1, max_length=512),
) -> FileResponse:
    """The rendered Opus, as a file.

    ``FileResponse`` and not a streamed body on purpose: it sets
    ``Accept-Ranges`` and answers a ``Range`` with a 206, which was verified
    against Starlette's source rather than assumed. Without that, every seek in
    a player re-downloads the whole chapter.
    """
    audio, _timing = chapter_paths(source, series, chapter)
    if not audio.is_file():
        raise StarletteHTTPException(status_code=404, detail="Not Found")
    return FileResponse(audio, media_type="audio/ogg")


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


@router.post("/narrator")
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
    voice_id: str | None = Field(default=None, max_length=64)


class AliasMerge(BaseModel):
    """Declare that one name is another character."""

    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)
    alias: str = Field(min_length=1, max_length=128)
    canonical: str = Field(min_length=1, max_length=128)


@router.post("/cast")
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
    try:
        row = correct_cast_member(
            db, body.source_id, body.series_key, body.name,
            gender=body.gender, voice_id=body.voice_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    db.commit()
    return {
        "name": row.display_name, "gender": row.gender,
        "voice_id": row.voice_id, "locked": row.locked,
    }


@router.post("/cast/alias")
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
