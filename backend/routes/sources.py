from __future__ import annotations

import hashlib
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request, Response
from fastapi.responses import Response
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.rate_limit import limiter, sources_limit
from database.session import get_db
from connectors.registry import list_installed_connectors
from services.browse_service import BrowseService, get_browse_service
from services.search_tiers import tier_one_source_ids
from services.reader_service import ReaderService, get_reader_service
from services.image_resize import (
    COVER_WIDTHS,
    PAGE_WIDTHS,
    negotiate_cover_format,
    negotiate_image_format,
    resize_page,
    snap_cover_width,
    snap_page_width,
)
from services.source_cache_service import (
    SourceCacheService,
    get_source_cache_service,
    live_cache_info,
)
from services.source_pin_service import (
    SourcePinService,
    get_source_pin_service,
    require_source_pin_service,
)
from utils.api_pagination import set_list_total_header

router = APIRouter(prefix="/sources", tags=["sources"])


BrowseDep = Annotated[BrowseService, Depends(get_browse_service)]
CacheDep = Annotated[SourceCacheService, Depends(get_source_cache_service)]
ReaderDep = Annotated[ReaderService, Depends(get_reader_service)]
PinDep = Annotated[SourcePinService, Depends(get_source_pin_service)]
PinWriteDep = Annotated[SourcePinService, Depends(require_source_pin_service)]
DbDep = Annotated[Session, Depends(get_db)]


def _release_pooled_connection(db: Session) -> None:
    """Hand this request's pooled DB connection back before a slow upstream fetch.

    Authenticating a request resolves the session token through the request's
    Session, which checks a connection out of the engine pool; the Session
    holds it until the next commit/rollback/close, and ``AuthService._touch``
    deliberately does neither for a token used in the last minute. Every route
    below that then spends up to 30 s fetching from a third-party site would
    otherwise pin one of the 20+20 pool slots for that whole time — and the
    page-image proxy runs 20-200 times per chapter read, so a single slow image
    host is enough to exhaust the pool on a 2-vCPU box.

    Only correct where every DB-dependent decision (the 18+ gate, resolved in
    ``get_browse_service``) has already been made: the rollback ends the
    transaction, and any later DB use simply checks a connection out again.
    Nothing uncommitted is lost — ``_touch`` either modified nothing or
    committed already.
    """
    db.rollback()


class SourcePinsUpdate(BaseModel):
    """The complete pinned set, in the order it should be displayed."""

    source_ids: list[str] = Field(default_factory=list)


def _image_proxy_headers() -> dict[str, str]:
    """Response headers for the two byte-proxying routes.

    The service layer already clamps the media type to a bitmap allowlist;
    these headers stop a browser from second-guessing it (nosniff), neuter any
    markup that does get through (CSP sandbox: no script, no same-origin
    access), and keep a top-level navigation from treating the body as a page
    of ours (Content-Disposition).
    """
    return {
        "Cache-Control": "max-age=86400",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "sandbox",
        "Content-Disposition": "inline; filename=image",
    }


# A cover is effectively immutable per URL (the URL embeds the series key, and
# a source swapping a cover is rare), so it gets a long ``public`` max-age:
# the client caches it locally, Cloudflare may cache it at the edge, and both
# stop re-proxying the same bytes through the VPS. ``public`` is load-bearing —
# without it an edge will not cache an authenticated response.
#
# A cover requested WITHOUT ``?w=`` is still never stored server-side: it is
# streamed through and forgotten, as it always was. Only the DERIVED,
# downscaled renderings live on disk, in ``source_cover_cache``, under a hard
# byte budget — see ``database.models.SourceCoverCache`` for why that does not
# breach the no-chapter-images rule. Page images are untouched by all of this.
_COVER_MAX_AGE_SECONDS = 30 * 24 * 3600  # 30 days


def _etag_for(data: bytes) -> str:
    """Strong validator derived from the actual bytes served."""
    return f'"{hashlib.sha256(data).hexdigest()[:32]}"'


def _if_none_match_hits(header: str | None, etag: str) -> bool:
    """RFC 9110 ``If-None-Match``: ``*``, or a comma-separated list where any
    entry (weak-compared, so ``W/`` prefixes are ignored) equals our ETag."""
    if not header:
        return False
    if header.strip() == "*":
        return True
    for candidate in header.split(","):
        candidate = candidate.strip()
        if candidate.startswith("W/"):
            candidate = candidate[2:]
        if candidate == etag:
            return True
    return False


