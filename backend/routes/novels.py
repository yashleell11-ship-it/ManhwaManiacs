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

from fastapi import APIRouter, Depends, Query, Request, Response
from sqlalchemy.orm import Session
from pydantic import BaseModel, Field
from starlette.exceptions import HTTPException as StarletteHTTPException

from core.config import get_settings
from core.rate_limit import bulk_limit, limiter, sources_limit
from database.session import get_db
from services.novel_attribution_service import read_attribution
from services.novel_service import NovelService, get_novel_service


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
