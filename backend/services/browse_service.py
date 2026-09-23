"""Browse online sources through connector implementations."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import threading
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from itertools import zip_longest
from typing import Annotated, Any
from urllib.parse import quote

from anyio import to_thread
from fastapi import Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from core.config import get_settings
from core.content_rating import (
    hidden_by_gate,
    resolve_mature_gate,
    resolve_series_rating,
)
from core.errors import AppError
from core.profile_context import ProfileContext, resolve_profile_context
from database.models import SourceSeriesCache
from database.session import get_db
from connectors.base import SourceConnector
from connectors.http import swallowed
from connectors.http.client import ConnectorHttpError
from connectors.ids import fully_unquote
from connectors.models import Chapter, Page, PaginatedSeriesList, Series
from connectors.registry import (
    ConnectorDescriptor,
    create_connector,
    list_installed_connectors,
    registry_snapshot,
)
from services.outbound_security import validate_outbound_url
from services.source_health import (
    SourceHealthState,
    load_states,
    record_outcomes,
    record_traffic_outcome,
    source_side_failure,
    states_for,
    summarize,
)

logger = logging.getLogger(__name__)

# --- image proxy transport -------------------------------------------------
# Every page image used to go out through the module-level ``httpx.stream()``,
# which builds and throws away a whole httpx.Client per call -- a fresh DNS
# lookup, TCP connect and TLS handshake for each of the 20-200 images in a
# chapter. Measured from the VPS with scripts/bench_image_proxy.py, 6 images:
#
#     mangadex    2.60s -> 0.09s   (28.9x)
#     flamescans  3.50s -> 0.53s   (6.6x)
#     ehentai     1.20s -> 0.67s   (1.8x)
#
# One pooled, keep-alive client makes the second image onward reuse the
# connection the first one opened. Bounded so a long reading session cannot
# accumulate sockets across dozens of CDNs.
_IMAGE_POOL_MAX_CONNECTIONS = 64
_IMAGE_POOL_MAX_KEEPALIVE = 32
_IMAGE_POOL_KEEPALIVE_EXPIRY_SECONDS = 60.0

_image_http_client: Any = None
_image_client_lock = threading.Lock()


def _image_client() -> Any:
    """Return the process-wide pooled client used for image/cover GETs."""
    global _image_http_client
    import httpx

    client = _image_http_client
    if client is not None and not client.is_closed:
        return client
    with _image_client_lock:
        if _image_http_client is None or _image_http_client.is_closed:
            _image_http_client = httpx.Client(
                follow_redirects=False,
                timeout=30.0,
                limits=httpx.Limits(
                    max_connections=_IMAGE_POOL_MAX_CONNECTIONS,
                    max_keepalive_connections=_IMAGE_POOL_MAX_KEEPALIVE,
                    keepalive_expiry=_IMAGE_POOL_KEEPALIVE_EXPIRY_SECONDS,
                ),
            )
        return _image_http_client


def _image_stream(method: str, url: str, **kwargs: Any):
    """Seam for the outbound image request.

    Signature-compatible with ``httpx.stream`` on purpose: it is the single
    point every proxied image byte passes through, which is what the SSRF and
    redirect tests assert against.
    """
    return _image_client().stream(method, url, **kwargs)


# Federated search fan-out tuning. The fan-out is I/O bound across dozens of
# unrelated sites, so it gets a dedicated pool instead of the shared default
# executor: the previous semaphore of 8 serialised the registry into
# ceil(N/8) rounds of _SEARCH_TIMEOUT_SECONDS, measured at 34-52s against the
# mobile client's 30s receive timeout (i.e. search failed outright). Fanning
# out to every source at once measured 10.8s on the same 50-source registry.
_SEARCH_MAX_WORKERS = 128
_SEARCH_TIMEOUT_SECONDS = 8.0
# Whole-request budget. Whatever has not resolved by the deadline is reported
# as a failed source so the client always gets its page back in time.
_SEARCH_DEADLINE_SECONDS = 12.0
# Search runs on a much tighter HTTP budget than browsing (30s x 3 retries):
# one wedged site must not eat the deadline. Applied only to the search-scoped
# connector instances built by _search_connector, so browsing keeps its
# resilience.
_SEARCH_HTTP_TIMEOUT_SECONDS = 6.0
_SEARCH_HTTP_RETRIES = 1
# A source that answers with this many titles, none of which share a token with
# the query, is answering something other than what was asked -- baozimh returns
# its whole 82-title catalog for every query -- so its results are dropped.
# Below the threshold results are only demoted, never dropped: a narrow result
# set with no literal overlap is exactly how a genuine alternative-title hit
# looks (MangaDex answers "lookism" with the single romanized title
# "Oemo Jisangjuui").
_QUERY_IGNORED_MIN_ITEMS = 10
_WHITESPACE_RE = re.compile(r"\s+")
_TOKEN_SPLIT_RE = re.compile(r"[^\w]+", re.UNICODE)
_LOCAL_GROUP_NAME = "My Library"

# The only media types the image proxy will ever declare to a browser. The
# upstream Content-Type used to be reflected verbatim, so a hostile
# allowlisted host serving ``text/html`` (or scriptable ``image/svg+xml``)
# became stored XSS on the app origin. Anything else is served as an opaque
# download instead.
_ALLOWED_IMAGE_MEDIA_TYPES = frozenset(
    {"image/jpeg", "image/png", "image/webp", "image/avif", "image/gif"}
)


def _safe_image_media_type(media_type: str | None) -> str:
    """Clamp an upstream Content-Type to the bitmap allowlist."""
    cleaned = (media_type or "").split(";")[0].strip().lower()
    if cleaned in _ALLOWED_IMAGE_MEDIA_TYPES:
        return cleaned
    return "application/octet-stream"


_search_executor: ThreadPoolExecutor | None = None
_search_executor_lock = threading.Lock()
# Search-scoped connector instances, one per source (see _search_connector).
_search_connectors: dict[str, SourceConnector] = {}
_search_connectors_lock = threading.Lock()


def _absolute_url(base_url: str, path: str) -> str:
    """Join a request base URL (``http://host/``) with a relative API path."""
    return f"{base_url.rstrip('/')}/{path.lstrip('/')}"


def _normalize_title(title: str) -> str:
    """Collapse whitespace + casefold for duplicate detection within a source."""
    return _WHITESPACE_RE.sub(" ", (title or "").strip()).casefold()


def _query_tokens(query: str) -> list[str]:
    return [token for token in _TOKEN_SPLIT_RE.split(query.casefold()) if token]


def _relevance_score(title: str, query_norm: str, tokens: list[str]) -> float:
    """Rank one result title against the query. ``0.0`` means "shares nothing".

    Only the title is available here -- connectors normalize away the alternative
    titles a site matched on -- so a zero score means "no literal overlap", not
    "wrong result". Callers demote zeros rather than discarding them; see
    _QUERY_IGNORED_MIN_ITEMS for the one case where a source is dropped.
    """
    normalized = _normalize_title(title)
    if not normalized or not tokens:
        return 0.0
    if normalized == query_norm:
        return 4.0
    if query_norm in normalized:
        return 3.0
    matched = sum(1 for token in tokens if token in normalized)
    if matched == len(tokens):
        return 2.0
    if matched:
        return 1.0 + matched / len(tokens)
    return 0.0


_URL_IN_TEXT = re.compile(r"https?://\S+")


def _redact_urls(text: str) -> str:
    """Strip URLs out of an error string.

    httpx builds its message from the failing request URL, which for a search
    carries the query string. This message is persisted on the GLOBAL
    source_health row and served to every authenticated caller, so leaving it
    intact made one account's search terms readable by another. The rest of the
    message is genuinely useful when diagnosing a dead source, so redact rather
    than discard.
    """
    return _URL_IN_TEXT.sub("<url>", text).strip()


def _search_error_message(exc: BaseException) -> str:
    """One-line, client-safe reason a source contributed nothing."""
    if isinstance(exc, TimeoutError):
        return "Timed out."
    if isinstance(exc, ConnectorHttpError) and exc.status_code == 403:
        return "Access blocked (403). This source may use Cloudflare or bot protection."
    return _redact_urls(str(exc)) or exc.__class__.__name__


def _get_search_executor() -> ThreadPoolExecutor:
    """The federated fan-out's own thread pool.

    Sized to hold the whole registry at once; threads are spawned on demand, so
    a small search costs no more than a small pool. Kept off the default
    executor so a wedged source cannot starve unrelated background work.
    """
    global _search_executor
    if _search_executor is None:
        with _search_executor_lock:
            if _search_executor is None:
                _search_executor = ThreadPoolExecutor(
                    max_workers=_SEARCH_MAX_WORKERS,
                    thread_name_prefix="federated-search",
                )
    return _search_executor


def _apply_search_http_budget(connector: SourceConnector) -> None:
    """Tighten every HTTP client the connector owns to the search budget.

    Both connector HTTP clients (httpx and the curl_cffi one) expose the same
    ``_timeout`` / ``_max_retries`` knobs. Reaching for them here keeps the
    budget in one place instead of threading a parameter through 50 connector
    files, and it is only ever applied to the search-scoped instance below --
    never to the shared instance browsing uses.
    """
    for value in vars(connector).values():
        timeout = getattr(value, "_timeout", None)
        retries = getattr(value, "_max_retries", None)
        if not isinstance(timeout, (int, float)) or not isinstance(retries, int):
            continue
        value._timeout = min(float(timeout), _SEARCH_HTTP_TIMEOUT_SECONDS)
        value._max_retries = min(retries, _SEARCH_HTTP_RETRIES)
        # httpx.Client keeps its own copy of the timeout for every request.
        inner = getattr(value, "_client", None)
        if inner is not None and hasattr(inner, "timeout"):
            inner.timeout = _SEARCH_HTTP_TIMEOUT_SECONDS


def _search_connector(source_id: str) -> SourceConnector:
    """Return the connector instance the federated fan-out should use.

    The registry hands browsing a cached instance per source; search needs a
    tighter HTTP budget than browsing, so it keeps its own instance rather than
    mutating a shared one out from under a concurrent browse request.
    """
    connector = create_connector(source_id)
    if not isinstance(connector, SourceConnector):
        # Test doubles and anything else non-standard are used untouched.
        return connector
    cached = _search_connectors.get(source_id)
    if cached is not None and type(cached) is type(connector):
        return cached
    try:
        scoped = type(connector)()
    except Exception:  # pragma: no cover - connector needs constructor config
        logger.debug("federated_search source=%s has no search-scoped instance", source_id)
        return connector
    _apply_search_http_budget(scoped)
    with _search_connectors_lock:
        return _search_connectors.setdefault(source_id, scoped)


def _round_robin(buckets: list[list[dict[str, object]]], limit: int) -> list[dict[str, object]]:
    """Interleave per-source result lists, one item per source per round.

    This replaces the flat ``merged[:per_page]`` truncation: with sources
    concatenated in connector display-name order, the third source alone
    (baozimh, 82 catalog titles) consumed all 40 slots and the real hits never
    reached the page.
    """
    picked: list[dict[str, object]] = []
    for row in zip_longest(*buckets):
        for item in row:
            if item is None:
                continue
            picked.append(item)
            if len(picked) >= limit:
                return picked
    return picked


def _normalize_source_chapter_id(chapter_id: str) -> str:
    """Decode chapter IDs from URL paths (may contain ``/`` for some sources)."""
    return fully_unquote(chapter_id).strip().strip("/")


def _serialize_series(series: Series, source_id: str) -> dict[str, object]:
    return {
        "id": series.id,
        "source_id": source_id,
        "title": series.title,
        "chapter_count": series.chapter_count,
        "description": series.description,
        "author": series.author,
        "artist": series.artist,
        "status": series.status,
        "genres": list(series.genres),
        "content_rating": series.content_rating,
        "latest_chapter": series.latest_chapter,
        "cover_url": f"/sources/{source_id}/series/{quote(series.id, safe='')}/cover",
    }


def _serialize_chapter(chapter: Chapter, source_id: str) -> dict[str, object]:
    return {
        "id": chapter.id,
        "source_id": source_id,
        "series_id": chapter.series_id,
        "title": chapter.title,
        "number": chapter.number,
        "page_count": chapter.page_count,
        "release_date": chapter.release_date,
    }


def _serialize_page(page: Page, source_id: str) -> dict[str, object]:
    return {
        "id": page.id,
        "chapter_id": page.chapter_id,
        "number": page.number,
        "width": page.width,
        "height": page.height,
        "image_url": f"/sources/{source_id}/pages/{quote(page.id, safe='')}/image",
    }


def _invalidate_series_caches(connector: SourceConnector, series_id: str) -> None:
    """Drop per-series connector caches after a transient upstream miss."""
    api_key = fully_unquote(series_id).strip().strip("/")
    if api_key.startswith("serie/"):
        api_key = api_key.removeprefix("serie/")
    for cache_name in ("_series_cache", "_chapter_list_cache", "_gallery_cache", "_page_cache"):
        cache = getattr(connector, cache_name, None)
        if cache is not None and hasattr(cache, "pop"):
            cache.pop(api_key)


def _chapter_key_needle(chapter_key: str) -> str:
    """The literal substring a cached chapter list holds for this key.

    Built with ``json.dumps`` rather than an f-string so the escaping matches
    byte for byte what ``SourceCacheService`` wrote -- a key containing a quote
    or a backslash would otherwise never match its own row.
    """
    return json.dumps({"key": chapter_key})[1:-1]


def _loads_genres(raw: str | None) -> list[str]:
    """A cached row's ``genres`` JSON, or nothing when it is absent or broken."""
    try:
        parsed = json.loads(raw) if raw else None
    except ValueError:
        return []
    return [str(item) for item in parsed] if isinstance(parsed, list) else []


def _row_visible(series: Series, *, gate_open: bool, source_mature: bool) -> bool:
    """Whether one catalog row survives a caller's 18+ gate.

    The source gate answers for a whole catalog, which left an adult series
    listed on a general-audience source reaching a gate-closed profile -- the
    same series that profile's library hides once it is followed.
    ``resolve_series_rating`` is that library rule, applied here to the genres
    the connector already returns, so browse and library agree about a row
    instead of one hiding what the other prints. Unknown stays visible: almost
    no catalog rates itself.

    Takes the gate as an argument rather than reading it off the service
    because the federated fan-out is handed its gate by the route.
    """
    return not hidden_by_gate(
        resolve_series_rating(None, series.genres, source_mature=source_mature),
        gate_open=gate_open,
    )


def _serialize_paginated(
    listing: PaginatedSeriesList,
    source_id: str,
    items: list[Series],
) -> dict[str, object]:
    """``items`` is passed separately because it is the GATED subset of
    ``listing.items``; the pagination envelope stays the source's own. Upstream
    ``total`` counts the whole catalog, not this page, so it cannot be adjusted
    for rows dropped here without inventing a number."""
    from utils.api_pagination import enrich_pagination_aliases

    return enrich_pagination_aliases(
        {
            "items": [_serialize_series(item, source_id) for item in items],
            "page": listing.page,
            "page_size": listing.page_size,
            "total": listing.total,
            "total_pages": listing.total_pages,
            "has_more": listing.has_more,
        }
    )


class BrowseService:
    """Source-agnostic facade for browsing online catalogs."""

    def __init__(
        self,
        mature_enabled: bool | None = None,
        db: Session | None = None,
        user_id: int | None = None,
        profile_id: int | None = None,
        record_traffic_health: bool = False,
    ) -> None:
        """``mature_enabled`` is the caller's *resolved* 18+ gate.

        It is passed in rather than looked up because the gate is per-(user,
        profile) and this service holds neither a DB session nor a
        ``ProfileContext`` -- reading ``get_settings()`` here is exactly the bug
        that made the in-app toggle inert. ``get_browse_service`` resolves it
        from the request's profile.

        ``None`` means "no caller context", and falls back to the global config
        default at *call* time (not construction, so a settings change is
        observed). That path exists only for the handful of context-free
        callers: the federated search fan-out, cover prefetching for series
        already in a library, and direct construction in connector tests.

        ``db`` is the caller's request-scoped session, used for source health
        (reading it, and recording what the search fan-out observed) and for
        the cached chapter->series lookup a shut gate needs in
        ``_require_visible_chapter``. It is optional for the same reason as the
        gate: the context-free callers above have no session, and a service
        without one simply reports every source's health as unknown instead of
        failing.

        ``user_id``/``profile_id`` scope the NAS browse mode. Downloads belong
        to a (user, profile) pair exactly like library membership does, so
        without them the NAS listing would show one reader what another reader
        downloaded. Absent context yields an empty NAS listing rather than an
        unscoped one -- the safe direction to fail.

        ``record_traffic_health`` makes a series page, a chapter list or a
        single-source search count towards the source's health (see
        ``source_health``'s "Real traffic"). Only ``get_browse_service`` turns it
        on, because only there is the request a READER's. Every other
        constructor is a background actor with rules of its own: the update
        sweep records one outcome per source per pass and deliberately counts
        an empty chapter list as neither success nor failure, which a per-call
        success recorded underneath it would silently undo; and the browse
        warm is a speculative fetch nobody is waiting on.
        """
        self._mature_enabled = mature_enabled
        self._db = db
        self._user_id = user_id
        self._profile_id = profile_id
        self._record_traffic_health = record_traffic_health and db is not None
        # Guards ``self._db`` for the one read that happens off the request
        # thread -- see ``_require_visible_chapter``. Per instance, which is
        # per request, which is the scope of the fan-out that needs it.
        self._db_lock = threading.Lock()

    def _gate_open(self) -> bool:
        """Whether adult content is permitted for whoever built this service."""
        if self._mature_enabled is not None:
            return self._mature_enabled
        return get_settings().mature_content_enabled

    def _series_visible(self, series: Series, connector: SourceConnector) -> bool:
        """``_row_visible`` for a source resolved through ``_get_connector``."""
        return _row_visible(
            series, gate_open=self._gate_open(), source_mature=connector.is_mature
        )

    def _require_visible_series(
        self, series: Series, connector: SourceConnector, source_id: str
    ) -> None:
        """404 a row this caller's 18+ gate hides, exactly as an absent one."""
        if self._series_visible(series, connector):
            return
        raise AppError(
            "Series not found.",
            code="series_not_found",
            status_code=404,
            details={"source_id": source_id, "series_id": series.id},
        )

    def _require_visible_chapter(
        self, source_id: str, chapter_key: str, connector: SourceConnector
    ) -> None:
        """404 a chapter whose SERIES this caller's 18+ gate hides.

        ``/sources/{id}/chapters/{key}/pages`` is the one read that names no
        series, so the series has to be recovered rather than received: the
        only signal available is the cached row that remembers this chapter.
        A chapter no cached row claims resolves unknown, and unknown stays
        visible -- the alternative is a page route that fails until something
        happens to have browsed the series.

        Only a SHUT gate pays for the lookup, which also keeps it off the
        reader's bulk-manifest fan-out for every caller who is allowed the
        content anyway; the lock is there because that fan-out calls this on
        worker threads that would otherwise share one Session.
        """
        if self._gate_open() or self._db is None:
            return
        with self._db_lock:
            row = self._db.execute(
                select(SourceSeriesCache)
                .where(
                    SourceSeriesCache.source_id == source_id,
                    SourceSeriesCache.chapters.contains(
                        _chapter_key_needle(chapter_key), autoescape=True
                    ),
                )
                .limit(1)
            ).scalar_one_or_none()
        if row is None:
            return
        rating = resolve_series_rating(
            row.content_rating,
            _loads_genres(row.genres),
            source_mature=connector.is_mature,
        )
        if hidden_by_gate(rating, gate_open=False):
            raise AppError(
                "Chapter not found.",
                code="chapter_not_found",
                status_code=404,
                details={"source_id": source_id, "chapter_id": chapter_key},
            )

    def _traffic_ok(self, source_id: str) -> None:
        """This reader's request found the source answering."""
        if self._record_traffic_health:
            record_traffic_outcome(self._traffic_bind(), source_id, None)

    def _traffic_failed(
        self,
        source_id: str,
        exc: BaseException,
        noted: list[BaseException] | None = None,
    ) -> None:
        """This reader's request failed; record it only if the SOURCE did.

        ``noted`` is what the connector swallowed on the way (see
        ``_observe_traffic``). It is the fallback, not the first choice: the
        raised failure is the direct evidence, and a 404 we raise because the
        connector answered None is only the source's fault when the None hid a
        source-side failure.
        """
        if not self._record_traffic_health:
            return
        error = source_side_failure(exc)
        if error is None:
            error = self._swallowed_failure(noted)
        if error is not None:
            record_traffic_outcome(self._traffic_bind(), source_id, error)

    def _traffic_swallowed(
        self, source_id: str, noted: list[BaseException]
    ) -> None:
        """The source gave nothing back; record it if the nothing hid the
        SOURCE failing.

        For a None series or an empty chapter list that came back without an
        exception. With nothing noted this records nothing, exactly as before:
        a genuine "no such series" or an empty list the site served is evidence
        of neither success nor failure.
        """
        if not self._record_traffic_health:
            return
        error = self._swallowed_failure(noted)
        if error is not None:
            record_traffic_outcome(self._traffic_bind(), source_id, error)

    @staticmethod
    def _swallowed_failure(noted: list[BaseException] | None) -> str | None:
        """The newest noted failure that is the source's, as a health message.

        Newest, because a retry supersedes the attempt before it. Filtered by
        ``source_side_failure`` like everything else, so a swallowed 404 or a
        timeout still counts as nothing.
        """
        for exc in reversed(noted or ()):
            error = source_side_failure(exc)
            if error is not None:
                return error
        return None

    def _traffic_bind(self):
        # The engine, not the session: the recording opens a session of its own
        # (see ``record_traffic_outcome`` for why).
        try:
            return self._db.get_bind() if self._db is not None else None
        except Exception:  # noqa: BLE001 - no engine means nothing to record into
            return None

    @contextmanager
    def _observe_traffic(self, source_id: str):
        """Count a failure raised inside this block against ``source_id``.

        Only the failure: what counts as a success differs per read, so each
        caller says so itself with ``_traffic_ok``. Anything that is not the
        source's fault (a 404 of ours, the 18+ gate, a timeout) is filtered by
        ``source_side_failure``, so wrapping a gate check here is harmless.

        Yields the failures the connector SWALLOWED inside the block. Most
        families (Madara among them) answer a blocked series page with None
        and a blocked chapter list with [], so the failure never reaches the
        ``except`` below; a caller that got nothing back hands this list to
        ``_traffic_swallowed``. It stays readable after the block.
        """
        with swallowed.capture() as noted:
            try:
                yield noted
            except Exception as exc:
                self._traffic_failed(source_id, exc, noted)
                raise

    @staticmethod
    def _raise_source_connector_error(source_id: str, exc: Exception) -> None:
        """Map upstream connector failures to client-facing browse errors."""
        if isinstance(exc, ConnectorHttpError):
            if exc.status_code == 403:
                message = (
                    "Access blocked (403). This source may use Cloudflare or bot protection."
                )
            else:
                message = str(exc) or "Could not load source catalog."
            raise AppError(
                message,
                code="source_unreachable",
                status_code=502,
                details={"source_id": source_id},
            ) from exc
        if isinstance(exc, OSError):
            raise AppError(
                "Could not reach the source site (network timeout).",
                code="source_unreachable",
                status_code=502,
                details={"source_id": source_id},
            ) from exc
        raise exc

    def _visible_descriptors(self) -> list[ConnectorDescriptor]:
        """The browsable sources this caller's 18+ gate allows.

        Single definition of "sources I can see", so the health surfaces below
        cannot drift from what ``list_sources`` shows.
        """
        return list_installed_connectors(
            browsable_only=True,
            include_mature=self._gate_open(),
        )

    def _health_for(
        self, descriptors: list[ConnectorDescriptor]
    ) -> dict[str, SourceHealthState]:
        """Health keyed by source id, for these descriptors only.

        Health is stored globally but read through the caller's own gated
        descriptor list, so a mature source's health cannot reach a profile
        that is not allowed to know the source exists.
        """
        return states_for(
            load_states(self._db), [descriptor.source_type for descriptor in descriptors]
        )

    @staticmethod
    def _source_payload(
        descriptor: ConnectorDescriptor, health: SourceHealthState
    ) -> dict[str, object]:
        """One row of the source listing. Shared by /sources and /sources/health
        so the two can never disagree about a source's shape."""
        return {
            "id": descriptor.source_type,
            "source_id": descriptor.source_type,
            "name": descriptor.name,
            "description": descriptor.description,
            "browsable": descriptor.browsable,
            "supports_import": descriptor.supports_import,
            # Carried through so the client can badge 18+ sources; the
            # descriptor has always had it, the payload just dropped it.
            "mature": descriptor.mature,
            "icon_url": descriptor.icon_url,
            # "manga" | "novel" — clients open the matching reader on this
            # (spec 2026-09-04-novels-design §3). Novel sources only ever
            # appear here when MM_NOVELS_ENABLED is on (registry gate).
            "content_kind": descriptor.content_kind,
            # Content language ("en") where the connector declares one;
            # null for the legacy manga connectors, which never did.
            "language": descriptor.language,
            # Additive: lets the listing badge a source the owner's searches
            # have found unreachable, instead of it looking installed and fine
            # right up until a followed series stops updating.
            "health": health.payload(),
        }

    def list_sources(self) -> list[dict[str, object]]:
        snapshot = registry_snapshot()
        descriptors = self._visible_descriptors()
        health = self._health_for(descriptors)
        logging.getLogger("uvicorn.error").info(
            "GET /sources registry_id=%s all_types=%s browsable_types=%s returning=%s",
            snapshot["registry_id"],
            snapshot["connector_types"],
            snapshot["browsable_types"],
            [descriptor.source_type for descriptor in descriptors],
        )
        return [
            self._source_payload(descriptor, health[descriptor.source_type])
            for descriptor in descriptors
        ]

    def list_source_health(self) -> list[dict[str, object]]:
        """The same rows as ``list_sources``, ordered worst-first.

        Deliberately not a different payload shape, so a client can render
        either list with one component; the only difference is the order --
        dead sources first, then failing, then never-probed, then healthy --
        because the question this view answers is "what is broken", not "what
        can I browse". A failing source is never omitted: hiding it is exactly
        how the owner ended up unable to tell a dead source from a quiet one.
        """
        descriptors = self._visible_descriptors()
        health = self._health_for(descriptors)
        ordered = sorted(
            descriptors,
            key=lambda descriptor: (
                health[descriptor.source_type].severity,
                -health[descriptor.source_type].consecutive_failures,
                descriptor.name.casefold(),
            ),
        )
        return [
            self._source_payload(descriptor, health[descriptor.source_type])
            for descriptor in ordered
        ]

    def source_health_summary(self) -> dict[str, int]:
        """Counts by status across the sources this caller can see."""
        return summarize(self._health_for(self._visible_descriptors()).values())

    def _get_connector(self, source_id: str) -> SourceConnector:
        try:
            connector = create_connector(source_id)
        except ValueError as exc:
            raise AppError(
                "Source not found.",
                code="source_not_found",
                status_code=404,
                details={"source_id": source_id},
            ) from exc
        if not connector.is_browsable:
            raise AppError(
                "Source is not browsable.",
                code="source_not_browsable",
                status_code=400,
                details={"source_id": source_id},
            )
        # A mature source is hidden entirely when the user has not opted into
        # adult content: report it as not-found rather than "forbidden" so its
        # existence isn't disclosed. This one check covers every read path
        # (browse, search, series, chapters, pages, reader, covers) because
        # they all resolve their connector here.
        if connector.is_mature and not self._gate_open():
            raise AppError(
                "Source not found.",
                code="source_not_found",
                status_code=404,
                details={"source_id": source_id},
            )
        return connector

    def ensure_visible(self, source_id: str) -> None:
        """Enforce this caller's view of ``source_id`` — no network involved.

        Raises exactly what a live browse would (404 unknown, 404 mature while
        the caller's 18+ gate is closed, 400 not browsable). Exists so cached
        read paths (``SourceCacheService.get_browse_page``) can apply the
        per-caller gate on every read without touching the connector: cache
        rows are global, the gate never is.
        """
        self._get_connector(source_id)

    def list_browse_modes(self, source_id: str) -> list[dict[str, str]]:
        connector = self._get_connector(source_id)
        modes = [
            {"id": mode.id, "label": mode.label} for mode in connector.list_browse_modes()
        ]
        # The old "NAS" browse mode (a view of server-held downloads) is gone:
        # source-native, nothing is stored server-side (spec §1, §5.1).
        return modes

    def list_genres(self, source_id: str) -> list[dict[str, str]]:
        connector = self._get_connector(source_id)
        return [{"id": mode.id, "label": mode.label} for mode in connector.list_genres()]

    def list_series(
        self,
        source_id: str,
        *,
        page: int = 1,
        query: str | None = None,
        sort: str | None = None,
        genre: str | None = None,
        apply_gate: bool = True,
    ) -> dict[str, object]:
        """One page of a source's catalog, gated to this caller.

        ``apply_gate=False`` returns the page WITHOUT the per-row 18+ filter,
        and exists for exactly one caller: ``SourceCacheService``, which stores
        a browse page in a table shared by every profile. Storing the gated
        page made the cached row inherit whichever profile happened to warm it,
        in both directions -- an open gate cached an adult row and a shut gate
        was later served it, and a shut gate cached a page without that row and
        the profile allowed it lost the series until the row expired. The cache
        stores the whole page and applies the gate on the way out instead.

        Nothing else may pass ``False``. The source gate
        (``ensure_visible``) is unaffected either way: it runs before this and
        answers for the whole catalog, so an ungated LIST is still only ever a
        list of a source this caller may already see. What it drops is the
        per-ROW rule, which is the caller's to re-apply.
        """
        connector = self._get_connector(source_id)
        normalized_query = query.strip() if query else None
        normalized_sort = sort.strip() if sort else None
        normalized_genre = genre.strip() if genre else None
        if normalized_sort == "default":
            normalized_sort = None

        try:
            if normalized_genre and normalized_query:
                listing = connector.search_series(
                    f"{normalized_genre} {normalized_query}",
                    page,
                    sort=normalized_sort,
                )
                operation = "genre_search"
            elif normalized_genre:
                try:
                    listing = connector.browse_by_genre(
                        normalized_genre,
                        page,
                        sort=normalized_sort,
                    )
                    operation = "genre_browse"
                except NotImplementedError:
                    listing = connector.search_series(
                        normalized_genre, page, sort=normalized_sort
                    )
                    operation = "genre_search"
            elif normalized_query:
                listing = connector.search_series(normalized_query, page, sort=normalized_sort)
                operation = "search"
            else:
                listing = connector.get_series_list(page, sort=normalized_sort)
                operation = "browse"
        except (ConnectorHttpError, OSError) as exc:
            # A search is real traffic the re-probe never makes -- its one
            # listing page cannot see a source blocked only on search. A plain
            # browse is left to the re-probe, which asks for exactly that.
            if normalized_query:
                self._traffic_failed(source_id, exc)
            self._raise_source_connector_error(source_id, exc)
        except Exception as exc:
            if normalized_query:
                self._traffic_failed(source_id, exc)
            raise
        if normalized_query:
            # Any answer is the source answering, zero results included --
            # the same rule the federated fan-out records by.
            self._traffic_ok(source_id)

        logger.info(
            "%s source=%s page=%d sort=%r query=%r genre=%r parsed=%d total=%d total_pages=%d has_more=%s",
            operation,
            source_id,
            page,
            normalized_sort,
            normalized_query,
            normalized_genre,
            len(listing.items),
            listing.total,
            listing.total_pages,
            listing.has_more,
        )
        return _serialize_paginated(
            listing,
            source_id,
            list(listing.items)
            if not apply_gate
            else [
                item for item in listing.items if self._series_visible(item, connector)
            ],
        )

    async def _fan_out_search(
        self,
        query: str,
        source_ids: list[str],
        *,
        page: int,
    ) -> dict[str, PaginatedSeriesList | BaseException]:
        """Query every source at once, bounded per source and overall.

        Returns one entry per source: its listing, or the exception explaining
        why it contributed nothing. Sources still running at the overall
        deadline are cancelled and reported as timed out -- their threads are
        left to drain in the dedicated pool rather than holding up the response.
        """
        loop = asyncio.get_running_loop()
        executor = _get_search_executor()

        async def _search_one(source_id: str) -> PaginatedSeriesList:
            def _work() -> PaginatedSeriesList:
                return _search_connector(source_id).search_series(query, page, sort=None)

            return await asyncio.wait_for(
                loop.run_in_executor(executor, _work),
                timeout=_SEARCH_TIMEOUT_SECONDS,
            )

        tasks = {
            asyncio.ensure_future(_search_one(source_id)): source_id
            for source_id in source_ids
        }
        done, pending = await asyncio.wait(tasks, timeout=_SEARCH_DEADLINE_SECONDS)

        outcomes: dict[str, PaginatedSeriesList | BaseException] = {}
        for task in done:
            failure = task.exception()
            outcomes[tasks[task]] = failure if failure is not None else task.result()
        for task in pending:
            task.cancel()
            outcomes[tasks[task]] = TimeoutError("Search deadline exceeded.")
        return outcomes

    def _merge_health(
        self, outcomes: dict[str, PaginatedSeriesList | BaseException]
    ) -> dict[str, SourceHealthState]:
        """Record this fan-out's outcomes and return health for every source.

        Sources that were not probed (empty query) keep whatever was already
        recorded -- nothing was learned about them, so nothing is written.

        A source counts as OK whenever it *answered*, including with zero
        results or with the unrelated-catalog dump that
        ``_QUERY_IGNORED_MIN_ITEMS`` throws away. That is deliberate: those are
        relevance problems, and treating them as outages would demote a
        perfectly reachable source and make the health table lie about why the
        results are bad.
        """
        stored = load_states(self._db)
        if not outcomes:
            return stored
        results = {
            source_id: (
                _search_error_message(outcome)
                if isinstance(outcome, BaseException)
                else None
            )
            for source_id, outcome in outcomes.items()
        }
        try:
            return {**stored, **record_outcomes(self._db, results)}
        except Exception:  # pragma: no cover - defensive
            # Health is diagnostic metadata about the search; it must never be
            # the reason the search itself fails. record_outcomes already
            # handles database errors, so reaching here means a bug -- log it
            # loudly and serve the results with the last known health.
            logger.exception("federated_search could not record source health")
            return stored

    def _build_source_group(
        self,
        descriptor: ConnectorDescriptor,
        outcome: PaginatedSeriesList | BaseException | None,
        *,
        base_url: str,
        query_norm: str,
        tokens: list[str],
        health: SourceHealthState,
        gate_open: bool,
    ) -> tuple[dict[str, object], float]:
        """Turn one source's outcome into a display group + its best score."""
        source_id = descriptor.source_type
        group: dict[str, object] = {
            "source": source_id,
            "source_name": descriptor.name,
            "icon_url": descriptor.icon_url,
            "status": "empty",
            "error": None,
            "total": 0,
            "has_more": False,
            "items": [],
            # Recorded reachability, so the screen can label a source that has
            # been failing for weeks differently from one that failed just now.
            "health": health.payload(),
        }
        if outcome is None:
            return group, 0.0
        if isinstance(outcome, BaseException):
            group["status"] = "error"
            group["error"] = _search_error_message(outcome)
            logger.warning(
                "federated_search source=%s query=%r failed: %r", source_id, query_norm, outcome
            )
            return group, 0.0

        scored: list[tuple[float, dict[str, object]]] = []
        seen: set[str] = set()
        for series in outcome.items:
            # Same row-level gate the single-source listing applies: a general
            # source that answers a query with an adult row must not become the
            # way past a gate that hides that row when browsing the same source.
            if not _row_visible(
                series, gate_open=gate_open, source_mature=descriptor.mature
            ):
                continue
            # De-dupe WITHIN one source only. The same series legitimately shows
            # up under several sources and each keeps its own row: collapsing
            # across sources is what reduced the five real Lookism hits to one.
            key = _normalize_title(series.title)
            if key in seen:
                continue
            seen.add(key)
            scored.append(
                (
                    _relevance_score(series.title, query_norm, tokens),
                    {
                        "kind": "source",
                        "source": source_id,
                        "series_id": str(series.id),
                        "title": series.title,
                        "cover_url": _absolute_url(
                            base_url,
                            f"/sources/{source_id}/series/"
                            f"{quote(str(series.id), safe='')}/cover",
                        ),
                        "author": series.author,
                        # Carried through so source-migration candidates can be
                        # compared on catalog size without an extra fetch per
                        # candidate. 0 means "the source did not say", not
                        # "empty" -- most search endpoints omit it.
                        "chapter_count": series.chapter_count,
                        "extra": None,
                    },
                )
            )

        best_score = max((score for score, _ in scored), default=0.0)
        if best_score <= 0.0 and len(scored) >= _QUERY_IGNORED_MIN_ITEMS:
            group["error"] = (
                f"Source returned {len(scored)} results unrelated to the query; ignored."
            )
            logger.info(
                "federated_search source=%s query=%r ignored the query (%d unrelated titles)",
                source_id,
                query_norm,
                len(scored),
            )
            return group, 0.0

        # Stable sort: best matches first, source order preserved within a tier.
        scored.sort(key=lambda pair: -pair[0])
        items = [item for _, item in scored]
        group["items"] = items
        group["total"] = len(items)
        group["has_more"] = bool(outcome.has_more)
        group["status"] = "ok" if items else "empty"
        return group, best_score

    async def federated_search(
        self,
        query: str,
        *,
        page: int = 1,
        per_page: int = 40,
        include_mature: bool = False,
        local_items: list[dict[str, object]] | None = None,
        local_has_more: bool = False,
        base_url: str = "",
        tier: int | None = None,
        tier_ids: list[str] | None = None,
    ) -> dict[str, object]:
        """Search the local library AND every browsable source in parallel.

        ``local_items`` are already-serialized ``kind:"local"`` hits (the caller
        owns the DB session, so it queries the library and passes them in).
        ``local_has_more`` reports whether the library query itself has further
        pages, so a local-only result set is not falsely truncated to one page.

        Results are returned twice: as ``groups`` (the library plus one group
        per source, which is what the screen renders) and as the flat ``items``
        list older clients still read. ``items`` interleaves the groups instead
        of truncating a concatenation, so no single source can consume the page.
        """
        local_items = list(local_items or [])
        normalized_query = query.strip()

        # Resolve the browsable sources the same way ``list_sources`` does,
        # honouring the caller's mature-content gate (adult sources dropped off).
        # NOTE: this path takes the gate as an argument rather than reading
        # ``self._gate_open()``, so it cannot use ``_visible_descriptors``.
        descriptors = list_installed_connectors(
            browsable_only=True,
            include_mature=include_mature,
        )
        # Split AFTER the gate, never instead of it. `descriptors` is the
        # source-level 18+ decision; restricting it can only ever shrink what a
        # caller sees, never widen it — which is why tier_ids is intersected
        # here rather than used to build the set.
        visible_total = len(descriptors)
        if tier_ids is not None:
            wanted = set(tier_ids)
            if tier == 2:
                descriptors = [
                    d for d in descriptors if d.source_type not in wanted
                ]
            else:
                descriptors = [d for d in descriptors if d.source_type in wanted]
        sources_queried = len(descriptors)
        sources_deferred = visible_total - sources_queried

        outcomes: dict[str, PaginatedSeriesList | BaseException] = {}
        if normalized_query and descriptors:
            outcomes = await self._fan_out_search(
                normalized_query,
                [descriptor.source_type for descriptor in descriptors],
                page=page,
            )

        # The fan-out already probed every source and caught every failure, so
        # it is the one place that knows whether a source is answering without
        # spending a single extra request. Recording happens BEFORE the groups
        # are built so this response reflects what it just observed -- in
        # particular, a source that recovered is un-demoted by the very search
        # that found it working.
        #
        # Off the loop: ``_merge_health`` is the only thing in this coroutine
        # that touches ``self._db``, and it ends in a COMMIT on the request's
        # synchronous Session. SQLite has a single write lock with a 5 s
        # busy_timeout, so held by a sweep or a batch of progress writes that
        # commit blocks whatever thread it is on for seconds -- and on the
        # event loop that is EVERY request in the process, not just this
        # search. The thread pool is where the app's sync endpoints already
        # take that wait.
        health = states_for(
            await to_thread.run_sync(self._merge_health, outcomes),
            [d.source_type for d in descriptors],
        )

        query_norm = _normalize_title(normalized_query)
        tokens = _query_tokens(normalized_query)
        ranked: list[tuple[float, SourceHealthState, dict[str, object]]] = []
        sources_failed = 0
        for descriptor in descriptors:
            state = health[descriptor.source_type]
            group, score = self._build_source_group(
                descriptor,
                outcomes.get(descriptor.source_type),
                base_url=base_url,
                query_norm=query_norm,
                tokens=tokens,
                health=state,
                gate_open=include_mature,
            )
            if group["status"] == "error":
                sources_failed += 1
            ranked.append((score, state, group))

        # Demotion is the FIRST sort key, ahead of relevance: a source with a
        # failure streak sinks below every source that is still answering.
        # Relevance then orders the rest as before -- most relevant first,
        # sources with nothing to show below them, ties broken by display name
        # so the order is stable.
        #
        # Demoted is not hidden. The group, its error text and its health block
        # all survive, because the owner has to be able to SEE that a source is
        # failing -- that is the whole point -- and because one success clears
        # the streak and floats it straight back up.
        #
        # In practice a demoted source contributed nothing this round anyway
        # (that is what demoted it); this key is what keeps the empty husks of
        # ~100 dead connectors below the sources that answered.
        ranked.sort(
            key=lambda entry: (
                1 if entry[1].demoted else 0,
                -entry[0],
                0 if entry[2]["items"] else 1,
                str(entry[2]["source_name"]).casefold(),
            )
        )
        source_groups = [group for _, _, group in ranked]
        sources_demoted = sum(1 for _, state, _ in ranked if state.demoted)

        local_group: dict[str, object] = {
            "source": None,
            "source_name": _LOCAL_GROUP_NAME,
            "icon_url": None,
            "status": "ok" if local_items else "empty",
            "error": None,
            "total": len(local_items),
            "has_more": bool(local_has_more),
            "items": local_items,
        }

        # Flat list: the library first (as before), then one item per source per
        # round until the page is full.
        items = local_items[:per_page]
        if len(items) < per_page:
            items = items + _round_robin(
                [group["items"] for group in source_groups],
                per_page - len(items),
            )

        total_available = len(local_items) + sum(
            len(group["items"]) for group in source_groups
        )
        has_more = (
            local_has_more
            or total_available > len(items)
            or any(group["has_more"] for group in source_groups)
        )

        logger.info(
            "federated_search query=%r sources_queried=%d sources_failed=%d "
            "sources_demoted=%d groups_with_hits=%d items=%d",
            normalized_query,
            sources_queried,
            sources_failed,
            sources_demoted,
            sum(1 for group in source_groups if group["items"]),
            len(items),
        )

        return {
            "items": items,
            "groups": [local_group, *source_groups],
            "sources_queried": sources_queried,
            "sources_failed": sources_failed,
            # How many of the queried sources are currently demoted for a
            # failure streak. Distinct from sources_failed, which counts only
            # this search's misses.
            "sources_demoted": sources_demoted,
            # What this tier did NOT ask, so a client can keep the footer
            # honest on a partial answer instead of reporting 4 of 91 as the
            # whole search.
            "sources_deferred": sources_deferred,
            "tier": tier,
            #: Non-null means "there is more to fetch"; the client asks again
            #: with this tier. Null means this response is the whole search.
            "next_tier": 2 if (tier == 1 and sources_deferred > 0) else None,
            "page": page,
            "has_more": has_more,
        }

    def get_series(self, source_id: str, series_id: str) -> dict[str, object]:
        connector = self._get_connector(source_id)
        with self._observe_traffic(source_id) as noted:
            series = connector.get_series(fully_unquote(series_id))
        if series is None:
            # The reader still gets a 404 either way; health only hears about
            # it when the None hid the source failing (a blocked series page).
            self._traffic_swallowed(source_id, noted)
            raise AppError(
                "Series not found.",
                code="series_not_found",
                status_code=404,
                details={"source_id": source_id, "series_id": series_id},
            )
        # Only once a series came back. A None above is evidence of neither:
        # "no such series" is the site answering about one page, and a soft
        # block that parses as nothing looks exactly like it.
        self._traffic_ok(source_id)
        self._require_visible_series(series, connector, source_id)
        return _serialize_series(series, source_id)

    def get_chapters(self, source_id: str, series_id: str) -> list[dict[str, object]]:
        connector = self._get_connector(source_id)
        series_id = fully_unquote(series_id)
        with self._observe_traffic(source_id) as noted:
            series = connector.get_series(series_id)
            if series is None:
                raise AppError(
                    "Series not found.",
                    code="series_not_found",
                    status_code=404,
                    details={"source_id": source_id, "series_id": series_id},
                )
            self._require_visible_series(series, connector, source_id)
            chapters = connector.get_chapters(series_id)
            if not chapters and series.chapter_count > 0:
                logger.warning(
                    "Chapters empty despite chapter_count=%d source=%s series=%s; retrying after cache bust",
                    series.chapter_count,
                    source_id,
                    series_id,
                )
                _invalidate_series_caches(connector, series_id)
                series = connector.get_series(series_id)
                if series is None:
                    raise AppError(
                        "Series not found.",
                        code="series_not_found",
                        status_code=404,
                        details={"source_id": source_id, "series_id": series_id},
                    )
                chapters = connector.get_chapters(series_id)
        # Only a list with chapters in it is the source working. An empty one
        # is the update sweep's "degraded" case -- drifted markup or a soft
        # block answering 200 -- and resetting a failure streak on it would
        # clear a blocked source every time a reader opened it. It counts as a
        # failure only when the connector swallowed the source failing to get
        # it; after a retry that worked, the list is not empty and the earlier
        # swallowed failure is rightly ignored.
        if chapters:
            self._traffic_ok(source_id)
        else:
            self._traffic_swallowed(source_id, noted)
        return [_serialize_chapter(chapter, source_id) for chapter in chapters]

    def get_chapter_pages(self, source_id: str, chapter_id: str) -> list[dict[str, object]]:
        connector = self._get_connector(source_id)
        normalized_chapter_id = _normalize_source_chapter_id(chapter_id)
        self._require_visible_chapter(source_id, normalized_chapter_id, connector)
        pages = connector.get_chapter_pages(normalized_chapter_id)
        if not pages:
            raise AppError(
                "Chapter not found.",
                code="chapter_not_found",
                status_code=404,
                details={"source_id": source_id, "chapter_id": normalized_chapter_id},
            )
        return [_serialize_page(page, source_id) for page in pages]

    def get_reader_chapter(
        self,
        source_id: str,
        series_id: str,
        chapter_id: str,
    ) -> dict[str, object]:
        connector = self._get_connector(source_id)
        normalized_chapter_id = _normalize_source_chapter_id(chapter_id)
        series_id = fully_unquote(series_id)
        # The series page and its chapter list are the same evidence here as in
        # ``get_chapters``; the page fetch below is not, since one chapter's
        # images failing says nothing about whether the site is up.
        with self._observe_traffic(source_id) as noted:
            series = connector.get_series(series_id)
            if series is None:
                raise AppError(
                    "Series not found.",
                    code="series_not_found",
                    status_code=404,
                )
            self._require_visible_series(series, connector, source_id)

            chapters = connector.get_chapters(series_id)
        if chapters:
            self._traffic_ok(source_id)
        else:
            self._traffic_swallowed(source_id, noted)
        chapter = next((item for item in chapters if item.id == normalized_chapter_id), None)
        if chapter is None:
            raise AppError(
                "Chapter not found.",
                code="chapter_not_found",
                status_code=404,
            )

        pages = connector.get_chapter_pages(normalized_chapter_id)
        chapter_index = chapters.index(chapter)
        previous_chapter_id = chapters[chapter_index - 1].id if chapter_index > 0 else None
        next_chapter_id = (
            chapters[chapter_index + 1].id if chapter_index < len(chapters) - 1 else None
        )

        return {
            "mode": "remote",
            "source_id": source_id,
            "series_id": series_id,
            "id": normalized_chapter_id,
            "title": chapter.title,
            "number": chapter.number,
            "page_count": len(pages),
            "pages": [_serialize_page(page, source_id) for page in pages],
            "previous_chapter_id": previous_chapter_id,
            "next_chapter_id": next_chapter_id,
            "series_title": series.title,
        }

    def resolve_page_image(self, source_id: str, page_id: str) -> tuple[str, bytes]:
        connector = self._get_connector(source_id)
        normalized_page_id = fully_unquote(page_id).strip()
        page = connector.find_page(normalized_page_id)
        if page is None:
            raise AppError(
                "Page not found.",
                code="page_not_found",
                status_code=404,
                details={"source_id": source_id, "page_id": page_id},
            )
        return self._fetch_remote_image(page, connector)

    def resolve_series_cover(self, source_id: str, series_id: str) -> tuple[str, bytes]:
        connector = self._get_connector(source_id)
        series = connector.get_series(fully_unquote(series_id))
        if series is None or not series.cover_url:
            raise AppError(
                "Cover not found.",
                code="cover_not_found",
                status_code=404,
            )
        # A cover is the one piece of an adult row that is explicit on its own,
        # so it is gated with the metadata rather than left reachable by key.
        self._require_visible_series(series, connector, source_id)
        return self._fetch_url(series.cover_url, connector)

    def _fetch_remote_image(self, page: Page, connector: SourceConnector) -> tuple[str, bytes]:
        if not page.remote_url:
            raise AppError(
                "Remote page URL not available.",
                code="remote_url_missing",
                status_code=404,
            )
        return self._fetch_url(page.remote_url, connector)

    def _validate_outbound_url(self, url: str, connector: SourceConnector) -> str:
        return validate_outbound_url(url, connector)

    @staticmethod
    def _too_large(url: str, max_bytes: int) -> AppError:
        return AppError(
            "Remote image exceeds the proxy size limit.",
            code="image_too_large",
            status_code=502,
            details={"url": url, "max_bytes": max_bytes},
        )

    def _fetch_url(self, url: str, connector: SourceConnector) -> tuple[str, bytes]:
        import httpx

        self._validate_outbound_url(url, connector)
        max_bytes = get_settings().image_proxy_max_bytes

        try:
            proxied = connector.fetch_proxied_image(url)
        except ConnectorHttpError as exc:
            raise AppError(
                "Failed to fetch remote image.",
                code="remote_fetch_failed",
                status_code=502,
                details={"url": url, "reason": str(exc)},
            ) from exc
        if proxied is not None:
            media_type, data = proxied
            if len(data) > max_bytes:
                raise self._too_large(url, max_bytes)
            return _safe_image_media_type(media_type), data

        try:
            # Redirects are not followed automatically: a redirect target
            # could point off the approved allowlist, silently bypassing it.
            # Connector headers (e.g. Referer) are required for CDNs that
            # enforce hotlink protection — bare GETs often return 403.
            # Streamed with a hard byte ceiling: a hostile upstream must not
            # be able to buffer an unbounded body into this process.
            with _image_stream(
                "GET",
                url,
                timeout=30.0,
                follow_redirects=False,
                headers=connector.image_fetch_headers(),
            ) as response:
                if response.is_redirect:
                    raise AppError(
                        "Remote host returned a redirect, which is not permitted.",
                        code="ssrf_blocked",
                        status_code=502,
                        details={"url": url},
                    )
                response.raise_for_status()
                declared = response.headers.get("content-length", "")
                if declared.isdigit() and int(declared) > max_bytes:
                    raise self._too_large(url, max_bytes)
                body = bytearray()
                for chunk in response.iter_bytes():
                    body.extend(chunk)
                    if len(body) > max_bytes:
                        raise self._too_large(url, max_bytes)
                media_type = response.headers.get("content-type", "image/jpeg")
        except httpx.HTTPError as exc:
            raise AppError(
                "Failed to fetch remote image.",
                code="remote_fetch_failed",
                status_code=502,
                details={"url": url, "reason": str(exc)},
            ) from exc

        return _safe_image_media_type(media_type), bytes(body)


def get_browse_service(
    db: Annotated[Session, Depends(get_db)],
    ctx: Annotated[ProfileContext, Depends(resolve_profile_context)],
) -> BrowseService:
    """Per-request browse service carrying the caller's own 18+ gate.

    This is where the source-level gate becomes per-(user, profile): every
    remote read path resolves its connector through ``_get_connector``, so
    binding the gate once here covers browse, series, chapters, pages, covers
    and the reader in one place.

    The session is carried too, for source health only (read on every listing,
    written by the search fan-out when a source's state actually changes, and by
    this reader's own series, chapter and search requests -- which is why
    ``record_traffic_health`` is on here and nowhere else).
    """
    return BrowseService(
        mature_enabled=resolve_mature_gate(db, ctx.profile_id, ctx.user_id),
        db=db,
        user_id=ctx.user_id,
        profile_id=ctx.profile_id,
        record_traffic_health=True,
    )