def _conditional_image_response(
    request: Request,
    media_type: str,
    data: bytes,
    headers: dict[str, str],
) -> Response:
    """200 with the bytes, or 304 if the client already holds them.

    The upstream fetch has still happened by the time we are here (no bytes
    are stored server-side to validate against), so the 304 saves egress and
    lets clients/edges revalidate a long-lived cache entry — it does not save
    the origin fetch. Every hardening header stays on both status codes.
    """
    etag = _etag_for(data)
    headers = {**headers, "ETag": etag}
    if _if_none_match_hits(request.headers.get("if-none-match"), etag):
        return Response(status_code=304, headers=headers)
    return Response(content=data, media_type=media_type, headers=headers)


@router.get("")
def list_sources(service: BrowseDep, response: Response) -> list[dict[str, object]]:
    """List installed browsable source connectors."""
    items = service.list_sources()
    set_list_total_header(response, len(items))
    return items


# NOTE: this literal ``/search`` route MUST be declared before the
# ``/{source_id}/...`` routes below so "search" is never captured as a
# ``source_id`` path parameter.
@router.get("/search")
@limiter.limit(sources_limit)
async def federated_search(
    request: Request,
    response: Response,
    service: BrowseDep,
    db: DbDep,
    q: str = Query("", description="Search query"),
    page: int = Query(1, ge=1),
    per_page: int = Query(40, ge=1, le=200),
    tier: int | None = Query(
        None,
        ge=1,
        le=2,
        description=(
            "1 asks only the sources you pin or follow and returns as soon as "
            "they answer; 2 asks everything else. Omit for the old behaviour: "
            "one request to every source."
        ),
    ),
) -> dict[str, object]:
    """Search every browsable source in parallel.

    Rate-limited on the ``sources`` bucket: one request here fans out to *every*
    installed connector at once, so it is the most expensive thing an
    unthrottled caller can ask this box to do.

    Source-native: there is no local catalog to search — the library is the
    per-profile ``followed_series`` set, searched via ``GET /library/search``.
    """
    # Resolved here, where the caller's identity lives, and passed down — the
    # split must be IDENTICAL across the two requests of one search, so both
    # tiers compute it from the same rows rather than each guessing.
    tier_ids: list[str] | None = None
    if tier is not None:
        tier_ids = tier_one_source_ids(
            db,
            user_id=service._user_id,
            profile_id=service._profile_id,
            visible_ids={
                d.source_type
                for d in list_installed_connectors(
                    browsable_only=True, include_mature=service._gate_open()
                )
            },
        )

    return await service.federated_search(
        q.strip(),
        page=page,
        per_page=per_page,
        include_mature=service._gate_open(),
        tier=tier,
        tier_ids=tier_ids,
    )


# NOTE: like ``/search`` above, this literal route MUST stay ahead of the
# ``/{source_id}/...`` routes or FastAPI captures "health" as a source id.
@router.get("/health")
def list_source_health(service: BrowseDep, response: Response) -> list[dict[str, object]]:
    """List sources with their recorded reachability, worst first.

    Same rows and same 18+ gate as ``GET /sources`` -- health is stored
    globally (a site being down is a property of the site) but is only ever
    read back through the caller's own gated source list, so a mature source's
    health never reaches a profile that cannot see the source.

    Nothing is hidden here: a dead source is listed and flagged, because the
    failure this endpoint exists to fix is a source dying silently.
    """
    items = service.list_source_health()
    set_list_total_header(response, len(items))
    return items


# NOTE: like ``/search`` above, both literal ``/pins`` routes MUST stay ahead of
# the ``/{source_id}/...`` routes or FastAPI captures "pins" as a source id.
@router.get("/pins")
def list_source_pins(service: PinDep, response: Response) -> list[dict[str, object]]:
    """Return the caller's pinned sources, ordered."""
    items = service.list_pins()
    set_list_total_header(response, len(items))
    return items


@router.put("/pins")
def replace_source_pins(
    payload: SourcePinsUpdate,
    service: PinWriteDep,
    response: Response,
) -> list[dict[str, object]]:
    """Replace the pinned set with exactly the sources given, in that order."""
    items = service.replace_pins(payload.source_ids)
    set_list_total_header(response, len(items))
    return items


