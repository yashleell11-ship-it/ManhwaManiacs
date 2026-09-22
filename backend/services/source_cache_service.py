"""Read-through TTL cache over connector metadata (spec §3.10, §5.2).

``source_series_cache`` lets the library grid, continue-reading strip, and
notifications render titles/covers/chapter counts without hitting a connector
on every request. ``source_browse_cache`` does the same for whole browse
*pages*, so opening a source renders the grid without a live scrape.
``source_cover_cache`` holds DOWNSCALED cover bytes for ``GET .../cover?w=``
so a 2-vCPU box renders each (series, width, format) once. All three are
*purely* caches: any row may be deleted at any time and is repopulated on the
next read.

Semantics (all three tables):
  * fresh row (``fetched_at`` within its TTL)   → serve it
  * missing / stale                             → refetch, upsert, serve
  * connector failure with any row present      → serve stale (flagged)
  * connector failure with nothing cached       → raise

Rows are GLOBAL — a page one caller fetched serves every caller — but the
18+ gate is applied per caller on every read, before any row is touched
(``BrowseService.ensure_visible``), so a mature source's cached data can
never reach a profile whose gate is closed. One rule, enforced the same way
at all three read entry points: ``get_browse_page``, ``get_series_meta``
(and ``get_chapter_list``, which is a projection of it) and
``get_series_cover``.
"""

from __future__ import annotations

import json
import logging
import threading
from collections import OrderedDict
from dataclasses import dataclass
from datetime import timedelta
from typing import Annotated, Any

from fastapi import Depends
from sqlalchemy import delete, func, select, tuple_
from sqlalchemy.orm import Session

from connectors.base import SourceConnector
from connectors.ids import fully_unquote
from core.config import get_settings
from core.connector_directory import known_source_ids
from core.content_rating import (
    TRACKER_RATING_MATURE,
    hidden_by_gate,
    rating_from_genres,
    resolve_series_rating,
    serialized_series_rating,
)
from core.errors import AppError
from core.time_utils import utcnow
from database.models import (
    NovelChapterCache,
    SourceBrowseCache,
    SourceCoverCache,
    SourceSeriesCache,
)
from database.session import get_db
from services.browse_service import BrowseService, get_browse_service
from services.image_resize import COVER_FORMATS, resize_cover

logger = logging.getLogger("manhwamaniacs.source_cache")

#: ``cache.status`` values in browse responses. The client contract:
#:   * ``fresh`` — served from cache within TTL; no connector was contacted.
#:   * ``live``  — the connector was fetched during this request.
#:   * ``stale`` — the connector FAILED; an expired (or force-refreshed) cached
#:     page was served instead. ``cache.stale`` is true only here, and
#:     ``cache.fetched_at`` says how old the data is.
CACHE_FRESH = "fresh"
CACHE_LIVE = "live"
CACHE_STALE = "stale"


def live_cache_info() -> dict[str, Any]:
    """The ``cache`` block for a response that just came off the connector."""
    return {"status": CACHE_LIVE, "stale": False, "fetched_at": utcnow().isoformat()}


def _loads(value: str | None) -> Any:
    if not value:
        return None
    try:
        return json.loads(value)
    except (ValueError, TypeError):
        return None


# --- chapter-list parse memo ----------------------------------------------
#
# ``source_series_cache.chapters`` is a JSON array, and every read of a series
# — the reader manifest, a novel chapter's prev/next, the series screen —
# parses the whole thing. That is fine for a 40-chapter manhwa and expensive
# for the long tail: measured on the VPS, novelarchive's "Shadow Slave" is
# 3,174 chapters / 314 KB, and ``json.loads`` alone was 9.4 ms of the 9.5 ms a
# CACHE HIT on /novels/chapter took. novelfull carries 3,956; baozimh 3,874.
#
# So the parse is memoized process-wide, keyed by the row's identity AND its
# ``fetched_at``. That key is what keeps this from changing any answer:
# ``_upsert`` bumps ``fetched_at`` whenever a chapter list is written, so a
# refreshed list is a different key and the stale parse can never be served.
# A row deleted outright simply misses.
#
# Bounded by total chapters rather than entries, because entries differ in
# size by two orders of magnitude and a per-entry cap would either waste the
# budget on 40-chapter series or blow it on 4,000-chapter ones.
_CHAPTER_MEMO_MAX_CHAPTERS = 20_000
_chapter_memo: "OrderedDict[tuple[str, str, str], list[Any]]" = OrderedDict()
_chapter_memo_chapters = 0
_chapter_memo_lock = threading.Lock()


def _memoized_chapters(row: SourceSeriesCache) -> list[Any]:
    """``row.chapters`` parsed, reusing the last parse of this exact row.

    Returns a shallow copy of the list: callers only read it today, but a
    shared list that someone later sorts in place would corrupt every
    subsequent request, and copying 3,000 pointers costs ~20 us against the
    9.4 ms it saves.
    """
    global _chapter_memo_chapters
    raw = row.chapters
    if not raw:
        return []
    fetched = row.fetched_at.isoformat() if row.fetched_at else ""
    # Identity + write time + byte length. ``fetched_at`` alone would already
    # be enough (it is bumped by every chapter-list write); the length is a
    # free second opinion, so two different lists written inside the same
    # microsecond cannot share a parse.
    key = (row.source_id, row.series_key, f"{fetched}:{len(raw)}")
    with _chapter_memo_lock:
        hit = _chapter_memo.get(key)
        if hit is not None:
            _chapter_memo.move_to_end(key)
            return list(hit)
    parsed = _loads(raw) or []
    if not isinstance(parsed, list):
        return []
    with _chapter_memo_lock:
        if key not in _chapter_memo:
            _chapter_memo[key] = parsed
            _chapter_memo_chapters += len(parsed)
        _chapter_memo.move_to_end(key)
        while _chapter_memo_chapters > _CHAPTER_MEMO_MAX_CHAPTERS and len(
            _chapter_memo
        ) > 1:
            _evicted_key, evicted = _chapter_memo.popitem(last=False)
            _chapter_memo_chapters -= len(evicted)
    return list(parsed)


def reset_chapter_memo() -> None:
    """Drop the parse memo. For tests; production never needs it."""
    global _chapter_memo_chapters
    with _chapter_memo_lock:
        _chapter_memo.clear()
        _chapter_memo_chapters = 0


