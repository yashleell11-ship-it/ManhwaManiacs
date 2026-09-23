"""Client-driven OCR ingest (spec §3.9, §4.4).

The phone/browser runs OCR on downloaded pages and uploads the text here.
``chapter_ocr`` is **global** — one row per ``(source_id, series_key,
chapter_key)``, not per user: the OCR text of a chapter is a property of the
chapter (same rationale as ``source_health``). Every path that *returns*
stored text is scoped to the caller's followed series + 18+ gate, which is the
whole reason spec §3.9 calls the global row "no disclosure risk".
``ocr_search`` enforced that; ``get_chapter`` and ``coverage`` did not, and
handed any account the transcript of any chapter on any source — mature
sources included.

"Global row" describes the STORAGE, not the authorization, and the write read
it as the latter: ``ingest_chapter`` took the identity triple from the body
and upserted, with no check at all. Registration is open, so any account could
replace the transcript of any chapter of any series anyone follows — with up
to 2,000,000 characters of its own text, which the owner then reads as the
in-reader dialogue overlay and as search results, believing it to be his own
scan. The upsert destroys the real transcript rather than versioning it. The
write now runs the SAME predicate the reads do (:meth:`_may_write`), so a
contributor may only supply OCR for a series their own profile follows, and
only for a chapter of it the server has actually seen
(:meth:`OcrIngestService._require_known_chapter`) -- following is self-service,
so without that a stranger could mint transcripts under invented chapter keys
that every follower, the owner included, then got as search hits.
"""

from __future__ import annotations

import json
from typing import Annotated, Any

from fastapi import Depends
from sqlalchemy import LargeBinary, cast, func, select
from sqlalchemy.orm import Session

from connectors.ids import fully_unquote
from core.config import get_settings
from core.connector_directory import descriptor_for_source
from core.content_rating import (
    TRACKER_RATING_MATURE,
    resolve_mature_gate,
    resolve_tracker_rating,
)
from core.errors import AppError
from core.profile_context import ProfileContext, resolve_profile_context
from core.time_utils import utcnow
from database.models import ChapterOcr, FollowedSeries, SourceSeriesCache, User
from database.session import get_db
from services.browse_service import BrowseService, get_browse_service


def _word_count(text: str) -> int:
    return len(text.split())