@router.get("/{source_id}/browse-modes")
def list_browse_modes(source_id: str, service: BrowseDep) -> list[dict[str, str]]:
    """Return catalog sort modes supported by a source (popular, latest, etc.)."""
    return service.list_browse_modes(source_id)


@router.get("/{source_id}/genres")
def list_source_genres(source_id: str, service: BrowseDep) -> list[dict[str, str]]:
    """Return genre filters supported by a source."""
    return service.list_genres(source_id)


@router.get("/{source_id}/series")
@limiter.limit(sources_limit)
def list_source_series(
    source_id: str,
    service: BrowseDep,
    cache: CacheDep,
    db: DbDep,
    request: Request,
    response: Response,
    page: int = Query(1, ge=1),
    query: str | None = Query(None),
    sort: str | None = Query(None),
    genre: str | None = Query(None),
    refresh: bool = Query(False, description="Bypass the cache and refetch live"),
) -> dict[str, object]:
    """List or search series from an online source.

    Plain browses (no ``query``) are served through ``source_browse_cache``:
    a repeat visit within the TTL never touches the connector, and a dead
    connector serves the last known page flagged stale instead of a 502. The
    response carries a ``cache`` block — ``{"status": "fresh"|"live"|"stale",
    "stale": bool, "fetched_at": ISO-8601 UTC}`` — so clients can badge stale
    grids. Searches bypass the cache (unbounded key cardinality) and always
    report ``status: "live"``, and so does a ``sort``/``genre`` the connector
    never advertised — those are cache KEYS, so only the source's own closed
    set of facets may mint rows. ``refresh=true`` forces a live refetch.
    """
    normalized_query = query.strip() if query else None
    if normalized_query:
        # Search is a bare upstream fetch with nothing left to read locally;
        # the cached browse below keeps its connection because it writes rows.
        _release_pooled_connection(db)
        listing = service.list_series(
            source_id, page=page, query=normalized_query, sort=sort, genre=genre
        )
        listing["cache"] = live_cache_info()
        return listing
    return cache.get_browse_page(
        source_id, page=page, sort=sort, genre=genre, force=refresh, warm_next=True
    )


# --- key-bearing routes ----------------------------------------------------
#
# CONTRACT: every ``{series_id}`` / ``{chapter_id}`` / ``{page_id}`` below is a
# ``:path`` parameter, because connector keys are opaque strings that contain
# slashes and percent-encoding (see docs/CLAUDE_HANDOFF.md §2). The ASGI server
# percent-decodes before routing, so a ``%2F`` in a key reaches the router as a
# real ``/`` and a plain segment converter simply 404s. ``fully_unquote`` is
# applied uniformly downstream (browse_service / reader_service), so ``:path``
# costs nothing and the mixture used to mean the same key worked on one route
# and 404'd on the next.
#
# ``:path`` is greedy, so ORDER MATTERS: the suffixed routes must be declared
# before the bare ``/{series_id:path}`` detail route or it swallows their
# suffixes. Do not reorder these without re-reading this comment.
#
# A ``@limiter.limit`` route that returns a dict rather than a ``Response`` MUST
# also take ``response: Response`` — slowapi injects its X-RateLimit-* headers
# into that object and raises at request time if it is missing.


_CHAPTERS_SEGMENT = "/chapters/"


def _split_at_first_chapters_segment(series_id: str, chapter_id: str) -> tuple[str, str]:
    """Undo Starlette's greedy split of the reader path's two ``:path`` params.

    Both params are greedy, so when the URL carries more than one
    ``/chapters/`` the FIRST param swallows through the LAST one. Three
    connectors (aurorascans, beehentai, comicland) mint chapter ids as
    ``<series>/chapters/<chapter>``, so every chapter on those sources arrived
    with the series id over-long and the chapter id truncated, and the reader
    answered "Chapter not found" (production log, 2026-09-07).

    Rejoining and re-splitting at the FIRST separator is correct because a
    series key has never contained ``/chapters/`` while a chapter id routinely
    does; keys that merely contain slashes are unaffected, since the rejoined
    string reproduces the original path exactly.
    """
    joined = f"{series_id}{_CHAPTERS_SEGMENT}{chapter_id}"
    head, _, tail = joined.partition(_CHAPTERS_SEGMENT)
    return head, tail