# --- rendered-cover cache tuning -------------------------------------------
#
# ``last_used_at`` drives LRU eviction, but a cover grid touches 24 rows per
# screen and bumping every one of them on every paint would turn a read-only
# request into 24 writes against SQLite's single writer. Hourly resolution is
# far finer than an eviction sweep needs, so a row whose stamp is younger than
# this is left alone.
_COVER_LRU_BUMP_MINUTES = 60
# How many rows one eviction pass considers at a time. Deletes are issued as
# Core statements against the primary key rather than by loading ORM objects,
# so an eviction never pulls the blobs it is about to throw away into memory.
_COVER_EVICT_BATCH = 256

# The ``source_cover_cache.resize_failure`` vocabulary. One value, because one
# value is all ``resize_cover`` can tell us: it answers bytes-or-None and
# folds "already small enough", "animated", "not an image", "no Pillow" into
# that single None. The column exists so a future policy change can invalidate
# one class of negative entry without flushing the table, which needs
# ``image_resize`` to report a reason first; until it does, adding names here
# would only be guessing at the row's own history.
_RESIZE_FAILURE_NO_GAIN = "no_downscale"

#: Error codes the 18+ gate itself raises. The degrade-to-stale handlers below
#: must re-raise these rather than treat them as a connector outage: a gate
#: refusing a series is an ANSWER, and answering it with the cached row is the
#: exact disclosure the gate exists to prevent.
_GATE_ERROR_CODES = frozenset({"source_not_found", "series_not_found"})


def _normalize_sort(sort: str | None) -> str:
    """Cache-key form of the ``sort`` facet; mirrors ``list_series``."""
    cleaned = (sort or "").strip()
    return "" if cleaned == "default" else cleaned


def _normalize_genre(genre: str | None) -> str:
    return (genre or "").strip()


# --- background next-page warm --------------------------------------------
#
# After serving a browse page (fresh or live, never stale), the next page is
# fetched in the background so paging forward is instant. Strictly one page
# ahead, deduplicated, and gated on ``settings.browse_prefetch_enabled`` —
# never a fan-out, and at most one extra connector request per page a human
# actually viewed. The three module hooks below exist so tests can run the
# warm inline against their own session/service.

_warm_inflight: set[tuple[str, str, str, int]] = set()
_warm_lock = threading.Lock()


def _spawn_warm(work) -> None:
    threading.Thread(target=work, name="browse-warm", daemon=True).start()


def _open_warm_session() -> Session:
    from database.session import SessionLocal

    return SessionLocal()


def _build_warm_browse(db: Session, mature_enabled: bool) -> BrowseService:
    return BrowseService(mature_enabled=mature_enabled, db=db)


def _evict_cover_bytes_to_budget(db: Session) -> int:
    """Delete least-recently-used rows until the table fits its byte budget.

    A byte budget rather than the row cap the JSON caches use: these rows are
    encoded images, they differ in size by an order of magnitude, and the thing
    that actually has to be bounded on a 20 GB VPS is bytes.
    ``settings.cover_cache_max_bytes`` is therefore a HARD ceiling on what this
    feature can ever occupy. Returns how many rows went; the caller commits.

    The ``SUM`` runs on every store, not only when the budget is blown:
    measured on the VPS it is 22 ms over 10,000 rows (13 ms at the ~6,000 the
    default budget actually holds), against the ~130 ms of CPU the render that
    triggered it just spent. It stays cheap because ``byte_size`` is declared
    BEFORE ``data`` in the table, so the scan reads each record's first page
    instead of walking blob overflow pages.
    """
    cap = get_settings().cover_cache_max_bytes
    if cap <= 0:
        return 0
    # autoflush is off session-wide; flush so the row just added counts.
    db.flush()
    total = db.execute(
        select(func.coalesce(func.sum(SourceCoverCache.byte_size), 0))
    ).scalar_one()
    if total <= cap:
        return 0
    evicted = 0
    while total > cap:
        batch = db.execute(
            select(
                SourceCoverCache.source_id,
                SourceCoverCache.series_key,
                SourceCoverCache.width,
                SourceCoverCache.fmt,
                SourceCoverCache.byte_size,
            )
            .order_by(SourceCoverCache.last_used_at.asc())
            .limit(_COVER_EVICT_BATCH)
        ).all()
        if not batch:
            break
        for victim in batch:
            if total <= cap:
                break
            db.execute(
                delete(SourceCoverCache).where(
                    SourceCoverCache.source_id == victim.source_id,
                    SourceCoverCache.series_key == victim.series_key,
                    SourceCoverCache.width == victim.width,
                    SourceCoverCache.fmt == victim.fmt,
                )
            )
            total -= victim.byte_size or 0
            evicted += 1
    if evicted:
        logger.info(
            "cover_cache: evicted %d least-recently-used row(s) (budget %d bytes)",
            evicted,
            cap,
        )
    return evicted


