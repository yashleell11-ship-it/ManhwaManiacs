"""Source-native reader endpoints (spec §4.1).

Every read here answers the caller's own 18+ gate, per-(user, profile). The two
that name a single source — the manifests and ``GET /progress/series`` — run
``BrowseService.ensure_visible`` first and 404 exactly as browse does; the two
that list across sources — ``GET /history`` and ``GET /bookmarks`` — fold the
source's maturity into the per-row rating and omit what is gated, because a
raise would let one deregistered source in a reader's history take the whole
list down. Denial is always absence, never 403.

The writes are deliberately ungated: a shut gate is a request not to be *shown*
adult series, not a request to forget where the account got to.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, ValidationError

from core.errors import AppError
from core.profile_context import require_profile_context
from core.rate_limit import bulk_limit, limiter
from core.time_utils import clamp_client_clock
from services.bookmark_service import (
    OP_UPSERT,
    BookmarkOp,
    BookmarkService,
    get_bookmark_service,
)
from services.progress_service import (
    RETRY_AFTER_SECONDS,
    ProgressInput,
    ProgressService,
    get_progress_service,
)
from services.reader_service import ReaderService, get_reader_service
from utils.api_pagination import set_list_total_header

router = APIRouter(prefix="/reader", tags=["reader"])

ReaderDep = Annotated[ReaderService, Depends(get_reader_service)]
ProgressDep = Annotated[ProgressService, Depends(get_progress_service)]
BookmarkDep = Annotated[BookmarkService, Depends(get_bookmark_service)]


class ProgressRequest(BaseModel):
    """One progress push on the wire.

    ``last_read_at`` is the instant the DEVICE recorded this position, and it
    is the whole reason the merge can tell an offline replay from a fresh read.
    Without it every push is stamped at flush time, so a week-old push made on
    a plane arrives claiming to be the newest read of the account: it wins the
    ``merge_progress`` tie-break against a scroll offset set on the web an hour
    ago, and it takes rank 1 of Continue Reading away from the chapter actually
    read last. Optional, because the shipped clients do not send it yet; any
    offset is accepted and normalized to UTC, and a *future* value is capped
    (``clamp_client_clock``) so a wrong device clock cannot pin itself to the
    head of the strip forever.
    """

    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)
    chapter_key: str = Field(min_length=1, max_length=512)
    chapter_number: float | None = None
    last_page: int = Field(default=1, ge=1)
    page_count: int = Field(default=0, ge=0)
    scroll_offset_px: int = Field(default=0, ge=0)
    is_completed: bool = False
    last_read_at: datetime | None = None
    #: Wall-clock time spent in the chapter SINCE THIS CLIENT'S LAST PUSH, not
    #: a running total: the server accumulates (``merge_progress``), so a
    #: cumulative figure would be re-added on every push and on every replay.
    time_spent_seconds: int = Field(default=0, ge=0)

    def to_input(self) -> ProgressInput:
        return ProgressInput(
            source_id=self.source_id,
            series_key=self.series_key,
            chapter_key=self.chapter_key,
            chapter_number=self.chapter_number,
            last_page=self.last_page,
            page_count=self.page_count,
            scroll_offset_px=self.scroll_offset_px,
            is_completed=self.is_completed,
            last_read_at=clamp_client_clock(self.last_read_at),
            time_spent_seconds=self.time_spent_seconds,
        )


class BookmarkBody(BaseModel):
    """One bookmark on the wire, for both the single POST and the batch.

    The position is the generic anchor triple + ``media_type`` discriminator
    described in ``database.models.Bookmark``: ``anchor_index`` counts pages
    for manga and paragraphs for novels (1-based in both), ``anchor_fraction``
    is 0.0-1.0 *within* that unit, ``anchor_total`` is the unit count the
    client saw (0 = unknown).

    ``page`` is a deprecated alias for ``anchor_index``, kept because the
    shipped web reader still posts it: an old page-only create keeps working
    and lands at offset 0.0 of that page, exactly like the rows the migration
    carried forward.
    """

    client_id: str | None = Field(default=None, max_length=64)
    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)
    chapter_key: str = Field(min_length=1, max_length=512)
    chapter_number: float | None = None
    media_type: str = Field(default="manga", max_length=16)
    anchor_index: int = Field(default=1, ge=1)
    anchor_fraction: float = Field(default=0.0, ge=0.0, le=1.0)
    anchor_total: int = Field(default=0, ge=0)
    note: str | None = None
    #: Deprecated: pre-2026-09-05 clients. Used only when anchor_index is unset.
    page: int | None = Field(default=None, ge=1)

    def resolved_index(self) -> int:
        return self.anchor_index if self.anchor_index != 1 else (self.page or 1)


class BookmarkOpRequest(BookmarkBody):
    """One item of an offline flush: a ``BookmarkBody`` plus op + clock.

    ``client_id`` is REQUIRED here (unlike the single POST, which mints one):
    a batch item with no client id has no sync identity, so a retry of the
    same flush would create a duplicate every time.

    The identity fields relax to optional for a delete — a device replaying a
    delete may no longer hold the bookmark's body, and the server re-identifies
    by ``client_id`` alone.
    """

    op: str = Field(default=OP_UPSERT, max_length=16)
    client_id: str = Field(min_length=1, max_length=64)
    source_id: str = Field(default="", max_length=64)
    series_key: str = Field(default="", max_length=512)
    chapter_key: str = Field(default="", max_length=512)
    #: The client's own clock for this change; absent means "server now".
    #: Any offset is accepted and normalized to UTC.
    updated_at: datetime | None = None

    def to_op(self) -> BookmarkOp:
        return BookmarkOp(
            op=self.op,
            client_id=self.client_id,
            source_id=self.source_id,
            series_key=self.series_key,
            chapter_key=self.chapter_key,
            chapter_number=self.chapter_number,
            media_type=self.media_type,
            anchor_index=self.resolved_index(),
            anchor_fraction=self.anchor_fraction,
            anchor_total=self.anchor_total,
            note=self.note,
            updated_at=self.updated_at,
        )


@router.get("/chapter/manifest")
def chapter_manifest(
    service: ReaderDep,
    source: str = Query(..., min_length=1),
    series: str = Query(..., min_length=1),
    chapter: str = Query(..., min_length=1),
) -> dict[str, object]:
    """The download plan for a chapter: ordered page list + prev/next keys."""
    return service.manifest(source, series, chapter)


class BulkManifestRequest(BaseModel):
    """A WINDOW of one series' chapters (spec 2026-09-05 R2/R4).

    The client names the chapters explicitly rather than asking for a numeric
    range: ``chapter_key`` is an opaque connector string and the client already
    holds the ordered list from the series page, so an index range would mean
    both sides parsing keys or agreeing on an ordering that upstream can change
    under them. A window is therefore just "these keys, in this order", and the
    server answers in the same order.
    """

    source_id: str = Field(min_length=1, max_length=64)
    series_key: str = Field(min_length=1, max_length=512)
    chapter_keys: list[str] = Field(min_length=1)


@router.post("/chapters/manifest")
@limiter.limit(bulk_limit)
def chapter_manifest_batch(
    body: BulkManifestRequest,
    service: ReaderDep,
    request: Request,
    response: Response,  # slowapi injects X-RateLimit-* headers into this
) -> dict[str, object]:
    """Download plans for a bounded window of chapters, in one round trip.

    ``{source_id, series_key, max_chapters, requested, ok_count, failed_count,
    items: [{chapter_key, status, manifest, error}]}`` where each ``manifest``
    is byte-identical to what ``GET /reader/chapter/manifest`` serves for that
    chapter (same code path builds both). ``status`` is ``"ok"`` or
    ``"error"``; exactly one of ``manifest`` / ``error`` is non-null per item.

    POST, not GET, because the body is a list of opaque keys that routinely
    contain slashes and percent-encoding — twenty of them do not belong in a
    query string. It is still a read: nothing here mutates.

    Over ``max_chapters`` keys is a 413 ``batch_too_large`` (details carry
    ``max_chapters``), matching ``POST /reader/progress/batch``. Every success
    echoes ``max_chapters`` so a client pages by the server's stride.

    Rate-limited on the ``bulk`` bucket, not ``sources``: one call is worth up
    to ``max_chapters`` upstream scrapes.
    """
    return service.manifest_batch(
        body.source_id, body.series_key, body.chapter_keys
    )


#: The service's code for "SQLite's single writer is still busy" (503).
DB_BUSY_CODE = "db_busy"


def _busy(exc: AppError) -> JSONResponse:
    """The 503 envelope, plus the header ``AppError`` cannot carry.

    ``core.errors`` renders every ``AppError`` through one ``JSONResponse``
    with no way to attach headers, and a 503 with no ``Retry-After`` tells a
    retrying client nothing — these two routes are the reader's steady drip of
    keep-alive pushes, which is exactly the traffic that has to back OFF a
    saturated writer rather than spin on it. Built here, in the only routes
    that raise it, instead of widening the shared handler for one code; the
    body is byte-identical to what that handler would have produced.
    """
    return JSONResponse(
        status_code=exc.status_code,
        content={"code": exc.code, "message": exc.message, "details": exc.details},
        headers={"Retry-After": str(RETRY_AFTER_SECONDS)},
    )


@router.post("/progress", dependencies=[Depends(require_profile_context)])
def save_progress(body: ProgressRequest, service: ProgressDep) -> dict[str, object]:
    """Save reading progress. Applies the furthest-wins merge (never rewinds)."""
    try:
        return service.save_one(body.to_input())
    except AppError as exc:
        if exc.code != DB_BUSY_CODE:
            raise
        return _busy(exc)


# Offline-sync batches are bounded: an unbounded array was parsed fully into
# memory and then hammered the single-writer SQLite (audit finding 12). A
# client with more than this simply sends several batches.
PROGRESS_BATCH_MAX_ITEMS = 200


def _item_errors(exc: ValidationError) -> list[dict[str, str]]:
    """Pydantic's report, flattened to something JSON can hold.

    ``ValidationError.errors()`` carries ``ctx`` objects and the offending
    input verbatim; the input is the client's own row (no need to echo it) and
    ``ctx`` is not always serializable, so only the field path and the message
    cross the wire.
    """
    return [
        {"field": ".".join(str(part) for part in err["loc"]), "message": err["msg"]}
        for err in exc.errors()
    ]


@router.post(
    "/progress/batch",
    dependencies=[Depends(require_profile_context)],
    # The handler validates item by item (see below), so the signature can no
    # longer carry the schema. Declare it here instead, or /docs would show an
    # array of anything for the endpoint every offline client posts to.
    openapi_extra={
        "requestBody": {
            "content": {
                "application/json": {
                    "schema": {
                        "type": "array",
                        "items": {
                            "$ref": "#/components/schemas/ProgressRequest"
                        },
                    }
                }
            }
        }
    },
)
def save_progress_batch(body: list[Any], service: ProgressDep) -> dict[str, object]:
    """Offline-sync catch-up: an array of progress pushes, merged in one
    transaction. Capped at ``PROGRESS_BATCH_MAX_ITEMS`` items.

    Answers ``{saved, advanced, items, rejected}``. ``items`` holds one merged
    result per ACCEPTED push, in request order; ``rejected`` holds
    ``{index, errors}`` for each push that could not be parsed, where ``index``
    is its position in the array the client sent.

    Per-item validation, because ``body: list[ProgressRequest]`` made one
    unparseable row fatal to the whole flush. An outbox is drained oldest-first
    and cleared only on a 2xx, so a single such row — a ``last_page`` of 0 from
    an older build, an identifier a migration left empty — turned every flush
    into the same 422 for ever, and nothing queued behind it was ever saved.
    The bookmark batch already states the rule this now follows: "a flush that
    400s as a whole leaves the device unable to make progress at all."

    An unknown field is not such a row: ``ProgressRequest`` ignores extras, so
    a client may add one without waiting for the server.

    The batch cap stays fatal (413): that one the client can obey by sending
    fewer items, and it is about the write lock rather than the payload.
    """
    if len(body) > PROGRESS_BATCH_MAX_ITEMS:
        raise AppError(
            "Too many progress items in one batch.",
            code="batch_too_large",
            status_code=413,
            details={
                "max_items": PROGRESS_BATCH_MAX_ITEMS,
                "received": len(body),
            },
        )
    payloads: list[ProgressInput] = []
    rejected: list[dict[str, object]] = []
    for index, item in enumerate(body):
        try:
            payloads.append(ProgressRequest.model_validate(item).to_input())
        except ValidationError as exc:
            rejected.append({"index": index, "errors": _item_errors(exc)})
    try:
        result = service.save_batch(payloads)
    except AppError as exc:
        if exc.code != DB_BUSY_CODE:
            raise
        return _busy(exc)
    return {**result, "rejected": rejected}


@router.get("/progress/series")
def get_series_progress(
    service: ProgressDep,
    source: str = Query(..., min_length=1),
    series: str = Query(..., min_length=1),
) -> list[dict[str, object]]:
    """Every stored chapter position for one series, for the active profile.

    404 ``source_not_found`` for a source this profile's 18+ gate hides — the
    same answer ``GET /reader/chapter/manifest`` gives for it. A series that is
    18+ on a general source comes back as the empty list, which is already this
    endpoint's answer for a series the profile has never opened.
    """
    return service.get_series_progress(source, series)


@router.get("/history")
def reading_history(
    service: ProgressDep,
    response: Response,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    collapse: str = Query("none", pattern="^(none|series)$"),
) -> list[dict[str, object]]:
    """The active profile's reading history, newest first.

    Gated rows are removed inside the query, so ``limit``/``offset`` page over
    what this profile can actually see rather than over the unfiltered table.

    ``collapse=series`` answers one row per BOOK — the furthest-read chapter
    in each — which is what a "what have I been reading" screen wants. Without
    it, forty chapters of one book are forty rows and the book before it is on
    page two. Opt-in rather than the default so the raw position list stays
    available to anything that wants positions rather than books.
    """
    items = service.reading_history(limit=limit, offset=offset, collapse=collapse)
    set_list_total_header(response, len(items))
    return items


# Same cap and the same 413 shape as ``/reader/progress/batch``: an unbounded
# array is parsed fully into memory and then hammers the single-writer SQLite.
BOOKMARK_BATCH_MAX_ITEMS = 200


@router.post("/bookmark", dependencies=[Depends(require_profile_context)])
def create_bookmark(body: BookmarkBody, service: BookmarkDep) -> dict[str, object]:
    """Bookmark the current position, in one action (design §5).

    Returns the stored bookmark, including the server-minted ``client_id``
    when the client did not supply one — a client that wants to delete this
    bookmark through the offline batch later must keep that id.

    409 ``bookmark_deleted`` if the ``client_id`` is already tombstoned: this
    endpoint speaks for one deliberate user action, so silently doing nothing
    would show a bookmark that then vanishes on the next refresh.
    """
    return service.add_bookmark(
        client_id=body.client_id,
        source_id=body.source_id,
        series_key=body.series_key,
        chapter_key=body.chapter_key,
        chapter_number=body.chapter_number,
        media_type=body.media_type,
        anchor_index=body.resolved_index(),
        anchor_fraction=body.anchor_fraction,
        anchor_total=body.anchor_total,
        note=body.note,
    )


@router.post("/bookmarks/batch", dependencies=[Depends(require_profile_context)])
def sync_bookmarks_batch(
    body: list[BookmarkOpRequest], service: BookmarkDep
) -> dict[str, object]:
    """Offline-sync catch-up for bookmarks: creates, edits and deletes.

    Modelled on ``POST /reader/progress/batch`` (one transaction, one commit,
    the same 413 over ``BOOKMARK_BATCH_MAX_ITEMS``) and merged by the OPPOSITE
    rules — bookmarks are user-created objects, not a furthest-wins scalar.
    See ``services.bookmark_service.decide``; in short, a tombstone is
    terminal, so a stale device replaying its create outbox can never
    resurrect a bookmark deleted elsewhere.

    Per item: ``{client_id, op, status, bookmark}`` where ``status`` is
    ``created`` / ``updated`` / ``tombstoned`` / ``already_deleted`` /
    ``stale`` / ``rejected_deleted``. A refused item is reported, never fatal:
    a flush that 400s as a whole leaves the device unable to make progress at
    all.
    """
    if len(body) > BOOKMARK_BATCH_MAX_ITEMS:
        raise AppError(
            "Too many bookmark items in one batch.",
            code="batch_too_large",
            status_code=413,
            details={
                "max_items": BOOKMARK_BATCH_MAX_ITEMS,
                "received": len(body),
            },
        )
    return service.apply_batch([item.to_op() for item in body])


@router.get("/bookmarks")
def list_bookmarks(
    service: BookmarkDep,
    response: Response,
    source: str | None = None,
    series: str | None = None,
    since: datetime | None = Query(
        None,
        description=(
            "Delta pull: only bookmarks changed strictly after this instant, "
            "OLDEST first so a client can page forward on the last updated_at."
        ),
    ),
    include_deleted: bool = Query(
        False, description="Include tombstones, so a device learns about deletes."
    ),
    limit: int = Query(200, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> list[dict[str, object]]:
    """The Bookmarks screen, and the pull half of sync.

    Each item carries everything the screen needs without a second round trip:
    ``series_title``, ``chapter_number``, ``position_fraction`` (0.0-1.0 through
    the chapter, or null when the client never recorded a unit count) and, for
    novels, ``snippet`` — the cached sanitized text at that exact position.
    """
    items = service.list_bookmarks(
        source_id=source,
        series_key=series,
        since=since,
        include_deleted=include_deleted,
        limit=limit,
        offset=offset,
    )
    set_list_total_header(response, len(items))
    return items


@router.delete(
    "/bookmarks/{bookmark_id}",
    status_code=204,
    dependencies=[Depends(require_profile_context)],
)
def delete_bookmark(bookmark_id: int, service: BookmarkDep) -> None:
    """Tombstone one bookmark by row id. The row is never removed."""
    service.delete_bookmark(bookmark_id)