@router.get("/{source_id}/series/{series_id:path}/chapters/{chapter_id:path}/reader")
@limiter.limit(sources_limit)
def get_source_reader_chapter(
    source_id: str,
    series_id: str,
    chapter_id: str,
    service: ReaderDep,
    request: Request,
    response: Response,
) -> dict[str, object]:
    """Return the online reader payload for a chapter, straight from the source."""
    series_id, chapter_id = _split_at_first_chapters_segment(series_id, chapter_id)
    return service.resolve_source_chapter(source_id, series_id, chapter_id)


@router.get("/{source_id}/series/{series_id:path}/chapters")
@limiter.limit(sources_limit)
def get_source_chapters(
    source_id: str,
    series_id: str,
    service: BrowseDep,
    db: DbDep,
    request: Request,
    response: Response,
) -> list[dict[str, object]]:
    """Return chapters for a series from an online source.

    Rate-limited: triggers up to four upstream fetches and runs on the sync
    threadpool, so with no ceiling a caller looping cache-busted keys against
    a dead upstream could pin every worker in retry cycles (audit finding 9).
    """
    _release_pooled_connection(db)
    items = service.get_chapters(source_id, series_id)
    set_list_total_header(response, len(items))
    return items


@router.get("/{source_id}/series/{series_id:path}/cover")
@limiter.limit(sources_limit)
def get_source_series_cover(
    source_id: str,
    series_id: str,
    service: BrowseDep,
    cache: CacheDep,
    db: DbDep,
    request: Request,
    w: int | None = Query(
        None,
        ge=1,
        le=10000,
        description=(
            "Render the cover at this width in device pixels. Snapped onto "
            f"{list(COVER_WIDTHS)}; the width actually served comes back in "
            "X-Cover-Width. Omit for the original, full-resolution image."
        ),
    ),
) -> Response:
    """Proxy a series cover image from an online source.

    Rate-limited: this and the page-image proxy are the two routes that stream
    third-party bytes through the box, so on a metered VPS they are the ones
    that most need a ceiling.

    Covers get the long-lived cacheable treatment (see _COVER_MAX_AGE_SECONDS)
    plus an ETag with 304 handling, so browsing the same grid twice costs the
    box nothing after the first paint.

    ``?w=`` is the fix for the biggest measured waste in the product: covers
    were served at source resolution into thumbnail boxes (1.64 MB average,
    6.27 MB max, ~39 MB for one 24-cover grid at a 375 px viewport). With a
    width the cover is downscaled and re-encoded — WebP when the client's
    ``Accept`` says so, JPEG otherwise — and cached in ``source_cover_cache``.
    Without one, nothing changes at all: the original streams straight through
    and is never written down.

    ``w`` SNAPS onto ``image_resize.COVER_WIDTHS`` rather than being honoured
    verbatim. A free-form integer would be a cache explosion and a cheap DoS
    (a thousand distinct widths is a thousand decode/encode cycles on 2 vCPU
    from one caller), and snapping beats rejecting because a client with a
    hard-coded odd number still gets a right-sized cover instead of a 422.
    ``X-Cover-Width`` reports what was actually rendered, and is absent when
    the original was served (unresizable bytes, a re-encode that would not
    have been smaller, or the MM_COVER_RESIZE_ENABLED kill switch). ``w`` is
    still validated (1..10000) before it is snapped, so a nonsense value is a
    422 rather than something to reason about further down.

    ``Vary: Accept`` is mandatory whenever a width is in play: the response
    body depends on the Accept header, and without it Cloudflare would happily
    hand a WebP to a client that asked for JPEG.
    """
    headers = {
        **_image_proxy_headers(),
        "Cache-Control": f"public, max-age={_COVER_MAX_AGE_SECONDS}",
    }
    if w is None:
        # The ``?w=`` path releases the connection inside the cache service
        # instead (it still needs the DB to read/write the derived rendering).
        _release_pooled_connection(db)
        media_type, data = service.resolve_series_cover(source_id, series_id)
        return _conditional_image_response(request, media_type, data, headers)

    media_type, data, served_width = cache.get_series_cover(
        source_id,
        series_id,
        width=snap_cover_width(w),
        fmt=negotiate_cover_format(request.headers.get("accept")),
    )
    headers["Vary"] = "Accept"
    if served_width is not None:
        headers["X-Cover-Width"] = str(served_width)
    return _conditional_image_response(request, media_type, data, headers)


