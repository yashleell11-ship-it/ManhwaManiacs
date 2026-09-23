"""Map AsuraScans API payloads to normalized connector models."""

from __future__ import annotations

import html
import re
from datetime import datetime
from typing import Any

from connectors.models import Chapter, Page, PaginatedSeriesList, Series
from connectors.titles import normalize_chapter_title

API_BASE = "https://api.asurascans.com"
PAGE_SIZE = 20
PUBLIC_URL_PREFIX = "/comics/"


def public_url_to_series_id(public_url: str | None) -> str | None:
    if not public_url:
        return None
    value = public_url.strip()
    if value.startswith(PUBLIC_URL_PREFIX):
        return value[len(PUBLIC_URL_PREFIX) :]
    return value.strip("/") or None


def series_id_to_api_key(series_id: str) -> str:
    return series_id.strip().strip("/")


#: The eight hex digits Asura appends to every series slug, and changes
#: site-wide every few days: production's cache holds The Great Mage Returns
#: After 4000 Years under -53fc8424, -6f7fe6eb, -05c7df14 and -08677664, and
#: every one of them still resolves.
_SLUG_SUFFIX = re.compile(r"-[0-9a-f]{8}$")


def series_identity(series_id: str) -> str:
    """The slug without its rotating suffix: what names the SERIES.

    Only an identity to compare by, never a key to fetch with -- whether the
    bare slug resolves on the API is unknown, and the suffixed key a row was
    stored under is known to.
    """
    key = series_id_to_api_key(series_id)
    return _SLUG_SUFFIX.sub("", key) or key


def chapter_identity(chapter_id: str) -> str:
    """``series_identity`` for a ``<slug>:<number>`` chapter id."""
    parsed = parse_chapter_id(chapter_id)
    if parsed is None:
        return chapter_id
    series_id, chapter_ref = parsed
    return f"{series_identity(series_id)}:{chapter_ref}"


def make_chapter_id(series_id: str, chapter_number: int | str) -> str:
    return f"{series_id_to_api_key(series_id)}:{chapter_number}"


def parse_chapter_id(chapter_id: str) -> tuple[str, str] | None:
    if ":" not in chapter_id:
        return None
    series_id, _, chapter_ref = chapter_id.rpartition(":")
    if not series_id or not chapter_ref:
        return None
    return series_id, chapter_ref


def page_id_chapter_id(page_id: str) -> str | None:
    if ":" not in page_id:
        return None
    chapter_id, _, _page_number = page_id.rpartition(":")
    return chapter_id or None


def _strip_html(value: str | None) -> str | None:
    if not value:
        return None
    text = re.sub(r"<[^>]+>", " ", value)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text or None


def _format_date(value: str | None) -> str | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.strftime("%Y-%m-%d")
    except ValueError:
        return value


def _genre_names(item: dict[str, Any]) -> tuple[str, ...]:
    genres = item.get("genres") or []
    names: list[str] = []
    for genre in genres:
        if isinstance(genre, dict):
            name = genre.get("name")
            if isinstance(name, str) and name.strip():
                names.append(name.strip())
    return tuple(names)


def _cover_url(item: dict[str, Any]) -> str | None:
    cover = item.get("cover") or item.get("cover_url")
    if isinstance(cover, str) and cover.strip():
        return cover.strip()
    return None


def _series_id_from_item(item: dict[str, Any]) -> str:
    public_id = public_url_to_series_id(item.get("public_url"))
    if public_id:
        return public_id
    slug = str(item.get("slug") or "").strip()
    if slug:
        return slug
    return str(item.get("id") or "")


def series_item_to_series(item: dict[str, Any], *, chapter_count: int | None = None) -> Series:
    series_id = _series_id_from_item(item)
    latest_chapters = item.get("latest_chapters") or []
    latest_chapter = None
    if latest_chapters and isinstance(latest_chapters[0], dict):
        latest = latest_chapters[0]
        number = latest.get("number")
        if number is not None:
            latest_chapter = f"Chapter {number}"

    return Series(
        id=series_id,
        title=str(item.get("title") or "Untitled"),
        chapter_count=chapter_count if chapter_count is not None else int(item.get("chapter_count") or 0),
        description=_strip_html(str(item.get("description") or "")) if item.get("description") else None,
        cover_url=_cover_url(item),
        author=str(item.get("author")).strip() if item.get("author") else None,
        artist=str(item.get("artist")).strip() if item.get("artist") else None,
        status=str(item.get("status")).strip() if item.get("status") else None,
        genres=_genre_names(item),
        latest_chapter=latest_chapter or _format_date(str(item.get("last_chapter_at") or "")),
    )


def series_list_to_paginated(
    payload: dict[str, Any],
    *,
    page: int,
    page_size: int = PAGE_SIZE,
) -> PaginatedSeriesList:
    data = payload.get("data") or []
    meta = payload.get("meta") or {}
    total = int(meta.get("total") or len(data))
    per_page = int(meta.get("per_page") or page_size)
    items = [series_item_to_series(item) for item in data if isinstance(item, dict)]
    api_has_more = meta.get("has_more")
    return PaginatedSeriesList(
        items=items,
        page=page,
        page_size=per_page,
        total=total,
        api_has_more=api_has_more if isinstance(api_has_more, bool) else None,
    )


def series_detail_to_series(payload: dict[str, Any], *, chapter_count: int | None = None) -> Series | None:
    # AsuraScans' detail API is inconsistent: some series come wrapped in a
    # top-level {"data": {...}} envelope, others return the object directly.
    # Unwrap so the series object is found either way (an unhandled wrapped
    # response otherwise makes get_series() return None for those titles).
    if "series" not in payload and isinstance(payload.get("data"), dict):
        payload = payload["data"]
    series = payload.get("series")
    if not isinstance(series, dict):
        return None
    return series_item_to_series(series, chapter_count=chapter_count)


def chapter_item_to_chapter(item: dict[str, Any], *, series_id: str) -> Chapter:
    number = item.get("number")
    chapter_number = float(number) if number is not None else None
    title = normalize_chapter_title(item.get("title"))
    if not title:
        title = f"Chapter {number}" if number is not None else "Chapter"
    return Chapter(
        id=make_chapter_id(series_id, number if number is not None else item.get("slug", "")),
        series_id=series_id_to_api_key(series_id),
        title=str(title),
        number=chapter_number,
        page_count=int(item.get("page_count") or 0),
        release_date=str(item.get("published_at")) if item.get("published_at") else None,
    )


def chapter_pages_to_pages(chapter_id: str, payload: dict[str, Any]) -> list[Page]:
    data = payload.get("data") or {}
    chapter = data.get("chapter") if isinstance(data, dict) else None
    if not isinstance(chapter, dict):
        return []

    pages_data = chapter.get("pages") or []
    pages: list[Page] = []
    for index, page in enumerate(pages_data, start=1):
        if not isinstance(page, dict):
            continue
        url = page.get("url")
        if not isinstance(url, str) or not url.strip():
            continue
        pages.append(
            Page(
                id=f"{chapter_id}:{index}",
                chapter_id=chapter_id,
                number=index,
                remote_url=url.strip(),
            )
        )
    return pages
