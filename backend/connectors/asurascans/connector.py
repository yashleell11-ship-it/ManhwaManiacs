"""AsuraScans online source connector."""

from __future__ import annotations

import logging
from typing import Any
from connectors.ids import fully_unquote

from connectors.asurascans.mappers import (
    API_BASE,
    PAGE_SIZE,
    chapter_identity as _chapter_identity,
    chapter_item_to_chapter,
    chapter_pages_to_pages,
    page_id_chapter_id,
    parse_chapter_id,
    series_detail_to_series,
    series_id_to_api_key,
    series_identity as _series_identity,
    series_item_to_series,
    series_list_to_paginated,
)
from connectors.base import SourceConnector
from connectors.http.cache import TTLCache
from connectors.http.client import ConnectorHttpError, SyncConnectorHttpClient
from connectors.models import BrowseMode, Chapter, Page, PaginatedSeriesList, Series

logger = logging.getLogger(__name__)


class AsuraScansConnector(SourceConnector):
    """Browse and read manhwa/manhua from AsuraScans."""

    SOURCE_TYPE = "asurascans"
    DISPLAY_NAME = "AsuraScans"
    DESCRIPTION = (
        "Browse and read manhwa and manhua from AsuraScans. "
        "Images are proxied through ManhwaManiacs for reliable local reading."
    )
    BROWSABLE = True
    SUPPORTS_IMPORT = False

    def __init__(self) -> None:
        self._http = SyncConnectorHttpClient(API_BASE)
        self._series_cache: TTLCache[Series] = TTLCache(ttl_seconds=300.0)
        self._chapter_list_cache: TTLCache[list[Chapter]] = TTLCache(ttl_seconds=180.0)
        self._page_cache: TTLCache[list[Page]] = TTLCache(ttl_seconds=600.0)

    @property
    def source_type(self) -> str:
        return self.SOURCE_TYPE

    @property
    def display_name(self) -> str:
        return self.DISPLAY_NAME

    @property
    def description(self) -> str:
        return self.DESCRIPTION

    @property
    def is_browsable(self) -> bool:
        return self.BROWSABLE

    @property
    def supports_import(self) -> bool:
        return self.SUPPORTS_IMPORT

    @property
    def allowed_image_hosts(self) -> frozenset[str]:
        return frozenset({"asurascans.com", "asuracomic.net"})

    def _log_request(
        self,
        operation: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        status: str,
        parsed_id: str | None = None,
        detail: str | None = None,
    ) -> None:
        message = (
            f"AsuraScans {operation} {API_BASE}{path} "
            f"params={params or {}} status={status}"
        )
        if parsed_id is not None:
            message += f" parsed_id={parsed_id}"
        if detail:
            message += f" detail={detail}"
        logger.info(message)

    def list_browse_modes(self) -> list[BrowseMode]:
        return [
            BrowseMode(id="default", label="All"),
            BrowseMode(id="popular", label="Popular"),
            BrowseMode(id="updated", label="Recently Updated"),
            BrowseMode(id="latest", label="Latest"),
            BrowseMode(id="trending", label="Trending"),
            BrowseMode(id="rating", label="Top Rated"),
        ]

    def _series_params(
        self,
        *,
        page: int,
        search: str | None = None,
        sort: str | None = None,
    ) -> dict[str, Any]:
        # AsuraScans ignores `page`; pagination uses offset/limit.
        safe_page = max(page, 1)
        params: dict[str, Any] = {
            "limit": PAGE_SIZE,
            "offset": (safe_page - 1) * PAGE_SIZE,
        }
        if search:
            params["search"] = search
        if sort and sort != "default":
            params["sort"] = sort
        return params

    def _normalize_series_id(self, series_id: str) -> str:
        return series_id_to_api_key(fully_unquote(series_id))

    # Asura rotates the suffix on every slug (see ``mappers._SLUG_SUFFIX``),
    # and the old slug keeps resolving. So one series reaches readers under
    # several keys, and a follow made under last week's key must still be
    # recognised from this week's. Keys stay what they are -- rows already
    # stored under old suffixes keep working, and are still fetched with --
    # and only the question "same series?" goes through these.

    def series_identity(self, series_key: str) -> str:
        return _series_identity(fully_unquote(series_key))

    def chapter_identity(self, chapter_key: str) -> str:
        return _chapter_identity(fully_unquote(chapter_key))

    def get_series_list(self, page: int, *, sort: str | None = None) -> PaginatedSeriesList:
        if page < 1:
            page = 1
        path = "/api/series"
        params = self._series_params(page=page, sort=sort)
        try:
            payload = self._http.get_json(path, params=params)
        except ConnectorHttpError as exc:
            self._log_request("browse", path, params=params, status="error", detail=str(exc))
            raise
        listing = series_list_to_paginated(payload, page=page, page_size=PAGE_SIZE)
        sample_id = listing.items[0].id if listing.items else None
        self._log_request(
            "browse",
            path,
            params=params,
            status="ok",
            parsed_id=sample_id,
            detail=(
                f"page={page} count={len(listing.items)} total={listing.total} "
                f"has_more={listing.has_more}"
            ),
        )
        return listing

    def search_series(self, query: str, page: int, *, sort: str | None = None) -> PaginatedSeriesList:
        if page < 1:
            page = 1
        normalized = query.strip()
        if not normalized:
            return self.get_series_list(page, sort=sort)
        path = "/api/series"
        params = self._series_params(page=page, search=normalized, sort=sort)
        try:
            payload = self._http.get_json(path, params=params)
        except ConnectorHttpError as exc:
            self._log_request("search", path, params=params, status="error", detail=str(exc))
            raise
        listing = series_list_to_paginated(payload, page=page, page_size=PAGE_SIZE)
        sample_id = listing.items[0].id if listing.items else None
        self._log_request(
            "search",
            path,
            params=params,
            status="ok",
            parsed_id=sample_id,
            detail=(
                f"page={page} count={len(listing.items)} total={listing.total} "
                f"has_more={listing.has_more} query={normalized!r}"
            ),
        )
        return listing

    def get_series(self, series_id: str) -> Series | None:
        api_key = self._normalize_series_id(series_id)
        cached = self._series_cache.get(api_key)
        if cached is not None:
            return cached

        path = f"/api/series/{api_key}"
        try:
            payload = self._http.get_json(path)
        except ConnectorHttpError as exc:
            self._log_request(
                "detail",
                path,
                status="error",
                parsed_id=api_key,
                detail=str(exc),
            )
            return None

        chapters = self.get_chapters(api_key)
        series = series_detail_to_series(payload, chapter_count=len(chapters))
        if series is None:
            self._log_request(
                "detail",
                path,
                status="error",
                parsed_id=api_key,
                detail="missing series object in API response",
            )
            return None

        if series.id != api_key:
            series = Series(
                id=api_key,
                title=series.title,
                chapter_count=series.chapter_count,
                canonical_path=series.canonical_path,
                description=series.description,
                cover_url=series.cover_url,
                author=series.author,
                artist=series.artist,
                status=series.status,
                genres=series.genres,
                latest_chapter=series.latest_chapter,
            )

        self._log_request(
            "detail",
            path,
            status="ok",
            parsed_id=series.id,
            detail=f"chapters={series.chapter_count}",
        )
        self._series_cache.set(api_key, series)
        return series

    def get_chapters(self, series_id: str) -> list[Chapter]:
        api_key = self._normalize_series_id(series_id)
        cached = self._chapter_list_cache.get(api_key)
        if cached is not None:
            return cached

        chapters = self._fetch_chapters(api_key)
        if chapters:
            self._chapter_list_cache.set(api_key, chapters)
        return chapters

    def _fetch_chapters(self, series_id: str) -> list[Chapter]:
        path = f"/api/series/{series_id}/chapters"
        try:
            payload = self._http.get_json(path)
        except ConnectorHttpError as exc:
            self._log_request(
                "chapters",
                path,
                status="error",
                parsed_id=series_id,
                detail=str(exc),
            )
            return []

        data = payload.get("data") or []
        chapters = [
            chapter_item_to_chapter(item, series_id=series_id)
            for item in data
            if isinstance(item, dict)
        ]
        chapters.sort(key=lambda chapter: chapter.number if chapter.number is not None else 0)
        self._log_request(
            "chapters",
            path,
            status="ok",
            parsed_id=series_id,
            detail=f"count={len(chapters)}",
        )
        return chapters

    def get_chapter_pages(self, chapter_id: str) -> list[Page]:
        cached = self._page_cache.get(chapter_id)
        if cached is not None:
            return cached

        pages = self._fetch_chapter_pages(chapter_id)
        if pages:
            self._page_cache.set(chapter_id, pages)
        return pages

    def _fetch_chapter_pages(self, chapter_id: str) -> list[Page]:
        parsed = parse_chapter_id(chapter_id)
        if parsed is None:
            self._log_request(
                "pages",
                "/api/series/{series}/chapters/{chapter}",
                status="error",
                parsed_id=chapter_id,
                detail="invalid chapter id format",
            )
            return []

        series_id, chapter_ref = parsed
        path = f"/api/series/{series_id}/chapters/{chapter_ref}"
        try:
            payload = self._http.get_json(path)
        except ConnectorHttpError as exc:
            self._log_request(
                "pages",
                path,
                status="error",
                parsed_id=chapter_id,
                detail=str(exc),
            )
            return []

        pages = chapter_pages_to_pages(chapter_id, payload)
        self._log_request(
            "pages",
            path,
            status="ok",
            parsed_id=chapter_id,
            detail=f"count={len(pages)}",
        )
        return pages

    def find_page(self, page_id: str) -> Page | None:
        chapter_id = page_id_chapter_id(page_id)
        if chapter_id is None:
            return None
        for page in self.get_chapter_pages(chapter_id):
            if page.id == page_id:
                return page
        return None