@router.get("/{source_id}/series/{series_id:path}")
@limiter.limit(sources_limit)
def get_source_series(
    source_id: str,
    series_id: str,
    service: BrowseDep,
    db: DbDep,
    request: Request,
    response: Response,
) -> dict[str, object]:
    """Return series metadata from an online source. Rate-limited — upstream
    fetch on the sync threadpool (audit finding 9; see the chapters route).

    Declared last of the ``/series/...`` routes — see the CONTRACT note above.
    """
    _release_pooled_connection(db)
    return service.get_series(source_id, series_id)


@router.get("/{source_id}/chapters/{chapter_id:path}/pages")
@limiter.limit(sources_limit)
def get_source_chapter_pages(
    source_id: str,
    chapter_id: str,
    service: BrowseDep,
    request: Request,
    response: Response,
) -> list[dict[str, object]]:
    """Return pages for a chapter from an online source. Rate-limited —
    upstream fetch on the sync threadpool (audit finding 9)."""
    return service.get_chapter_pages(source_id, chapter_id)


@router.get("/{source_id}/pages/{page_id:path}/image")
@limiter.limit(sources_limit)
def get_source_page_image(
    source_id: str,
    page_id: str,
    service: BrowseDep,
    db: DbDep,
    request: Request,
    w: int | None = Query(
        None,
        ge=1,
        le=10000,
        description=(
            "Render the page at this width in device pixels. Snapped onto "
            f"{list(PAGE_WIDTHS)}; the width actually served comes back in "
            "X-Page-Width, and that header is ABSENT whenever the original "
            "was served. Omit for the original, full-resolution image."
        ),
    ),
) -> Response:
    """Proxy a page image from an online source. Rate-limited — see the cover
    proxy above; this is the hot one, several dozen requests per chapter read.

    Gets the same ETag/304 revalidation as covers (saves egress on re-reads)
    but keeps the shorter, non-``public`` Cache-Control: page bytes are the
    actual chapter content, so they stay out of shared edge caches.

    ``?w=`` is the same contract as the cover proxy — snapped ladder, WebP only
    when ``Accept`` says so, served width echoed back — so a client learns one
    rule for both. Everything past that is deliberately different, and
    ``image_resize``'s page section has the measurements behind each one:

      * NOTHING IS STORED. Chapter images never touch disk, so every request
        pays the full render where a cover pays once and is then cached. That
        is why the render is refused above a source-megapixel ceiling, and why
        a long webtoon strip is passed straight through.
      * A REFUSAL IS THE COMMON CASE and costs under a millisecond — it is
        decided from the image header, before a row is decoded. Webtoon
        sources publish at 720-800 px, which is already at or below what a
        DPR-3 phone asks for, so on a phone this parameter changes nothing for
        the strips. It is not the fix for reader jank; that is client-side.
      * The resize runs on bytes the fetch has ALREADY validated — the SSRF
        allowlist, the no-redirect rule and ``image_proxy_max_bytes`` all live
        in ``BrowseService._fetch_url`` and are untouched by this.

    ``Vary: Accept`` rides along whenever a width is in play, even when the
    original was served: the response could have depended on Accept, and a
    shared cache that does not know that will hand a WebP to a client that
    asked for JPEG.
    """
    _release_pooled_connection(db)
    media_type, data = service.resolve_page_image(source_id, page_id)
    headers = _image_proxy_headers()
    if w is None:
        return _conditional_image_response(request, media_type, data, headers)

    headers["Vary"] = "Accept"
    width = snap_page_width(w)
    if width is not None:
        rendered = resize_page(
            data,
            width=width,
            fmt=negotiate_image_format(request.headers.get("accept")),
        )
        if rendered is not None:
            media_type, data = rendered
            # Exact, not aspirational: resize_page refuses outright unless the
            # source is meaningfully wider, so a render really is ``width`` px.
            headers["X-Page-Width"] = str(width)
    return _conditional_image_response(request, media_type, data, headers)