class SourceCacheService:
    def __init__(self, db: Session, browse: BrowseService) -> None:
        self._db = db
        self._browse = browse

    # --- public API ------------------------------------------------------

    def get_series_meta(
        self, source_id: str, series_key: str, *, force: bool = False
    ) -> dict[str, Any]:
        # Per-caller 18+ gate before any row is read, exactly as
        # ``get_browse_page`` and ``get_series_cover`` do it. This method used
        # to gate only by accident and only sometimes: a MISS reached
        # ``BrowseService.get_series``, which resolves the connector and so
        # applied the gate, while a FRESH HIT served the global row without
        # ever asking — and on a miss the gate's own 404 is an ``AppError``,
        # which the degrade-to-stale handler below then swallowed and served
        # the row anyway. Every caller today gates before it gets here (reader
        # manifest, novels, followed detail), so nothing leaked; but "gated
        # unless the row happens to be cached" is not a gate, and the next
        # caller added would have inherited it. Costs no network — registry
        # lookup only.
        self._browse.ensure_visible(source_id)

        series_key = fully_unquote(series_key)
        row = self._db.get(SourceSeriesCache, (source_id, series_key))
        # ``chapters is not None`` guards against browse write-through rows: a
        # browse listing carries metadata but no chapter list, so such a row is
        # *partial* — good enough to be the stale fallback below, never good
        # enough to satisfy a fresh read (a "fresh" hit with a silently empty
        # chapter list would blank the series screen).
        if (
            row is not None
            and not force
            and self._is_fresh(row)
            and row.chapters is not None
        ):
            return self._serve(source_id, row)

        try:
            meta = self._browse.get_series(source_id, series_key)
            chapters = self._browse.get_chapters(source_id, series_key)
        except (AppError, Exception) as exc:  # noqa: BLE001 - cache must degrade
            if isinstance(exc, AppError) and exc.code in _GATE_ERROR_CODES:
                # The gate refused, so there is nothing to degrade TO: this
                # handler existed for a connector that could not answer, and a
                # gate that will not answer is not the same thing.
                raise
            # Serving stale hides the failure from this reader, not from
            # source health: BrowseService has already counted it (when it was
            # the source's fault) before it reached here.
            if row is not None:
                logger.warning(
                    "source_cache: connector failed for %s/%s, serving stale (%s)",
                    source_id,
                    series_key,
                    exc,
                )
                return self._serve(source_id, row)
            raise

        row = self._upsert(source_id, series_key, meta, chapters)
        return self._serve(source_id, row)

    def _serve(self, source_id: str, row: SourceSeriesCache) -> dict[str, Any]:
        """Serialize one cached row, after the ROW's own 18+ rating is checked.

        ``ensure_visible`` above answers for the whole SOURCE, which said
        nothing about an adult series listed on a general-audience one — a
        madara site tagging a work "Smut". The same series, once followed, is
        hidden from that profile's library by ``resolve_tracker_rating``, so
        this surface printed by name exactly what that one withheld.

        The rule is ``core.content_rating.resolve_series_rating`` — the row's
        stored rating first, its genres behind it (the same signal the follow
        path captures), and unknown stays VISIBLE, for the reason recorded
        there: almost no catalog rates itself, so hiding the unrated would
        empty the app rather than clean it. ``BrowseService._row_visible``
        applies that same function to a live listing; the two agree because
        they call one implementation, not because they were written alike.
        """
        if self._rating_hides(row):
            raise AppError(
                "Series not found.",
                code="series_not_found",
                status_code=404,
                details={"source_id": source_id, "series_id": row.series_key},
            )
        return self._serialize(row)

    def _gate_listing(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Apply THIS caller's 18+ rating rule to a serialized browse page.

        ``source_browse_cache`` rows are global and every profile reads the
        same one, so the gate cannot be baked into what is stored. The page is
        stored whole (``list_series(apply_gate=False)``) and filtered here, on
        every serve, fresh or stale or live.

        Storing the gated page instead meant the cached row inherited whichever
        profile warmed it, and got it wrong in both directions: an open gate
        cached an adult row that a shut gate was then served, and a shut gate
        cached a page missing that row so the profile allowed it lost the
        series until the row expired.

        The pagination envelope is left alone. ``total`` counts the source's
        whole catalog rather than this page, so it cannot be adjusted for rows
        dropped here without inventing a number -- the same reason
        ``BrowseService._serialize_paginated`` gives for leaving it.
        """
        items = payload.get("items")
        if not isinstance(items, list):
            return payload
        gate = getattr(self._browse, "_gate_open", None)
        # A browse stand-in that cannot report a gate is treated as SHUT, the
        # same way ``_rating_hides`` treats it: the safe direction to fail.
        gate_open = bool(callable(gate) and gate())
        if gate_open:
            return payload
        visible = [
            item
            for item in items
            if not (
                isinstance(item, dict)
                and hidden_by_gate(
                    serialized_series_rating(item), gate_open=False
                )
            )
        ]
        if len(visible) == len(items):
            return payload
        gated = dict(payload)
        gated["items"] = visible
        return gated

    def _series_key_hides(self, source_id: str, series_key: str) -> bool:
        """Whether this caller's gate hides the SERIES behind a cached artifact.

        A cover row carries no rating of its own -- it is bytes keyed by
        ``(source, series, width, format)`` -- so the verdict has to come from
        the series row beside it. ``BrowseService.resolve_series_cover``
        already refuses an adult row on a MISS; without this a cached HIT
        handed the same cover straight back, which made the leak a function of
        whether anyone had loaded that grid before.

        Cheap on the hot path: a grid is dozens of covers, and an OPEN gate
        hides nothing, so the extra row is only ever read when the gate is
        shut. An absent series row is not a refusal -- unknown stays visible,
        the same as everywhere else this rule is applied.
        """
        gate = getattr(self._browse, "_gate_open", None)
        if callable(gate) and gate():
            return False
        row = self._db.get(SourceSeriesCache, (source_id, fully_unquote(series_key)))
        return row is not None and self._rating_hides(row)

    def _rating_hides(self, row: SourceSeriesCache) -> bool:
        """Whether this caller's 18+ gate hides ``row`` on its own rating."""
        gate = getattr(self._browse, "_gate_open", None)
        # A browse stand-in that cannot report a gate is treated as SHUT: the
        # rating rule then still applies, which is the safe direction to fail.
        if callable(gate) and gate():
            return False
        # ``source_mature`` is not passed: a mature source never reaches here
        # with the gate shut — ``ensure_visible`` already refused it — so the
        # only question left is what this row itself says.
        rating = resolve_series_rating(row.content_rating, _loads(row.genres) or [])
        return rating == TRACKER_RATING_MATURE

    def get_chapter_list(
        self, source_id: str, series_key: str, *, force: bool = False
    ) -> list[dict[str, Any]]:
        """The series' chapter list — a projection of ``get_series_meta``, and
        gated by it for the same reason."""
        return self.get_series_meta(source_id, series_key, force=force).get(
            "chapters", []
        )

    def get_browse_page(
        self,
        source_id: str,
        *,
        page: int = 1,
        sort: str | None = None,
        genre: str | None = None,
        force: bool = False,
        warm_next: bool = False,
    ) -> dict[str, Any]:
        """One browse page, served from ``source_browse_cache`` when possible.

        The returned dict is the listing exactly as ``BrowseService.list_series``
        shapes it, plus a ``cache`` block: ``{"status": "fresh"|"live"|"stale",
        "stale": bool, "fetched_at": ISO-8601 UTC}`` (see the constants at the
        top of this module for what each status means).

        ``force`` refetches even a fresh row (client pull-to-refresh) — but a
        connector failure still falls back to whatever row exists, because a
        refresh gesture degrading to "same grid as before" beats an error
        screen. ``warm_next`` opportunistically fetches the next page in the
        background after a fresh/live serve (see ``_maybe_warm_next``).

        Search results (``query=...``) never come through here: they bypass the
        cache entirely (unbounded key cardinality; see ``routes/sources.py``).
        A ``sort``/``genre`` the connector never advertised is served the same
        way — live, and stored nowhere (see ``_uncacheable_facet``).
        """
        # Per-caller 18+ gate, applied on EVERY read. Cache rows are global;
        # whether *this* caller may see the source is not. No network involved.
        self._browse.ensure_visible(source_id)

        sort_key = _normalize_sort(sort)
        genre_key = _normalize_genre(genre)
        reason = self._uncacheable_facet(source_id, sort_key, genre_key)
        if reason is not None:
            logger.info(
                "browse_cache: %s for %s (sort=%r genre=%r); browsing live",
                reason,
                source_id,
                sort_key,
                genre_key,
            )
            payload = dict(
                self._browse.list_series(
                    source_id,
                    page=page,
                    sort=sort_key or None,
                    genre=genre_key or None,
                )
            )
            payload["cache"] = live_cache_info()
            # No warm either: warming a key we refuse to store would fetch the
            # next page on every request and throw it away.
            return payload

        key = (source_id, sort_key, genre_key, page)
        try:
            row = self._db.get(SourceBrowseCache, key)
        except Exception:  # noqa: BLE001 - e.g. a DB predating the migration
            logger.warning(
                "browse_cache unavailable; browsing live", exc_info=True
            )
            self._db.rollback()
            row = None

        if row is not None and not force and self._browse_row_fresh(row):
            payload = self._gate_listing(self._browse_payload(row, CACHE_FRESH))
            if warm_next:
                self._maybe_warm_next(source_id, sort_key, genre_key, page, payload)
            return payload

        try:
            # Ungated on purpose: this page is about to be written to a table
            # every profile reads. ``_gate_listing`` applies the caller's own
            # rule on the way out. See its docstring for what storing the
            # gated page did instead.
            listing = self._browse.list_series(
                source_id,
                page=page,
                sort=sort_key or None,
                genre=genre_key or None,
                apply_gate=False,
            )
        except (AppError, Exception) as exc:  # noqa: BLE001 - cache must degrade
            if row is not None:
                logger.warning(
                    "browse_cache: connector failed for %s (sort=%r genre=%r "
                    "page=%d), serving stale from %s (%s)",
                    source_id,
                    sort_key,
                    genre_key,
                    page,
                    row.fetched_at,
                    exc,
                )
                return self._gate_listing(self._browse_payload(row, CACHE_STALE))
            raise

        try:
            row = self._store_browse_page(key, listing)
            self._write_through_listing(source_id, listing.get("items") or [])
            self._evict_oldest(
                SourceBrowseCache, get_settings().browse_cache_max_rows
            )
            self._evict_oldest(
                SourceSeriesCache, get_settings().source_cache_max_rows
            )
            self._db.commit()
        except Exception:  # noqa: BLE001 - a cache write must never break a browse
            logger.exception("browse_cache: cache write failed")
            self._db.rollback()

        payload = self._gate_listing(dict(listing))
        payload["cache"] = live_cache_info()
        if warm_next:
            self._maybe_warm_next(source_id, sort_key, genre_key, page, payload)
        return payload

    # --- rendered covers -------------------------------------------------

    def get_series_cover(
        self,
        source_id: str,
        series_key: str,
        *,
        width: int | None,
        fmt: str = "jpeg",
    ) -> tuple[str, bytes, int | None]:
        """One series cover, optionally downscaled. Returns
        ``(media_type, data, served_width)``; ``served_width`` is ``None``
        when the ORIGINAL bytes are what came back.

        ``width`` must already be snapped onto ``image_resize.COVER_WIDTHS``
        (the route does that) — this method will happily key a cache row on
        whatever it is handed, and the closed width set is the only thing
        bounding the key space.

        THE 18+ GATE IS THE FIRST THING THAT HAPPENS, before any cache lookup,
        and it is re-checked by ``resolve_series_cover`` on every miss. Cover
        rows are GLOBAL and carry no ``user_id``/``profile_id``, exactly like
        ``source_browse_cache``: what varies per (user, profile) is whether
        this reader may see the SOURCE, not what the cover looks like. Baking
        the gate into the cache key would cache the leak instead of preventing
        it — the gate has to be evaluated per request, on the request's own
        profile, which is what ``ensure_visible`` does here.

        Degradation matches the other caches: if the connector fails and a row
        exists (even an expired one) the row is served rather than an error,
        because a stale cover is indistinguishable from a fresh one and a
        missing cover is a hole in the grid.

        Every resize failure — corrupt bytes, an unsupported format, a source
        answering with HTML, Pillow missing entirely — serves the ORIGINAL
        bytes and records a NEGATIVE entry, so the next read of that key
        neither fetches upstream nor decodes again until it expires. See
        ``image_resize.resize_cover`` for what counts as a failure and
        ``database.models.SourceCoverCache`` for how such a row reads back.
        """
        self._browse.ensure_visible(source_id)
        # ...and the SERIES' own rating, which ``ensure_visible`` says nothing
        # about. Before the cache lookup, so a hit cannot answer what a miss
        # would refuse.
        if self._series_key_hides(source_id, series_key):
            raise AppError(
                "Series not found.",
                code="series_not_found",
                status_code=404,
                details={"source_id": source_id, "series_id": series_key},
            )

        settings = get_settings()
        if width is None or fmt not in COVER_FORMATS or not settings.cover_resize_enabled:
            media_type, data = self._browse.resolve_series_cover(source_id, series_key)
            return media_type, data, None

        key = (source_id, fully_unquote(series_key), width, fmt)
        row = self._cover_row(key)
        # A NEGATIVE entry (``resize_failed_at`` set) records that this key does
        # not shrink; its ``data`` is the ORIGINAL bytes, or empty when the
        # original was too large to keep. See ``database.models.SourceCoverCache``.
        negative = row is not None and row.resize_failed_at is not None
        skip_resize = False
        if row is not None and self._cover_row_fresh(row):
            if not negative:
                self._touch_cover(row)
                return row.media_type, bytes(row.data), width
            if row.byte_size:
                self._touch_cover(row)
                return row.media_type, bytes(row.data), None
            # Nothing stored to serve, but the verdict still stands: fetch the
            # original below and skip the decode this key has already failed.
            skip_resize = True

        # The stale-serve fallback, snapshotted as plain values: the pooled
        # connection is released below and ``row`` must not be read after that.
        stale = (
            (row.media_type, bytes(row.data), row.fetched_at, negative)
            if row is not None and row.data
            else None
        )

        # Release the pooled DB connection BEFORE the upstream fetch.
        #
        # Reading the cache row checks a connection out of the engine's pool
        # and the session holds it until the transaction ends -- so without
        # this, a connection stays checked out across a live fetch that may
        # take the whole image-proxy timeout, plus the Pillow resize after it.
        # The pool is 15 connections (5 + 10 overflow) against a 40-thread
        # request pool, so one dead-but-not-yet-timing-out source painted
        # across a cover grid exhausts it: requests with nothing to do with
        # covers -- the library list, saving progress, the reader manifest --
        # queue for ``pool_timeout`` and then fail with a raw QueuePool error.
        # The blast radius was the whole app rather than the one bad source.
        # The session transparently checks a connection back out when
        # ``_store_cover`` needs one.
        self._db.rollback()

        try:
            media_type, data = self._browse.resolve_series_cover(source_id, series_key)
        except (AppError, Exception):  # noqa: BLE001 - cache must degrade
            if stale is not None:
                stale_media_type, stale_data, stale_fetched_at, stale_negative = stale
                logger.warning(
                    "cover_cache: connector failed for %s/%s, serving stale "
                    "(w=%d fmt=%s, fetched %s)",
                    key[0],
                    key[1],
                    width,
                    fmt,
                    stale_fetched_at,
                )
                refreshed = self._cover_row(key)
                if refreshed is not None:
                    self._touch_cover(refreshed)
                # A negative entry's bytes are the original, so the served
                # width is what a passthrough would report: unknown.
                return (
                    stale_media_type,
                    stale_data,
                    None if stale_negative else width,
                )
            raise

        resized = None if skip_resize else resize_cover(data, width=width, fmt=fmt)
        if resized is None:
            # Nothing to gain (or nothing decodable). The original is what gets
            # served, but the FAILURE is recorded, so the next read of this key
            # neither fetches upstream nor decodes again until the entry
            # expires. Without that row this branch was an upstream fetch plus
            # a Pillow decode on every single grid paint, forever — for exactly
            # the covers this table exists to stop re-fetching.
            if not skip_resize:
                self._store_cover(
                    key, media_type, data, resize_failure=_RESIZE_FAILURE_NO_GAIN
                )
            return media_type, data, None

        out_media_type, out_data = resized
        self._store_cover(key, out_media_type, out_data)
        return out_media_type, out_data, width

    # --- rendered-cover internals ----------------------------------------

    def _cover_row(self, key: tuple[str, str, int, str]) -> SourceCoverCache | None:
        try:
            return self._db.get(SourceCoverCache, key)
        except Exception:  # noqa: BLE001 - e.g. a DB predating the migration
            logger.warning("cover_cache unavailable; serving live", exc_info=True)
            self._db.rollback()
            return None

    def _cover_row_fresh(self, row: SourceCoverCache) -> bool:
        ttl = timedelta(minutes=get_settings().cover_cache_ttl_minutes)
        return (utcnow() - row.fetched_at) < ttl

    def _touch_cover(self, row: SourceCoverCache) -> None:
        """Bump ``last_used_at`` for LRU — at most once an hour per row.

        Without the throttle a 24-cover grid would issue 24 UPDATEs against
        SQLite's single writer on a request that otherwise writes nothing.
        """
        now = utcnow()
        if row.last_used_at is not None and (
            now - row.last_used_at
        ) < timedelta(minutes=_COVER_LRU_BUMP_MINUTES):
            return
        try:
            row.last_used_at = now
            self._db.commit()
        except Exception:  # noqa: BLE001 - an LRU bump must never break a read
            logger.debug("cover_cache: last_used_at bump failed", exc_info=True)
            self._db.rollback()

    def _store_cover(
        self,
        key: tuple[str, str, int, str],
        media_type: str,
        data: bytes,
        *,
        resize_failure: str | None = None,
    ) -> None:
        """Upsert one rendered cover and sweep the byte budget. Best effort.

        With ``resize_failure`` set this writes a NEGATIVE entry instead:
        ``data`` is then the ORIGINAL bytes rather than a downscale, and the
        row records that this key produced nothing to serve.
        """
        max_row_bytes = get_settings().cover_cache_max_row_bytes
        if max_row_bytes > 0 and len(data) > max_row_bytes:
            if resize_failure is None:
                # Served, never stored: one pathological source must not be
                # able to spend the whole budget.
                logger.info(
                    "cover_cache: %d bytes exceeds the per-row ceiling; not stored",
                    len(data),
                )
                return
            # The verdict is still worth keeping when the original it describes
            # is not: the marker alone spares the decode on every later read,
            # and the fetch it cannot spare was going to happen anyway.
            data = b""
        source_id, series_key, width, fmt = key
        try:
            row = self._db.get(SourceCoverCache, key)
            if row is None:
                row = SourceCoverCache(
                    source_id=source_id,
                    series_key=series_key,
                    width=width,
                    fmt=fmt,
                )
                self._db.add(row)
            row.media_type = media_type
            row.data = data
            row.byte_size = len(data)
            row.fetched_at = utcnow()
            row.last_used_at = utcnow()
            # Written unconditionally, so a successful downscale CLEARS the
            # negative entry that preceded it rather than leaving a row that
            # claims both.
            row.resize_failure = resize_failure
            row.resize_failed_at = utcnow() if resize_failure else None
            self._evict_cover_bytes()
            self._db.commit()
        except Exception:  # noqa: BLE001 - a cache write must never break a read
            logger.exception("cover_cache: cache write failed")
            self._db.rollback()

    def _evict_cover_bytes(self) -> None:
        """Sweep the rendered-cover byte budget on this request's session."""
        _evict_cover_bytes_to_budget(self._db)

    def write_through(
        self,
        source_id: str,
        series_key: str,
        meta: dict[str, Any] | None,
        chapters: list[dict[str, Any]] | None = None,
    ) -> None:
        """Opportunistic write when a caller already has fresh connector data
        in hand (spec §3.10 — ``browse_service`` / ``source_service`` writes)."""
        try:
            self._upsert(source_id, fully_unquote(series_key), meta or {}, chapters)
        except Exception:  # noqa: BLE001 - a cache write must never break a read
            logger.exception("source_cache: opportunistic write failed")
            self._db.rollback()

    def invalidate(self, source_id: str, series_key: str) -> None:
        row = self._db.get(
            SourceSeriesCache, (source_id, fully_unquote(series_key))
        )
        if row is not None:
            self._db.delete(row)
            self._db.commit()

    # --- internals -----------------------------------------------------

    def _is_fresh(self, row: SourceSeriesCache) -> bool:
        ttl = timedelta(minutes=get_settings().source_cache_ttl_minutes)
        return (utcnow() - row.fetched_at) < ttl

    def _upsert(
        self,
        source_id: str,
        series_key: str,
        meta: dict[str, Any],
        chapters: list[dict[str, Any]] | None,
    ) -> SourceSeriesCache:
        row = self._merge_series_row(source_id, series_key, meta, chapters)
        self._evict_oldest(SourceSeriesCache, get_settings().source_cache_max_rows)
        self._db.commit()
        self._db.refresh(row)
        return row

    def _merge_series_row(
        self,
        source_id: str,
        series_key: str,
        meta: dict[str, Any],
        chapters: list[dict[str, Any]] | None,
    ) -> SourceSeriesCache:
        """Merge connector data into one ``source_series_cache`` row (no commit).

        ``fetched_at`` is only bumped when a *chapter list* arrives (or the row
        is new): metadata-only writes — the browse-listing write-through — must
        not extend an existing row's freshness, or a grid full of thumbnails
        would keep postponing the chapter refetch that the series screen needs.
        """
        row = self._db.get(SourceSeriesCache, (source_id, series_key))
        is_new = row is None
        if row is None:
            row = SourceSeriesCache(source_id=source_id, series_key=series_key)
            self._db.add(row)

        if meta:
            row.title = str(meta.get("title") or row.title or "")
            row.cover_url = meta.get("cover_url", row.cover_url)
            row.description = meta.get("description", row.description)
            row.author = meta.get("author", row.author)
            row.artist = meta.get("artist", row.artist)
            row.status = meta.get("status", row.status)
            row.year = meta.get("year", row.year)
            row.content_rating = meta.get("content_rating", row.content_rating)
            genres = meta.get("genres")
            if genres is not None:
                row.genres = json.dumps(list(genres))
        if chapters is not None:
            row.chapters = json.dumps(
                [
                    {
                        "key": c.get("id") or c.get("key"),
                        "number": c.get("number"),
                        "title": c.get("title"),
                        "published_at": c.get("release_date")
                        or c.get("published_at"),
                        "page_count": c.get("page_count"),
                    }
                    for c in chapters
                ]
            )
        if chapters is not None or is_new:
            row.fetched_at = utcnow()
        return row

    # --- browse-listing cache internals --------------------------------

    def _uncacheable_facet(
        self, source_id: str, sort_key: str, genre_key: str
    ) -> str | None:
        """Why this (sort, genre) pair must be served live, or ``None``.

        ``source_browse_cache`` keys on the facets VERBATIM, so without this
        anything a caller can type is a primary key — and the route hands
        ``?genre=`` straight through. Two ways that goes wrong, both of them
        the rule this module's docstring already states for searches:

          * ``BrowseService.list_series`` answers a genre the connector cannot
            browse by SEARCHING for it (its ``browse_by_genre`` default raises
            ``NotImplementedError``; most connectors never override it), so the
            row stored under a browse key holds search results; and
          * every distinct string mints another row, bounded only by
            ``browse_cache_max_rows`` — 2,000 junk genres evict every real page.

        So a facet is cacheable only when the connector itself advertised it.
        Genres match on id OR label because the web client puts the human label
        in the URL; both are the connector's own strings, so either way the key
        space stays closed. Registry lookup only — no network.
        """
        if not sort_key and not genre_key:
            return None
        resolve = getattr(self._browse, "_get_connector", None)
        if not callable(resolve):
            # Only a test stand-in for BrowseService lands here; the real one
            # always resolves, and ``ensure_visible`` above is that same call.
            return None
        connector = resolve(source_id)

        if sort_key and sort_key not in {
            mode.id for mode in connector.list_browse_modes()
        }:
            return "unadvertised sort"

        if genre_key:
            genres = connector.list_genres()
            advertised = {mode.id for mode in genres} | {mode.label for mode in genres}
            if genre_key not in advertised:
                return "unadvertised genre"
            if type(connector).browse_by_genre is SourceConnector.browse_by_genre:
                return "genre browse unsupported"
        return None

    def _browse_row_fresh(self, row: SourceBrowseCache) -> bool:
        ttl = timedelta(minutes=get_settings().browse_cache_ttl_minutes)
        return (utcnow() - row.fetched_at) < ttl

    @staticmethod
    def _browse_payload(row: SourceBrowseCache, status: str) -> dict[str, Any]:
        listing = _loads(row.payload) or {"items": []}
        listing["cache"] = {
            "status": status,
            "stale": status == CACHE_STALE,
            "fetched_at": row.fetched_at.isoformat() if row.fetched_at else None,
        }
        return listing

    def _store_browse_page(
        self, key: tuple[str, str, str, int], listing: dict[str, Any]
    ) -> SourceBrowseCache:
        """Upsert one cached page (no commit). Stores the listing verbatim —
        the ``cache`` block is added per response, never persisted."""
        source_id, sort_key, genre_key, page = key
        row = self._db.get(SourceBrowseCache, key)
        if row is None:
            row = SourceBrowseCache(
                source_id=source_id, sort=sort_key, genre=genre_key, page=page
            )
            self._db.add(row)
        row.payload = json.dumps(listing)
        row.fetched_at = utcnow()
        return row

    def _write_through_listing(
        self, source_id: str, items: list[dict[str, Any]]
    ) -> None:
        """Seed ``source_series_cache`` from a browse page's items (no commit).

        A browse already carries per-series metadata, so storing it makes the
        series screen render instantly afterwards (title/cover/description
        while chapters load). Only non-None fields are merged so a listing's
        sparser rows never blank out richer data written by a full series
        fetch, and ``_merge_series_row`` keeps ``fetched_at`` untouched for
        existing rows (no chapter list here — see its docstring).
        """
        for item in items:
            series_key = item.get("id")
            title = item.get("title")
            if not series_key or not title:
                continue
            meta = {
                field: item.get(field)
                for field in (
                    "title",
                    "cover_url",
                    "description",
                    "author",
                    "artist",
                    "status",
                    "genres",
                )
                if item.get(field) is not None
            }
            # The source's own verdict first, its genre tags behind it. Same
            # priority order the rating rule itself uses: a catalog that rates
            # its own work knows better than a tag sweep, and most catalogs
            # rate nothing, which is why the genre fallback exists at all.
            declared = item.get("content_rating")
            rating = (
                str(declared).strip().lower()
                if isinstance(declared, str) and declared.strip()
                else rating_from_genres(item.get("genres"))
            )
            if rating is not None:
                meta["content_rating"] = rating
            self._merge_series_row(
                source_id, fully_unquote(str(series_key)), meta, None
            )

    def _maybe_warm_next(
        self,
        source_id: str,
        sort_key: str,
        genre_key: str,
        page: int,
        payload: dict[str, Any],
    ) -> None:
        """Fetch the *next* page in the background so paging forward is instant.

        Bounded on purpose: never past the page after the one just served (no
        catalogue crawl — some sources hold 10k+ series), never when the next
        page is already fresh, never twice concurrently for the same key, and
        never after a stale serve (the connector is down; do not pile on). The
        warm carries the requesting caller's resolved 18+ gate so a mature
        source the caller can see warms exactly like any other.
        """
        if not get_settings().browse_prefetch_enabled:
            return
        if not payload.get("has_more"):
            return
        next_page = page + 1
        key = (source_id, sort_key, genre_key, next_page)
        try:
            existing = self._db.get(SourceBrowseCache, key)
            if existing is not None and self._browse_row_fresh(existing):
                return
        except Exception:  # noqa: BLE001 - warm is best-effort, never a failure
            return
        gate_fn = getattr(self._browse, "_gate_open", None)
        mature_enabled = bool(gate_fn()) if callable(gate_fn) else False

        with _warm_lock:
            if key in _warm_inflight:
                return
            _warm_inflight.add(key)

        def _work() -> None:
            db: Session | None = None
            try:
                db = _open_warm_session()
                browse = _build_warm_browse(db, mature_enabled)
                SourceCacheService(db, browse).get_browse_page(
                    source_id,
                    page=next_page,
                    sort=sort_key or None,
                    genre=genre_key or None,
                )
            except Exception:  # noqa: BLE001 - warm failures are invisible
                logger.debug(
                    "browse_cache: background warm failed for %s (sort=%r "
                    "genre=%r page=%d)",
                    source_id,
                    sort_key,
                    genre_key,
                    next_page,
                    exc_info=True,
                )
            finally:
                with _warm_lock:
                    _warm_inflight.discard(key)
                if db is not None:
                    db.close()

        try:
            _spawn_warm(_work)
        except Exception:  # noqa: BLE001
            with _warm_lock:
                _warm_inflight.discard(key)

    def _evict_oldest(self, model, cap: int) -> None:
        """Delete the oldest rows (by ``fetched_at``) past ``cap`` (no commit).

        Keeps both cache tables bounded no matter how many pages get browsed;
        the caller commits. ``cap <= 0`` disables the ceiling.
        """
        if cap <= 0:
            return
        # autoflush is off session-wide; flush so the row(s) just added are
        # visible to the COUNT and to the age ordering below.
        self._db.flush()
        count = self._db.execute(select(func.count()).select_from(model)).scalar_one()
        excess = count - cap
        if excess <= 0:
            return
        evicted = _delete_oldest_rows(self._db, model, "fetched_at", excess)
        logger.info(
            "source_cache: evicted %d oldest %s row(s) (cap %d)",
            evicted,
            model.__tablename__,
            cap,
        )

    @staticmethod
    def _serialize(row: SourceSeriesCache) -> dict[str, Any]:
        return {
            "source_id": row.source_id,
            "series_key": row.series_key,
            "title": row.title,
            "cover_url": row.cover_url,
            "description": row.description,
            "author": row.author,
            "artist": row.artist,
            "status": row.status,
            "year": row.year,
            "content_rating": row.content_rating,
            "genres": _loads(row.genres) or [],
            # Memoized: this parse dominated every read of a long series.
            "chapters": _memoized_chapters(row),
            "fetched_at": row.fetched_at.isoformat() if row.fetched_at else None,
        }


# --- retention -------------------------------------------------------------
#
# Every eviction above — ``_evict_oldest``, ``_evict_cover_bytes_to_budget``,
# and ``NovelService._evict_lru`` — runs only inside a WRITE and only once a
# cap is exceeded. That makes them a disk brake, not a retention policy, and it
# leaves two kinds of row in place forever.
#
# ROWS OF A SOURCE THAT NO LONGER EXISTS. ``manhuakey`` was dropped from
# ``connectors/catalog.py`` when its domain lapsed; the production database
# still held 40 ``source_series_cache`` rows and 4 ``source_browse_cache`` rows
# for it. No read path can ever use them (every one resolves the connector
# first) and no write path can ever reach them, so nothing shrinks them and
# nothing refreshes them — they are pure residue, and residue that names a
# source is worse than residue that does not: ``BookmarkService`` resolves a
# bookmark's maturity from the registry, so a row whose source has LEFT the
# registry reads as "not adult" there.
#
# ROWS THAT ARE MERELY ANCIENT. 1,539 of 1,550 series rows are browse
# write-throughs, whose ``fetched_at`` is deliberately never bumped
# (``_merge_series_row``), so all of them sit past their 6 h TTL waiting for a
# 20,000-row cap that a handful of users will never reach.
#
# So the policy lives here, declared once for all four tables, and is applied
# by a sweep that runs at boot (``main`` lifespan) and daily (the existing
# ``update_scheduler`` thread) — never on a read path: a cache read must not be
# able to trigger a table scan. Nothing it deletes is data; every row is
# rebuilt by the next read that wants it, so the cost of an over-eager rule is
# one connector fetch.


@dataclass(frozen=True)
class CacheRetentionRule:
    """One cache table's retention policy. The tuple below is the readable form."""

    model: Any
    #: The column that decides a row's age. ``last_used_at`` wherever the table
    #: has one, for the same reason those tables evict by LRU: a well-read old
    #: chapter should outlive a once-opened new one.
    age_column: str
    #: Rows older than this by ``age_column`` go, whatever the caps say. 0
    #: disables the age rule.
    max_age_days: int
    #: ``core.config`` attribute holding this table's row ceiling, or ``None``
    #: when the table is bounded by bytes instead. Read at sweep time so the
    #: env override still applies.
    max_rows_setting: str | None = None
    #: ``core.config`` attribute holding the byte ceiling (covers only).
    max_bytes_setting: str | None = None


#: THE retention policy for the four connector caches. The caps are the
#: existing settings (already env-overridable); the ages are declared here
#: because nothing else in the system has an opinion about them. Each age is a
#: multiple of that table's TTL — long enough that a row still being read is
#: never removed under a reader, short enough that a source nobody opens does
#: not accumulate.
CACHE_RETENTION_RULES: tuple[CacheRetentionRule, ...] = (
    # TTL 6 h. A month covers a reader who follows a series and opens it
    # monthly; past that the row is a browse write-through nobody came back to.
    CacheRetentionRule(SourceSeriesCache, "fetched_at", 30, "source_cache_max_rows"),
    # TTL 60 min, and a page is only ever re-served fresh. A week of nobody
    # opening this (source, sort, genre, page) means the facet is unused.
    CacheRetentionRule(SourceBrowseCache, "fetched_at", 7, "browse_cache_max_rows"),
    # TTL 30 days, LRU by use. Two TTLs of nobody painting this cover.
    CacheRetentionRule(
        SourceCoverCache, "last_used_at", 60, max_bytes_setting="cover_cache_max_bytes"
    ),
    # TTL 7 days, LRU by use. Kept longest of the four: published novel text is
    # immutable, the rows are ~15 KB, and a re-read costs a full scrape.
    CacheRetentionRule(NovelChapterCache, "last_used_at", 90, "novel_cache_max_rows"),
)

#: Composite primary keys are deleted with a row-value ``IN``; chunked so the
#: statement stays inside SQLite's variable limit.
_RETENTION_DELETE_CHUNK = 200


def _delete_oldest_rows(db: Session, model, age_column: str, limit: int) -> int:
    """Delete the ``limit`` oldest rows of ``model`` by ``age_column``.

    Victims are selected as bare KEY TUPLES and deleted with a row-value
    ``IN``. Selecting whole entities to hand to ``Session.delete`` instead
    pulled every column of the excess into the process to throw it away — and
    these tables are where the blobs live: ``source_series_cache.chapters``
    reaches 314 KB (3,174 entries), ``novel_chapter_cache.paragraphs`` 645 KB.
    A delete needs the key and nothing else, which is what
    ``_evict_cover_bytes_to_budget`` already does for the image rows.

    Returns the number removed; the caller commits. ``synchronize_session`` is
    off because the keys are already known — the ORM re-SELECTing them to
    reconcile its identity map would put back the read this exists to avoid.
    """
    primary_key = tuple(model.__table__.primary_key.columns)
    victims = db.execute(
        select(*primary_key).order_by(getattr(model, age_column).asc()).limit(limit)
    ).all()
    deleted = 0
    for start in range(0, len(victims), _RETENTION_DELETE_CHUNK):
        chunk = [tuple(victim) for victim in victims[start : start + _RETENTION_DELETE_CHUNK]]
        result = db.execute(
            delete(model).where(tuple_(*primary_key).in_(chunk)),
            execution_options={"synchronize_session": False},
        )
        deleted += int(result.rowcount or 0)
    return deleted


def sweep_cache_retention(db: Session) -> dict[str, dict[str, int]]:
    """Apply :data:`CACHE_RETENTION_RULES` to all four cache tables.

    Returns ``{table: {reason: rows removed}}`` for whatever it removed, and
    logs one line per table that lost anything. Each table is committed on its
    own, so one failing rule cannot roll back another table's sweep.
    """
    known = sorted(known_source_ids())
    if not known:
        # An empty registry means the import failed, not that every source was
        # deleted. Skipping the orphan rule is the difference between a
        # degraded boot and an emptied cache.
        logger.warning(
            "cache_retention: the connector registry is empty; skipping the "
            "orphan rule this sweep"
        )
    removed: dict[str, dict[str, int]] = {}
    for rule in CACHE_RETENTION_RULES:
        table = rule.model.__tablename__
        counts: dict[str, int] = {}
        try:
            if known:
                counts["orphaned"] = _delete_orphans(db, rule, known)
            counts["aged out"] = _delete_aged(db, rule)
            counts["over cap"] = _enforce_cap(db, rule)
            db.commit()
        except Exception:  # noqa: BLE001 - a maintenance sweep must never break boot
            logger.exception("cache_retention: sweep of %s failed", table)
            db.rollback()
            continue
        counts = {reason: n for reason, n in counts.items() if n}
        if counts:
            removed[table] = counts
            logger.info(
                "cache_retention: removed %s from %s",
                ", ".join(f"{n} {reason}" for reason, n in counts.items()),
                table,
            )
    if not removed:
        logger.debug("cache_retention: nothing to remove")
    return removed


def _delete_orphans(db: Session, rule: CacheRetentionRule, known: list[str]) -> int:
    """Rows whose ``source_id`` is no longer a connector this build defines."""
    result = db.execute(
        delete(rule.model).where(rule.model.source_id.notin_(known)),
        execution_options={"synchronize_session": False},
    )
    return int(result.rowcount or 0)


def _delete_aged(db: Session, rule: CacheRetentionRule) -> int:
    if rule.max_age_days <= 0:
        return 0
    cutoff = utcnow() - timedelta(days=rule.max_age_days)
    result = db.execute(
        delete(rule.model).where(getattr(rule.model, rule.age_column) < cutoff),
        execution_options={"synchronize_session": False},
    )
    return int(result.rowcount or 0)


def _enforce_cap(db: Session, rule: CacheRetentionRule) -> int:
    """The table's own ceiling, applied outside a write for once.

    The write-path sweeps only ever run when somebody browses; a cache that has
    gone quiet stays over its cap indefinitely, which is exactly the state a
    disk-bound VPS cares about.
    """
    if rule.max_bytes_setting is not None:
        return _evict_cover_bytes_to_budget(db)
    if rule.max_rows_setting is None:
        return 0
    cap = int(getattr(get_settings(), rule.max_rows_setting, 0) or 0)
    if cap <= 0:
        return 0
    model = rule.model
    count = db.execute(select(func.count()).select_from(model)).scalar_one()
    excess = count - cap
    if excess <= 0:
        return 0
    return _delete_oldest_rows(db, model, rule.age_column, excess)


def get_source_cache_service(
    db: Annotated[Session, Depends(get_db)],
    browse: Annotated[BrowseService, Depends(get_browse_service)],
) -> SourceCacheService:
    return SourceCacheService(db, browse)