class OcrIngestService:
    def __init__(
        self,
        db: Session,
        browse: BrowseService,
        *,
        user_id: int | None = None,
        profile_id: int | None = None,
    ) -> None:
        """``browse`` is required, not optional, so no caller can build a
        service whose reads are ungated — that was the shape of the bug."""
        self._db = db
        self._browse = browse
        self._user_id = user_id
        self._profile_id = profile_id
        # Resolved once per request: the gate is a property of the (user,
        # profile) pair and cannot change mid-request.
        self._gate_cache: bool | None = None

    # --- read scope ----------------------------------------------------

    def _gate_open(self) -> bool:
        """This caller's own 18+ gate.

        Resolved from the (user, profile) via ``resolve_mature_gate`` — the
        single resolution path. Reading ``get_settings().mature_content_enabled``
        here instead is what once made the in-app toggle inert.
        """
        if self._gate_cache is None:
            self._gate_cache = resolve_mature_gate(
                self._db, self._profile_id, self._user_id
            )
        return self._gate_cache

    def _may_read(self, source_id: str, series_key: str) -> bool:
        """Whether this ``(user_id, profile_id)`` may be shown OCR for a series.

        Two gates, both per-(user, profile), matching the two the rest of the
        read surface applies:

        * the *source* gate — ``ensure_visible`` is what every other read of a
          global table runs first (browse cache, cover cache, reader), so a
          mature source stays 404 here exactly as it is everywhere else. It
          raises rather than returning False, so the response is byte-identical
          to the one browse gives for that source.
        * the *follow* scope — ``chapter_ocr`` rows are global, so the only
          thing standing between one profile and another's contribution is
          "does this profile follow the series". ``series_key`` must already be
          unquoted: follows store it that way.

        A followed row is still hidden when the profile's gate is closed and
        the row resolves mature (``mature_override`` / captured
        ``content_rating``) — the source gate alone misses an 18+ series on a
        general source.
        """
        self._browse.ensure_visible(source_id)
        if self._user_id is None or self._profile_id is None:
            # ``followed_series.profile_id`` is NOT NULL, so an unscoped caller
            # has no library to match against; denial is the same answer a
            # lookup would give, reached without one.
            return False
        row = self._db.execute(
            select(FollowedSeries).where(
                FollowedSeries.user_id == self._user_id,
                FollowedSeries.profile_id == self._profile_id,
                FollowedSeries.source_id == source_id,
                FollowedSeries.series_key == series_key,
            )
        ).scalar_one_or_none()
        if row is None:
            return False
        if self._gate_open():
            return True
        return (
            resolve_tracker_rating(row, descriptor_for_source(source_id))
            != TRACKER_RATING_MATURE
        )

    def _may_write(self, source_id: str, series_key: str) -> bool:
        """Whether this ``(user_id, profile_id)`` may CONTRIBUTE OCR for a
        series. Deliberately the read predicate, unchanged.

        The gate a write needs here is the same question the reads ask — "is
        this series in this profile's library, and may this profile see it" —
        and running the identical function rather than a parallel one means
        the two cannot drift apart: a future tightening of the read scope is a
        tightening of the write scope for free. ``contributed_by_user_id`` was
        already being recorded, but nothing ever read it for authorization.
        """
        return self._may_read(source_id, series_key)

    def _may_replace(self, row: ChapterOcr) -> bool:
        """Whether this caller may OVERWRITE a stored transcript.

        :meth:`_may_write` says who may contribute to a series, and following
        is self-service: any account on open registration can follow the
        owner's series and pass it. The row is global and the upsert keeps no
        history, so that alone let a stranger replace the transcript the owner
        reads as his overlay and his search results. A stored transcript now
        belongs to whoever contributed it; only they, or the owner (admin),
        may replace it. A row with no recorded contributor predates the
        column being read, so it falls to the owner alone.
        """
        if self._user_id is not None and row.contributed_by_user_id == self._user_id:
            return True
        return self._is_admin()

    def ingest_chapter(
        self,
        *,
        source_id: str,
        series_key: str,
        chapter_key: str,
        pages: list[dict[str, Any]],
        language: str | None = None,
        engine: str = "unknown",
        chapter_number: float | None = None,  # noqa: ARG002 - accepted, not stored
    ) -> dict[str, Any]:
        """Upsert one chapter's OCR text. Rebuilds ``full_text`` from pages.

        An upload for an existing key **replaces** (last engine wins) unless the
        incoming ``word_count`` is 0 (spec §3.9). An upload with no words never
        creates a row either, and what is stored is bounded in bytes, per row
        and per account (:meth:`_require_stored_bytes_room`).

        404 for a series this profile does not follow (or may not see), which
        is the same answer the reads give for it — off-limits stays
        indistinguishable from absent on this route too. 404 as well for a
        chapter key the server has never seen for that series
        (:meth:`_require_known_chapter`). 409 for a chapter whose transcript
        another account contributed (:meth:`_may_replace`).
        """
        series_key = fully_unquote(series_key)
        chapter_key = fully_unquote(chapter_key)
        if not self._may_write(source_id, series_key):
            raise AppError(
                "Series not found.", code="series_not_found", status_code=404
            )
        self._require_known_chapter(source_id, series_key, chapter_key)

        normalized_pages = [
            {
                "page": int(p.get("page", i + 1)),
                "text": str(p.get("text") or ""),
                "boxes": p.get("boxes"),
            }
            for i, p in enumerate(pages)
        ]
        full_text = "\n".join(p["text"] for p in normalized_pages if p["text"]).strip()
        wc = _word_count(full_text)

        row = self._db.execute(
            select(ChapterOcr).where(
                ChapterOcr.source_id == source_id,
                ChapterOcr.series_key == series_key,
                ChapterOcr.chapter_key == chapter_key,
            )
        ).scalar_one_or_none()

        if row is not None and not self._may_replace(row):
            # A conflict, not a 404: the caller may already read this row, so
            # pretending it is absent would only make the client retry.
            raise AppError(
                "Another reader's transcript is already stored for this chapter.",
                code="ocr_transcript_taken",
                status_code=409,
            )

        if row is not None and wc == 0:
            # Never overwrite a good transcript with an empty one.
            return self._serialize(row)

        if wc == 0:
            # Nor create one. A row with no words is never a search hit and
            # has no overlay to show, so all it could ever hold is box
            # geometry -- which is exactly the payload that is free to inflate.
            raise AppError(
                "No text was found in this chapter.",
                code="ocr_transcript_empty",
                status_code=400,
            )

        # ensure_ascii=False: stored as UTF-8, so a CJK character costs its 3
        # bytes and an emoji its 4, not the 6 and 12 of \u escapes. What is
        # measured below is exactly this string, so either way the bound holds.
        page_texts = json.dumps(normalized_pages, ensure_ascii=False)
        self._require_stored_bytes_room(
            normalized_pages, page_texts, full_text, replacing=row
        )

        if row is None:
            self._require_chapter_room(source_id, series_key)
            row = ChapterOcr(
                source_id=source_id,
                series_key=series_key,
                chapter_key=chapter_key,
            )
            self._db.add(row)

        row.full_text = full_text or None
        row.page_texts = page_texts
        row.language = language or row.language
        row.engine = engine or "unknown"
        row.word_count = wc
        row.contributed_by_user_id = self._user_id
        row.updated_at = utcnow()
        self._db.commit()
        self._db.refresh(row)
        return self._serialize(row)

    def _is_admin(self) -> bool:
        if self._user_id is None:
            return False
        return bool(
            self._db.execute(
                select(User.is_admin).where(User.id == self._user_id)
            ).scalar_one_or_none()
        )

    @staticmethod
    def _chapter_keys_of(blob: str | None) -> list[str]:
        """The chapter keys in a stored chapter-list blob.

        ``followed_series.known_chapters`` and ``source_series_cache.chapters``
        both hold ``{"key": ...}`` entries; a connector's own list says
        ``id``. A malformed blob is treated as an empty list, never an error.
        """
        if not blob:
            return []
        try:
            entries = json.loads(blob)
        except ValueError:
            return []
        if not isinstance(entries, list):
            return []
        keys: list[str] = []
        for entry in entries:
            if isinstance(entry, dict):
                key = entry.get("key") or entry.get("id")
                if key:
                    keys.append(str(key))
        return keys

    def _require_known_chapter(
        self, source_id: str, series_key: str, chapter_key: str
    ) -> None:
        """Refuse OCR for a chapter the server has never seen for this series.

        Following is self-service, so the follow gate lets any account write
        to the owner's series, and ``chapter_key`` came straight from the
        body: a stranger could post ``<series>:99999`` stuffed with common
        words, and every follower -- the owner included -- got search hits
        and coverage for a chapter that does not exist.

        A key is known when it is in the caller's own follow snapshot
        (``known_chapters``, which the update sweep keeps current and which
        the caller necessarily has -- :meth:`_may_write` just found the row)
        or in the series' ``source_series_cache`` chapter list, read here
        regardless of its TTL: an expired list still names chapters that
        exist. Keys are compared fully unquoted, the form the row is stored
        under. Nothing is fetched upstream: that would cost a live source
        request per refused upload.
        """
        blobs = (
            self._db.execute(
                select(FollowedSeries.known_chapters).where(
                    FollowedSeries.user_id == self._user_id,
                    FollowedSeries.profile_id == self._profile_id,
                    FollowedSeries.source_id == source_id,
                    FollowedSeries.series_key == series_key,
                )
            ).scalar_one_or_none(),
            self._db.execute(
                select(SourceSeriesCache.chapters).where(
                    SourceSeriesCache.source_id == source_id,
                    SourceSeriesCache.series_key == series_key,
                )
            ).scalar_one_or_none(),
        )
        for blob in blobs:
            for key in self._chapter_keys_of(blob):
                if key == chapter_key or fully_unquote(key) == chapter_key:
                    return
        raise AppError(
            "Chapter not found.", code="chapter_not_found", status_code=404
        )

    @staticmethod
    def _geometry_bytes(normalized_pages: list[dict[str, Any]]) -> int:
        """Serialized size of every box MINUS its text: the geometry alone.

        Text is already bounded by the route (2,000,000 characters across page
        and box text), so this measures exactly the part nothing else does.
        """
        geometry = [
            [
                {k: v for k, v in box.items() if k != "text"}
                if isinstance(box, dict)
                else box
                for box in (p["boxes"] or [])
            ]
            for p in normalized_pages
        ]
        return len(json.dumps(geometry))

    def _require_stored_bytes_room(
        self,
        normalized_pages: list[dict[str, Any]],
        page_texts: str,
        full_text: str,
        *,
        replacing: ChapterOcr | None,
    ) -> None:
        """Bound the BYTES an upload stores, per row and per account.

        The route's model caps text characters only, and box geometry is not
        text: up to 9 floats per box, 300 boxes a page, 500 pages. With every
        page's text empty an upload passed the character cap, and each one
        wrote a ~36 MiB ``page_texts`` row -- at the rate limit's 200/hour,
        about 7 GB an hour from one account against a 14 GB free disk. So the
        geometry is measured here, after normalization, where it is exactly
        what SQLite will be handed.

        Geometry alone was not enough: a character is not a byte. Two million
        emoji were 24 MB of escaped ``page_texts`` plus 8 MB of ``full_text``
        -- a 32 MB row inside the character cap -- and the per-account ceiling
        below is dodged by registering more accounts. So the whole row is
        measured too, as the UTF-8 bytes of both columns exactly as written,
        and held to ``max_ocr_row_bytes`` whoever sends it.

        The per-account sum is what stops a stream of individually-legal
        uploads doing the same thing more slowly. A replacement is charged
        only its growth: the row it overwrites leaves the sum. The owner is
        exempt -- the ceiling is for accounts open registration hands out.
        """
        settings = get_settings()
        try:
            incoming = len(page_texts.encode("utf-8")) + len(
                full_text.encode("utf-8")
            )
        except UnicodeEncodeError:
            # A lone surrogate (``"\ud800"`` is legal JSON) cannot be stored
            # as UTF-8; refused here rather than as a 500 from the commit.
            raise AppError(
                "OCR text is not valid Unicode.",
                code="ocr_text_invalid",
                status_code=400,
            ) from None

        geometry_limit = settings.max_ocr_geometry_bytes
        if (
            geometry_limit > 0
            and self._geometry_bytes(normalized_pages) > geometry_limit
        ):
            raise AppError(
                "OCR upload carries too much box geometry to store.",
                code="ocr_payload_too_large",
                status_code=413,
                details={"max_geometry_bytes": geometry_limit},
            )

        row_limit = settings.max_ocr_row_bytes
        if row_limit > 0 and incoming > row_limit:
            raise AppError(
                "OCR upload is too large to store.",
                code="ocr_payload_too_large",
                status_code=413,
                details={"max_row_bytes": row_limit},
            )

        account_limit = settings.max_ocr_bytes_per_account
        if account_limit <= 0 or self._user_id is None or self._is_admin():
            return
        # Bytes, not characters: CAST AS BLOB makes length() count octets.
        row_bytes = func.length(
            cast(func.coalesce(ChapterOcr.page_texts, ""), LargeBinary)
        ) + func.length(cast(func.coalesce(ChapterOcr.full_text, ""), LargeBinary))
        stmt = select(func.coalesce(func.sum(row_bytes), 0)).where(
            ChapterOcr.contributed_by_user_id == self._user_id
        )
        if replacing is not None:
            stmt = stmt.where(ChapterOcr.id != replacing.id)
        used = int(self._db.execute(stmt).scalar_one() or 0)
        if used + incoming > account_limit:
            raise AppError(
                "OCR storage limit reached for this account.",
                code="ocr_storage_limit_reached",
                status_code=400,
                details={"max_bytes": account_limit},
            )

    def _require_chapter_room(self, source_id: str, series_key: str) -> None:
        """Bound how many chapters of ONE series may carry a transcript.

        Invented chapter keys are refused by :meth:`_require_known_chapter`;
        this is the backstop behind it, for a series whose known chapter list
        is itself implausibly long, since each row is worth up to the row
        ceiling. Counting uses ``ix_chapter_ocr_series``, so this is an index
        probe rather than a scan of the stored text.

        Only creates are charged — replacing an existing chapter's transcript
        adds no rows and must keep working at the cap.
        """
        limit = get_settings().max_ocr_chapters_per_series
        if limit <= 0:
            return
        count = int(
            self._db.execute(
                select(func.count())
                .select_from(ChapterOcr)
                .where(
                    ChapterOcr.source_id == source_id,
                    ChapterOcr.series_key == series_key,
                )
            ).scalar_one()
            or 0
        )
        if count >= limit:
            raise AppError(
                "OCR chapter limit reached for this series.",
                code="ocr_chapter_limit_reached",
                status_code=400,
                details={"max_chapters": limit},
            )

    def get_chapter(
        self, source_id: str, series_key: str, chapter_key: str
    ) -> dict[str, Any] | None:
        """One chapter's stored transcript, or ``None``.

        A series this profile may not see returns ``None`` exactly as an
        un-OCR'd chapter does, and the route turns both into the same 404 --
        off-limits is indistinguishable from absent. (A gated *source* 404s one
        step earlier, inside ``_may_read``, with the same body browse gives.)
        """
        series_key = fully_unquote(series_key)
        if not self._may_read(source_id, series_key):
            return None
        row = self._db.execute(
            select(ChapterOcr).where(
                ChapterOcr.source_id == source_id,
                ChapterOcr.series_key == series_key,
                ChapterOcr.chapter_key == fully_unquote(chapter_key),
            )
        ).scalar_one_or_none()
        if row is None:
            return None
        payload = self._serialize(row)
        payload["page_texts"] = json.loads(row.page_texts) if row.page_texts else []
        return payload

    def coverage(self, source_id: str, series_key: str) -> dict[str, Any]:
        """Which chapters of a series already have OCR (so the client only
        OCRs the gaps)."""
        series_key = fully_unquote(series_key)
        if not self._may_read(source_id, series_key):
            # The empty listing, not an error: same reasoning as get_chapter --
            # "you may not see this" reads as "nothing here yet". A gated
            # source never reaches here; ``_may_read`` raises browse's 404.
            return {"source_id": source_id, "series_key": series_key, "chapters": []}
        rows = self._db.execute(
            select(ChapterOcr.chapter_key, ChapterOcr.word_count).where(
                ChapterOcr.source_id == source_id,
                ChapterOcr.series_key == series_key,
            )
        ).all()
        return {
            "source_id": source_id,
            "series_key": series_key,
            "chapters": [
                {"chapter_key": k, "word_count": wc} for k, wc in rows
            ],
        }

    @staticmethod
    def _serialize(row: ChapterOcr) -> dict[str, Any]:
        return {
            "source_id": row.source_id,
            "series_key": row.series_key,
            "chapter_key": row.chapter_key,
            "language": row.language,
            "engine": row.engine,
            "word_count": row.word_count,
            "updated_at": row.updated_at.isoformat() if row.updated_at else None,
        }


def get_ocr_ingest_service(
    db: Annotated[Session, Depends(get_db)],
    browse: Annotated[BrowseService, Depends(get_browse_service)],
    ctx: Annotated[ProfileContext, Depends(resolve_profile_context)],
) -> OcrIngestService:
    # chapter_ocr is a global TABLE, but (user_id, profile_id) is the scope of
    # every operation on it — reads and the write alike. ``browse`` already
    # carries this caller's resolved 18+ gate.
    return OcrIngestService(
        db, browse, user_id=ctx.user_id, profile_id=ctx.profile_id
    )
