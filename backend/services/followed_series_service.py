"""The per-profile library, source-native (spec §3.2, §4.2, §5.2).

A series is in a profile's library iff a ``followed_series`` row exists for
``(user_id, profile_id, source_id, series_key)``. Replaces the old
``library_service`` + ``library_intelligence_service`` catalog stack.

Everything here is scoped to the request's ``(user_id, profile_id)``. Cross
-profile visibility is none.
"""

from __future__ import annotations

import json
from typing import Annotated, Any
from urllib.parse import quote

from fastapi import Depends
from sqlalchemy import and_, func, select, tuple_
from sqlalchemy.orm import Session, defer

from connectors.ids import fully_unquote
from core.config import get_settings
from core.connector_directory import descriptor_for_source
from core.content_rating import (
    TRACKER_RATING_MATURE,
    hidden_by_gate,
    mature_tracker_case,
    rating_from_genres,
    resolve_mature_gate,
    resolve_series_rating,
    resolve_tracker_rating,
)
from core.errors import AppError
from core.profile_context import ProfileContext, resolve_profile_context
from core.time_utils import utcnow
from database.models import (
    ChapterProgress,
    Collection,
    CollectionSeries,
    FollowedSeries,
    ProfileSeriesTag,
    SourceSeriesCache,
    Tag,
)
from database.session import get_db
from services.browse_service import BrowseService, get_browse_service
from services.reading_stats_service import ReadingStatsService
from services.source_cache_service import SourceCacheService

#: Row-value ``IN`` list size. SQLite's default ``SQLITE_MAX_VARIABLE_NUMBER``
#: is 32766 on modern builds but was 999 for years, and each pair here binds
#: two parameters — chunking keeps the statement inside even the old ceiling
#: and keeps the number of distinct prepared statements small.
_IN_CHUNK = 400

READING_STATUSES = {
    "unread",
    "reading",
    "completed",
    "on_hold",
    "dropped",
    "plan_to_read",
}


def _loads(value: str | None) -> Any:
    if not value:
        return None
    try:
        return json.loads(value)
    except (ValueError, TypeError):
        return None


def _next_known_chapter(
    chapters: list[dict[str, Any]], chapter_key: str
) -> dict[str, Any] | None:
    """The chapter after ``chapter_key`` in READING order, or None.

    Reading order is by number, ascending, with unnumbered chapters after the
    numbered ones in their listing order — the same rule the web's
    ``readingOrder`` and the phone's ``sortSeriesChapters`` derive, because a
    connector that lists newest-first would otherwise make "next" mean older.
    A key the list does not carry (a stale list, a chapter the source pulled)
    yields None: the caller then leaves the series out rather than guessing.
    """
    indexed = [
        (c, i) for i, c in enumerate(chapters) if isinstance(c, dict) and c.get("key")
    ]

    def _order(item: tuple[dict[str, Any], int]) -> tuple[int, float, int]:
        number = item[0].get("number")
        if isinstance(number, (int, float)):
            return (0, float(number), item[1])
        return (1, 0.0, item[1])

    ordered = [c for c, _ in sorted(indexed, key=_order)]
    for index, chapter in enumerate(ordered):
        if chapter["key"] == chapter_key:
            return ordered[index + 1] if index + 1 < len(ordered) else None
    return None


class FollowedSeriesService:
    def __init__(
        self,
        db: Session,
        browse: BrowseService,
        *,
        user_id: int | None = None,
        profile_id: int | None = None,
    ) -> None:
        self._db = db
        self._browse = browse
        self._cache = SourceCacheService(db, browse)
        self._user_id = user_id
        self._profile_id = profile_id
        # Resolved once per request. The gate is a property of the (user,
        # profile) pair, which cannot change mid-request, and every list path
        # asked for it again per call — `statistics` alone resolved it three
        # times, each a `Session.get(ReadingProfile, ...)`.
        self._gate_cache: bool | None = None

    # --- helpers -------------------------------------------------------

    def _require_owner(self) -> None:
        if self._user_id is None:
            raise AppError(
                "Authentication is required.",
                code="auth_required",
                status_code=401,
            )

    def _scope(self, stmt):
        stmt = stmt.where(FollowedSeries.user_id == self._user_id)
        if self._profile_id is None:
            return stmt.where(FollowedSeries.profile_id.is_(None))
        return stmt.where(FollowedSeries.profile_id == self._profile_id)

    #: ``known_chapters`` holds a series' whole chapter list — kilobytes per
    #: row. The paths that scan the profile's *entire* followed set (list,
    #: statistics, recommendations, the recently-updated strip) never read it,
    #: yet SQLite still had to read every blob off disk and SQLAlchemy still
    #: had to build a Python string for each: ~5 MB of text per request for a
    #: 300-series library. Deferring it makes those statements fetch the small
    #: columns only. Any path that *does* need the array (``get_detail``,
    #: ``follow``, ``patch``) simply does not apply this option.
    _NO_CHAPTERS = (defer(FollowedSeries.known_chapters),)

    def _progress_scope(self, stmt):
        """``_scope`` for ``chapter_progress``.

        Reading position is per-``(user_id, profile_id)`` exactly like a follow
        is; a statement that filters only on ``user_id`` merges the account's
        profiles together and resumes one reader at another's page.
        """
        stmt = stmt.where(ChapterProgress.user_id == self._user_id)
        if self._profile_id is None:
            return stmt.where(ChapterProgress.profile_id.is_(None))
        return stmt.where(ChapterProgress.profile_id == self._profile_id)

    def _require_profile(self) -> int:
        """The active profile id, or a clean 400.

        Profile-owned rows key on ``(user_id, profile_id, ...)`` with a NOT NULL
        ``profile_id``, so the unscoped bucket has no row to address: a
        ``Session.get()`` with a null key component is not a lookup, and an
        insert would surface as an IntegrityError 500.
        """
        self._require_owner()
        if self._profile_id is None:
            raise AppError(
                "An active profile is required for this action.",
                code="profile_required",
                status_code=400,
            )
        return self._profile_id

    def _gate_open(self) -> bool:
        if self._gate_cache is None:
            self._gate_cache = resolve_mature_gate(
                self._db, self._profile_id, self._user_id
            )
        return self._gate_cache

    def _descriptor(self, source_id: str):
        # Was a linear scan over a freshly *rebuilt* descriptor list, run once
        # per followed row; see core.connector_directory.
        return descriptor_for_source(source_id)

    def _rating(self, row: FollowedSeries) -> str:
        return resolve_tracker_rating(row, self._descriptor(row.source_id))

    def _visible(self, rows: list[FollowedSeries]) -> list[FollowedSeries]:
        if self._gate_open():
            return rows
        return [r for r in rows if self._rating(r) != TRACKER_RATING_MATURE]

    def _get_owned(self, followed_id: int) -> FollowedSeries:
        """Fetch a follow by id, or 404.

        The profile predicate is **unconditional**: ``None`` means the unscoped
        bucket, exactly as ``_scope`` reads it. Guarding it on
        ``self._profile_id is not None`` would let a caller that simply omits
        ``X-Profile-Id`` (which ``resolve_profile_context`` leniently allows)
        read and mutate any of the account's rows across every profile.
        """
        row = self._db.get(FollowedSeries, followed_id)
        if (
            row is None
            or row.user_id != self._user_id
            or row.profile_id != self._profile_id
        ):
            raise AppError(
                "Series not found.", code="series_not_found", status_code=404
            )
        return row

    def _hidden(self, row: FollowedSeries) -> bool:
        return not self._gate_open() and self._rating(row) == TRACKER_RATING_MATURE

    def _get_visible(self, followed_id: int) -> FollowedSeries:
        """``_get_owned`` plus the 18+ gate — the row as this profile may see it.

        Every path that addresses a follow by id goes through here, reads and
        writes alike. ``patch`` and ``unfollow`` used to stop at ``_get_owned``
        and so answered for a row ``get_detail`` 404s: PATCH echoed the whole
        hidden row (title, cover, chapter list) and DELETE's 204-versus-404
        told a gated caller whether the id existed. The denial is the same
        404 the read path gives, never a 403 — the row must not exist for
        this profile on any verb.
        """
        row = self._get_owned(followed_id)
        if self._hidden(row):
            raise AppError(
                "Series not found.", code="series_not_found", status_code=404
            )
        return row

    # --- CRUD --------------------------------------------------------

    def follow(self, source_id: str, series_key: str) -> dict[str, Any]:
        self._require_profile()
        # The source gate first, and outside the try below: a source this
        # profile cannot browse (unknown, or adult while the gate is shut) is
        # refused with the same 404 browse gives. It used to be applied only
        # inside ``get_series`` — whose failure the ``except`` deliberately
        # swallows so a follow survives a source outage — so the 404 was
        # swallowed too and the row was created for a source the profile is
        # not allowed to know exists, or for one that does not exist at all.
        self._browse.ensure_visible(source_id)
        series_key = fully_unquote(series_key)
        existing = self._db.execute(
            self._scope(
                select(FollowedSeries).where(
                    FollowedSeries.source_id == source_id,
                    FollowedSeries.series_key == series_key,
                )
            )
        ).scalar_one_or_none()
        if existing is not None:
            if self._hidden(existing):
                raise AppError(
                    "Series not found.", code="series_not_found", status_code=404
                )
            return self.serialize(existing)

        # Follows are the row count the scheduled sweep walks (a live upstream
        # fetch per row, every interval), so they are capped per profile —
        # uncapped follows let one profile turn the sweep into an hours-long
        # network job for the whole instance (audit finding 14).
        max_follows = get_settings().max_follows_per_profile
        if max_follows > 0:
            count = int(
                self._db.execute(
                    self._scope(select(func.count()).select_from(FollowedSeries))
                ).scalar_one()
                or 0
            )
            if count >= max_follows:
                raise AppError(
                    "Follow limit reached for this profile.",
                    code="follow_limit_reached",
                    status_code=400,
                    details={"max_follows": max_follows},
                )

        meta: dict[str, Any] = {}
        chapters: list[dict[str, Any]] = []
        try:
            meta = self._browse.get_series(source_id, series_key)
            chapters = self._browse.get_chapters(source_id, series_key)
        except Exception:  # noqa: BLE001 - follow must work while a source is down
            meta = {}

        content_rating = rating_from_genres(tuple(meta.get("genres") or ()))
        row = FollowedSeries(
            user_id=self._user_id,
            profile_id=self._profile_id,
            source_id=source_id,
            series_key=series_key,
            title=str(meta.get("title") or series_key),
            cover_url=meta.get("cover_url"),
            content_rating=content_rating,
            known_chapters=json.dumps(
                [
                    {
                        "key": c.get("id"),
                        "number": c.get("number"),
                        "title": c.get("title"),
                        "published_at": c.get("release_date"),
                    }
                    for c in chapters
                ]
            ),
            last_checked_at=utcnow() if chapters else None,
        )
        # Resolved before the insert, on the row as it would be stored: a
        # series whose genres rate it adult is hidden from this profile the
        # moment it lands, so inserting it hands the caller a follow it can
        # neither see nor remove. Refused as not-found, like the read paths.
        if self._hidden(row):
            raise AppError(
                "Series not found.", code="series_not_found", status_code=404
            )
        self._db.add(row)
        self._db.commit()
        self._db.refresh(row)
        if meta or chapters:
            self._cache.write_through(source_id, series_key, meta, chapters)
        return self.serialize(row)

    def unfollow(self, followed_id: int) -> None:
        self._require_owner()
        row = self._get_visible(followed_id)
        self._db.delete(row)
        self._db.commit()

    def patch(self, followed_id: int, **changes: Any) -> dict[str, Any]:
        self._require_owner()
        row = self._get_visible(followed_id)
        if "is_favorite" in changes and changes["is_favorite"] is not None:
            row.is_favorite = bool(changes["is_favorite"])
        if changes.get("reading_status") is not None:
            status = str(changes["reading_status"])
            if status not in READING_STATUSES:
                raise AppError(
                    f"Unknown reading_status '{status}'.",
                    code="invalid_reading_status",
                    status_code=422,
                )
            row.reading_status = status
        if "notify" in changes and changes["notify"] is not None:
            row.notify = bool(changes["notify"])
        if "mature_override" in changes and changes["mature_override"] is not None:
            row.mature_override = bool(changes["mature_override"])
        if changes.get("sort_order") is not None:
            row.sort_order = int(changes["sort_order"])
        row.updated_at = utcnow()
        self._db.commit()
        self._db.refresh(row)
        return self.serialize(row)

    # --- reads ------------------------------------------------------

    def list_series(
        self,
        *,
        page: int = 1,
        per_page: int = 40,
        sort: str = "title",
        search: str | None = None,
        reading_status: str | None = None,
        is_favorite: bool | None = None,
        **_ignored: Any,
    ) -> dict[str, Any]:
        self._require_owner()
        stmt = self._scope(select(FollowedSeries).options(*self._NO_CHAPTERS))
        if reading_status:
            stmt = stmt.where(FollowedSeries.reading_status == reading_status)
        if is_favorite is not None:
            stmt = stmt.where(FollowedSeries.is_favorite == is_favorite)
        if search:
            stmt = stmt.where(FollowedSeries.title.ilike(f"%{search.strip()}%"))

        rows = self._visible(list(self._db.execute(stmt).scalars().all()))

        reverse = sort.startswith("-")
        key = sort.lstrip("-")
        if key in ("title", "sort_title"):
            rows.sort(key=lambda r: (r.title or "").lower(), reverse=reverse)
        elif key == "sort_order":
            rows.sort(key=lambda r: r.sort_order, reverse=reverse)
        elif key in ("updated_at", "recently_updated"):
            rows.sort(
                key=lambda r: r.last_checked_at or r.created_at, reverse=True
            )
        elif key in ("created_at", "recently_added"):
            rows.sort(key=lambda r: r.created_at, reverse=True)

        total = len(rows)
        start = (page - 1) * per_page
        window = rows[start : start + per_page]
        return {
            "items": [
                self.serialize(r, include_chapters=False) for r in window
            ],
            "total": total,
            "page": page,
            "per_page": per_page,
            "page_size": per_page,
            "has_next": start + per_page < total,
            "has_more": start + per_page < total,
            "total_pages": max(1, -(-total // per_page)),
        }

    def get_detail(self, followed_id: int) -> dict[str, Any]:
        self._require_owner()
        row = self._get_visible(followed_id)
        payload = self.serialize(row)
        try:
            meta = self._cache.get_series_meta(row.source_id, row.series_key)
            payload["description"] = meta.get("description")
            payload["author"] = meta.get("author")
            payload["genres"] = meta.get("genres")
            payload["chapters"] = meta.get("chapters")
        except Exception:  # noqa: BLE001
            payload["chapters"] = _loads(row.known_chapters) or []
        # Progress overlay — scoped to (user_id, profile_id) like everything
        # else. Filtering on user_id alone merges two profiles that follow the
        # same series into one overlay and resumes each at the other's page.
        prog = self._db.execute(
            self._progress_scope(
                select(ChapterProgress).where(
                    ChapterProgress.source_id == row.source_id,
                    ChapterProgress.series_key == row.series_key,
                )
            )
        ).scalars().all()
        payload["progress"] = {
            p.chapter_key: {
                "last_page": p.last_page,
                "is_completed": bool(p.is_completed),
            }
            for p in prog
        }
        return payload

    def continue_reading(self, limit: int = 10) -> list[dict[str, Any]]:
        """Where each followed series resumes, newest series first, for this profile.

        Two things this must not do, both of which it used to:

        * read ``chapter_progress`` filtered on ``user_id`` alone — that shows
          one profile the account's other profiles' reading positions;
        * read ``chapter_progress`` *directly* — with no ``followed_series`` row
          in the statement there is nothing to resolve a rating against, so the
          18+ gate never ran and a mature series surfaced on a gated profile's
          home strip. The inner join is therefore load-bearing, not an
          optimisation: it both restricts the strip to series this profile
          follows and supplies the row ``_rating`` resolves the gate from.

        The "one row per series" collapse happens in SQL rather than in Python.
        It used to hydrate **every** ``chapter_progress`` row in the profile —
        with its matching ``followed_series`` row, both as full ORM entities —
        and then throw all but ten away: 6,000 progress rows cost 318 ms to
        produce a ten-item strip, and the query grew with every chapter the
        owner ever opened. A window function picks the latest chapter per
        series inside the database, so the number of rows crossing into Python
        is the number of *series*, not chapters.

        The row that speaks for a series is its NEWEST one, finished or not.
        It used to be the newest *unfinished* one, and that is a rewind: the
        continuous feed completes a chapter only when its last page settles, so
        the chapters a reader scrolled through keep mid-chapter rows, and the
        moment the chapter actually being read is finished the strip fell back
        to the newest of those — "sent back 2-3 chapters" every time a session
        ended on a last page. When the newest row is completed the strip now
        goes FORWARD, to the chapter after it in ``known_chapters``; with no
        next chapter to name the series is left out, which is what it always
        was once every touched chapter was finished, and never an older one.
        """
        self._require_owner()
        # (last_read_at DESC, id DESC): the old loop kept whichever row the
        # database happened to return first within a last_read_at tie, so the
        # tiebreak is new — but it is a *defined* one replacing an arbitrary
        # one, and it matches the id ordering an insert sequence gives.
        newest_first = (ChapterProgress.last_read_at.desc(), ChapterProgress.id.desc())
        ranked = (
            self._progress_scope(
                self._scope(
                    select(
                        ChapterProgress.source_id.label("source_id"),
                        ChapterProgress.series_key.label("series_key"),
                        ChapterProgress.chapter_key.label("chapter_key"),
                        ChapterProgress.chapter_number.label("chapter_number"),
                        ChapterProgress.last_page.label("last_page"),
                        ChapterProgress.page_count.label("page_count"),
                        ChapterProgress.last_read_at.label("last_read_at"),
                        ChapterProgress.is_completed.label("is_completed"),
                        # Carried so the 18+ gate can be resolved without a
                        # second lookup; the join itself is load-bearing (it is
                        # what restricts the strip to *followed* series).
                        FollowedSeries.mature_override.label("mature_override"),
                        FollowedSeries.content_rating.label("content_rating"),
                        func.row_number()
                        .over(
                            partition_by=(
                                ChapterProgress.source_id,
                                ChapterProgress.series_key,
                            ),
                            order_by=newest_first,
                        )
                        .label("rank"),
                    ).join(
                        FollowedSeries,
                        and_(
                            FollowedSeries.user_id == ChapterProgress.user_id,
                            FollowedSeries.profile_id == ChapterProgress.profile_id,
                            FollowedSeries.source_id == ChapterProgress.source_id,
                            FollowedSeries.series_key == ChapterProgress.series_key,
                        ),
                    )
                )
            )
            .subquery()
        )

        gate_open = self._gate_open()
        # No SQL limit: a rank-1 row that is completed with nothing known after
        # it is dropped below, and a limit applied before that drop would hand
        # back a short strip while series that belong on it wait beyond the
        # cut. The row count is bounded by the profile's follow count, not by
        # its history, which is what the window function bought.
        stmt = (
            select(ranked)
            .where(ranked.c.rank == 1)
            .order_by(ranked.c.last_read_at.desc())
        )
        rows = [
            row
            for row in self._db.execute(stmt).all()
            if gate_open or self._rating(row) != TRACKER_RATING_MATURE
        ]

        # The chapter lists are fetched only for the series whose newest row is
        # finished — ``known_chapters`` is kilobytes per series and most of the
        # strip is mid-chapter, where the row itself is the answer.
        finished = [(r.source_id, r.series_key) for r in rows if r.is_completed]
        known: dict[tuple[str, str], list[dict[str, Any]]] = {}
        if finished:
            for follow in self._db.execute(
                self._scope(
                    select(FollowedSeries).where(
                        tuple_(FollowedSeries.source_id, FollowedSeries.series_key).in_(
                            finished
                        )
                    )
                )
            ).scalars():
                known[(follow.source_id, follow.series_key)] = (
                    _loads(follow.known_chapters) or []
                )

        out: list[dict[str, Any]] = []
        for row in rows:
            last_read_at = row.last_read_at.isoformat() if row.last_read_at else None
            if not row.is_completed:
                out.append(
                    {
                        "source_id": row.source_id,
                        "series_key": row.series_key,
                        "chapter_key": row.chapter_key,
                        "chapter_number": row.chapter_number,
                        "last_page": row.last_page,
                        "page_count": row.page_count,
                        "last_read_at": last_read_at,
                    }
                )
            else:
                nxt = _next_known_chapter(
                    known.get((row.source_id, row.series_key), []), row.chapter_key
                )
                if nxt is None:
                    continue
                out.append(
                    {
                        "source_id": row.source_id,
                        "series_key": row.series_key,
                        "chapter_key": nxt["key"],
                        "chapter_number": nxt.get("number"),
                        "last_page": 1,
                        "page_count": 0,
                        "last_read_at": last_read_at,
                    }
                )
            if len(out) >= limit:
                break
        return out

    def recently_updated(self, limit: int = 10) -> list[dict[str, Any]]:
        self._require_owner()
        rows = self._db.execute(
            self._scope(select(FollowedSeries).options(*self._NO_CHAPTERS))
            .where(FollowedSeries.last_checked_at.is_not(None))
            .order_by(FollowedSeries.last_checked_at.desc())
            .limit(limit)
        ).scalars().all()
        return [
            self.serialize(r, include_chapters=False)
            for r in self._visible(list(rows))
        ]

    def statistics(
        self, *, days: int = 30, tz_offset_minutes: int = 0
    ) -> dict[str, Any]:
        """Library shape + what ``reading_sessions`` actually recorded.

        The first four keys are the original payload and keep their meaning so
        clients can migrate at their own pace. Everything else comes from
        :class:`~services.reading_stats_service.ReadingStatsService`, which owns
        the session aggregation (and its own ``(user_id, profile_id)`` scoping
        and 18+ gating) rather than growing another set of scope helpers here.
        """
        self._require_owner()
        rows = self._visible(
            list(
                self._db.execute(
                    self._scope(select(FollowedSeries).options(*self._NO_CHAPTERS))
                ).scalars().all()
            )
        )
        by_status: dict[str, int] = {}
        for r in rows:
            by_status[r.reading_status] = by_status.get(r.reading_status, 0) + 1
        # Profile-scoped like every other field in this payload — counting the
        # whole account here made one profile's number jump when a sibling read.
        stats = ReadingStatsService(
            self._db,
            user_id=self._user_id,
            profile_id=self._profile_id,
            gate_open=self._gate_open(),
            tz_offset_minutes=tz_offset_minutes,
        )
        payload: dict[str, Any] = {
            "followed_total": len(rows),
            "favorites": sum(1 for r in rows if r.is_favorite),
            "by_reading_status": by_status,
            "chapters_completed": stats.chapters_completed(),
        }
        payload.update(stats.build(days))
        return payload

    def recommendations(self, limit: int = 10) -> list[dict[str, Any]]:
        """Simple genre-similarity over the followed set (spec §5.2)."""
        self._require_owner()
        rows = self._visible(
            list(
                self._db.execute(
                    self._scope(select(FollowedSeries).options(*self._NO_CHAPTERS))
                ).scalars().all()
            )
        )
        # One statement, not one per followed series. This was a
        # ``Session.get`` inside the loop — 300 follows meant 300 round trips
        # (the endpoint issued 308 queries and took 191 ms) to build a
        # ten-entry genre histogram.
        genre_counts: dict[str, int] = {}
        keys = [(r.source_id, r.series_key) for r in rows]
        for chunk_start in range(0, len(keys), _IN_CHUNK):
            chunk = keys[chunk_start : chunk_start + _IN_CHUNK]
            genre_blobs = self._db.execute(
                select(SourceSeriesCache.genres).where(
                    tuple_(
                        SourceSeriesCache.source_id, SourceSeriesCache.series_key
                    ).in_(chunk)
                )
            ).scalars().all()
            for blob in genre_blobs:
                for g in _loads(blob) or []:
                    name = str(g).lower()
                    genre_counts[name] = genre_counts.get(name, 0) + 1
        # Without an external catalog there is nothing to recommend beyond the
        # followed set; return the top genres so the client can drive a browse.
        top = sorted(genre_counts.items(), key=lambda kv: kv[1], reverse=True)
        return [{"genre": g, "weight": n} for g, n in top[:limit]]

    def taste_profile(
        self, *, max_titles: int = 16, max_genres: int = 10
    ) -> dict[str, Any]:
        """What this reader demonstrably likes — for an AI suggestion prompt.

        A follow is a weak signal. Following costs one tap and says nothing
        about whether the thing was any good; plenty of libraries are mostly
        bookmarks-with-hope. **How far somebody actually read is the strong
        one** — eight chapters in is a verdict, chapter one is a glance. So
        titles come back ordered by read depth first, and the genre histogram
        is weighted by that same depth rather than counting every follow once.
        A suggestion built on the flat follow list would be a suggestion built
        on what the reader once clicked, which is exactly the "random" answer
        this is meant to avoid.

        Chapters read in series that were never followed count too — reading
        ten chapters without tapping follow is still reading ten chapters — so
        the two are merged on the identity pair and titles for the unfollowed
        half come from the series cache.

        Returns titles, genre names and counts. **Never descriptions.**
        ``source_series_cache.description`` is text scraped from third-party
        sites, and a prompt assembled out of it is a prompt partly written by
        whoever runs those sites. Titles and genres are small, useful, and not
        a place to hide instructions.
        """
        self._require_owner()
        all_rows = list(
            self._db.execute(
                self._scope(select(FollowedSeries).options(*self._NO_CHAPTERS))
            ).scalars().all()
        )
        rows = self._visible(all_rows)
        # Every key the gate is CURRENTLY hiding from this follow list. Kept
        # separately from `rows` rather than re-derived from it below: once a
        # key is missing from `rows`, nothing left in this function can tell
        # "never followed" apart from "followed but hidden right now" without
        # this set, and the two must be judged by different rules (see below).
        hidden_keys = {(r.source_id, r.series_key) for r in all_rows} - {
            (r.source_id, r.series_key) for r in rows
        }

        # How many distinct chapters of each series this profile has a
        # position in. One grouped statement, not one per series. Ungated: a
        # reading position is not secret from its own owner, and gating it
        # here would just mean the genuinely-unfollowed branch below has to
        # re-derive it from nothing.
        depth: dict[tuple[str, str], int] = {
            (source_id, series_key): int(n)
            for source_id, series_key, n in self._db.execute(
                self._progress_scope(
                    select(
                        ChapterProgress.source_id,
                        ChapterProgress.series_key,
                        func.count().label("n"),
                    )
                ).group_by(ChapterProgress.source_id, ChapterProgress.series_key)
            ).all()
        }

        # Built once so the loop below is an O(1) lookup per key rather than
        # an O(n) scan of `rows` repeated for every key — every other bulk
        # lookup in this file was deliberately de-quadraticized the same way
        # (`_series_cache_rows` chunks its IN, `depth` above is one grouped
        # statement); a linear scan here was the one that got missed.
        rows_by_key = {(r.source_id, r.series_key): r for r in rows}
        keys = list(rows_by_key.keys() | depth.keys())
        cached = self._series_cache_rows(keys)

        gate_open = self._gate_open()
        entries: list[dict[str, Any]] = []
        for key in keys:
            if not gate_open and key in hidden_keys:
                # A series the gate is hiding RIGHT NOW, reachable here only
                # because it also has reading progress (`depth` is ungated,
                # `rows` is not, and `keys` unions both). `_visible` already
                # made the authoritative call on it -- reading
                # `mature_override` and the content_rating captured at follow
                # time, neither of which survives into a bare cache lookup --
                # so it is dropped outright rather than re-judged by a weaker
                # rule that cannot see either signal. Re-judging it here was
                # the actual leak: a series the reader hand-flagged 18+ and
                # then hid was being re-admitted as if it were merely unread.
                continue
            row = rows_by_key.get(key)
            title, genres, cache_rating = cached.get(key, ("", [], None))
            if row is not None:
                title = row.title or title
            if not title:
                # Nothing to name it by; a bare series key tells the model
                # nothing and burns prompt budget.
                continue
            if not gate_open and row is None:
                # A genuinely unfollowed read: no follow row exists at all, so
                # there is no mature_override to defer to. Judged by the same
                # rule `SuggestionService._collect` applies to shelf rows --
                # content_rating first, genres behind it -- so the two halves
                # of one prompt cannot disagree about the same series. Unknown
                # resolves to hidden: this string is about to leave the box.
                descriptor = self._descriptor(key[0])
                if descriptor is None:
                    continue
                rating = resolve_series_rating(
                    cache_rating, genres, source_mature=descriptor.mature
                )
                if hidden_by_gate(rating, gate_open=False):
                    continue
            read = depth.get(key, 0)
            entries.append(
                {
                    "title": title,
                    "genres": [str(g) for g in genres],
                    "chapters_read": read,
                    "is_favorite": bool(row is not None and row.is_favorite),
                    "followed": row is not None,
                    "status": row.reading_status if row is not None else None,
                }
            )

        def weight(entry: dict[str, Any]) -> int:
            # Read depth dominates; a favourite is worth a few chapters of
            # evidence on its own; a bare follow still counts for one.
            return (
                entry["chapters_read"] * 2
                + (6 if entry["is_favorite"] else 0)
                + (1 if entry["followed"] else 0)
            )

        entries.sort(key=lambda e: (-weight(e), e["title"].lower()))

        genre_counts: dict[str, int] = {}
        for entry in entries:
            w = max(1, weight(entry))
            for genre in entry["genres"]:
                name = genre.strip().lower()
                if name:
                    genre_counts[name] = genre_counts.get(name, 0) + w

        top_genres = sorted(
            genre_counts.items(), key=lambda kv: (-kv[1], kv[0])
        )[:max_genres]
        return {
            "genres": [{"genre": g, "weight": n} for g, n in top_genres],
            "titles": [
                {
                    "title": e["title"],
                    "chapters_read": e["chapters_read"],
                    "is_favorite": e["is_favorite"],
                }
                for e in entries[:max_titles]
            ],
            # Every title this reader has followed or read, for a caller that
            # must never suggest the same book back. The identity pair alone
            # cannot do that: `source_series_cache` is GLOBAL across every
            # connector, so one work is routinely cached under several
            # `source_id`s, and a follow on one source does not exclude the
            # identical title cached from another. Title matching is the only
            # signal that survives that.
            #
            # Includes follows the gate is hiding right now (`all_rows`, not
            # `rows`). That is safe because this set is only ever used to
            # FILTER locally and is never put in a prompt; and it is needed,
            # because otherwise a book the reader followed and marked 18+
            # could come back as a suggestion from a second source whose
            # copy of it carries no rating.
            "excluded_titles": sorted(
                {e["title"] for e in entries}
                | {r.title for r in all_rows if r.title}
            ),
            "gate_open": gate_open,
        }

    def _series_cache_rows(
        self, keys: list[tuple[str, str]]
    ) -> dict[tuple[str, str], tuple[str, list[str], str | None]]:
        """``(source_id, series_key) -> (title, genres, content_rating)``.

        Chunked row-value ``IN`` for the same reason every other bulk lookup
        here is: one statement per 400 pairs instead of one per pair.

        ``content_rating`` carries the source's OWN declared verdict when it
        has one (``source_cache_service`` writes it from the connector before
        falling back to genres) -- it is the primary signal
        ``core.content_rating.resolve_series_rating`` reads, genres are only
        the fallback. A caller that judges a cache row by genres alone is
        reading the weaker half of that rule; this is why the column is
        fetched even though ``recommendations()`` and the shelf never needed
        it before ``taste_profile`` did.
        """
        out: dict[tuple[str, str], tuple[str, list[str], str | None]] = {}
        for start in range(0, len(keys), _IN_CHUNK):
            chunk = keys[start : start + _IN_CHUNK]
            if not chunk:
                continue
            for (
                source_id,
                series_key,
                title,
                genres,
                content_rating,
            ) in self._db.execute(
                select(
                    SourceSeriesCache.source_id,
                    SourceSeriesCache.series_key,
                    SourceSeriesCache.title,
                    SourceSeriesCache.genres,
                    SourceSeriesCache.content_rating,
                ).where(
                    tuple_(
                        SourceSeriesCache.source_id, SourceSeriesCache.series_key
                    ).in_(chunk)
                )
            ).all():
                parsed = _loads(genres) or []
                out[(source_id, series_key)] = (
                    title or "",
                    [str(g) for g in parsed if str(g).strip()],
                    content_rating,
                )
        return out

    def search(self, q: str, *, page: int = 1, per_page: int = 20) -> dict[str, Any]:
        return self.list_series(search=q, page=page, per_page=per_page)

    # --- collections ----------------------------------------------

    def _collection_scope(self, stmt):
        stmt = stmt.where(Collection.user_id == self._user_id)
        if self._profile_id is None:
            return stmt.where(Collection.profile_id.is_(None))
        return stmt.where(Collection.profile_id == self._profile_id)

    def _mature_case(self):
        """1 when a collection member is 18+ for this profile, else 0.

        The rule is :func:`core.content_rating.mature_tracker_case` — the same
        one bookmarks, history and notifications resolve, so a series those
        screens hide cannot be printed by name in a collection. All this names
        is the column the source's own maturity is read from.
        """
        return mature_tracker_case(CollectionSeries.source_id)

    def _visible_members(self, stmt):
        """Restrict a ``collection_series`` statement to what the gate allows.

        A membership row carries no rating of its own — it is a bare
        ``(source_id, series_key)`` — so the rating comes from the profile's
        own follow of that pair, outer-joined on the composite key exactly as
        bookmarks and history do it. Outer, not inner: a member the profile
        never followed still has its source's maturity to answer for it and an
        inner join would silently drop every unfollowed member instead.

        Applied only when the gate is shut: an open gate filters nothing and
        should not pay for the join.
        """
        if self._gate_open():
            return stmt
        return stmt.outerjoin(
            FollowedSeries,
            and_(
                FollowedSeries.user_id == self._user_id,
                FollowedSeries.profile_id == self._profile_id,
                FollowedSeries.source_id == CollectionSeries.source_id,
                FollowedSeries.series_key == CollectionSeries.series_key,
            ),
        ).where(self._mature_case() == 0)

    def _member_counts(self, collection_ids: list[int]) -> dict[int, int]:
        """``collection_id -> visible member count``, in one statement.

        ``series_count`` used to come from ``len(row.series)``, which lazy
        -loads the whole membership relationship — one SELECT per collection,
        returning every member row, to print a number. One GROUP BY answers
        them all, and it counts through ``_visible_members`` so the number a
        gated profile is shown is the number of members it can actually open.
        """
        if not collection_ids:
            return {}
        return dict(
            self._db.execute(
                self._visible_members(
                    select(
                        CollectionSeries.collection_id, func.count()
                    )
                    .where(
                        CollectionSeries.collection_id.in_(collection_ids)
                    )
                ).group_by(CollectionSeries.collection_id)
            ).all()
        )

    def list_collections(self) -> list[dict[str, Any]]:
        self._require_owner()
        rows = self._db.execute(
            self._collection_scope(select(Collection)).order_by(Collection.sort_order)
        ).scalars().all()
        counts = self._member_counts([c.id for c in rows])
        return [
            self._serialize_collection(c, series_count=counts.get(c.id, 0))
            for c in rows
        ]

    def create_collection(
        self, *, name: str, description: str | None = None
    ) -> dict[str, Any]:
        self._require_profile()
        row = Collection(
            user_id=self._user_id,
            profile_id=self._profile_id,
            name=name.strip(),
            description=description,
        )
        self._db.add(row)
        self._db.commit()
        self._db.refresh(row)
        return self._serialize_collection(row)

    def get_collection(self, collection_id: int) -> dict[str, Any]:
        self._require_owner()
        row = self._owned_collection(collection_id)
        # Selected rather than read off ``row.series``: the relationship holds
        # every member, and the 18+ gate is a predicate the database applies
        # (``_visible_members``) against the profile's follow rows, which a
        # loaded relationship knows nothing about. It also sidesteps the stale
        # identity-map read the relationship gave here — production sessions
        # are built with ``expire_on_commit=False``, so the membership loaded
        # by ``add_series_to_collection`` for the new ``sort_order`` survived
        # its own commit and this method served the collection one write
        # behind.
        members = self._db.execute(
            self._visible_members(
                select(
                    CollectionSeries.source_id,
                    CollectionSeries.series_key,
                    CollectionSeries.sort_order,
                ).where(CollectionSeries.collection_id == collection_id)
            ).order_by(CollectionSeries.sort_order)
        ).all()
        payload = self._serialize_collection(row, series_count=len(members))
        payload["series"] = [
            {
                "source_id": m.source_id,
                "series_key": m.series_key,
                "sort_order": m.sort_order,
            }
            for m in members
        ]
        return payload

    def update_collection(self, collection_id: int, **changes: Any) -> dict[str, Any]:
        self._require_owner()
        row = self._owned_collection(collection_id)
        if changes.get("name") is not None:
            row.name = str(changes["name"]).strip()
        if "description" in changes and changes["description"] is not None:
            row.description = changes["description"]
        if changes.get("sort_order") is not None:
            row.sort_order = int(changes["sort_order"])
        self._db.commit()
        self._db.refresh(row)
        return self._serialize_collection(
            row, series_count=self._member_counts([row.id]).get(row.id, 0)
        )

    def delete_collection(self, collection_id: int) -> None:
        self._require_owner()
        self._db.delete(self._owned_collection(collection_id))
        self._db.commit()

    def add_series_to_collection(
        self, collection_id: int, source_id: str, series_key: str
    ) -> dict[str, Any]:
        self._require_owner()
        row = self._owned_collection(collection_id)
        # ``sort_order`` below is the membership count at insert time, and
        # production sessions are built with ``expire_on_commit=False``: a
        # ``series`` collection loaded by an earlier add in this same session
        # survives that add's commit, so without this the second member is
        # counted against stale membership and lands on the first one's
        # position.
        self._db.expire(row, ["series"])
        series_key = fully_unquote(series_key)
        exists = self._db.get(
            CollectionSeries, (collection_id, source_id, series_key)
        )
        if exists is None:
            self._db.add(
                CollectionSeries(
                    collection_id=collection_id,
                    source_id=source_id,
                    series_key=series_key,
                    sort_order=len(row.series),
                )
            )
            self._db.commit()
        return self.get_collection(collection_id)

    def remove_series_from_collection(
        self, collection_id: int, source_id: str, series_key: str
    ) -> None:
        self._require_owner()
        self._owned_collection(collection_id)
        # Read through the same predicate ``get_collection`` prints members
        # through, so a member the gate hides is exactly an absent one: the
        # silent no-op below, row intact. A 404 here — where a member that
        # was never added answers 204 — would be the very existence oracle
        # the gate exists to close.
        row = self._db.execute(
            self._visible_members(
                select(CollectionSeries).where(
                    CollectionSeries.collection_id == collection_id,
                    CollectionSeries.source_id == source_id,
                    CollectionSeries.series_key == fully_unquote(series_key),
                )
            )
        ).scalars().first()
        if row is not None:
            self._db.delete(row)
            self._db.commit()

    def _owned_collection(self, collection_id: int) -> Collection:
        """Fetch a collection by id, or 404.

        Collections are *created* with a ``profile_id`` and *listed* through
        ``_collection_scope``, so a sibling profile cannot see one — but with
        only the ``user_id`` check here it could still rename, empty or
        ``DELETE`` one by guessing a small integer. The predicate must match
        ``_collection_scope`` exactly, ``None`` bucket included.
        """
        row = self._db.get(Collection, collection_id)
        if (
            row is None
            or row.user_id != self._user_id
            or row.profile_id != self._profile_id
        ):
            raise AppError(
                "Collection not found.", code="not_found", status_code=404
            )
        return row

    @staticmethod
    def _serialize_collection(
        row: Collection, *, series_count: int | None = None
    ) -> dict[str, Any]:
        """``series_count`` supplied by the caller avoids the relationship load;
        omitted, it falls back to the relationship (single-collection paths,
        where the membership is usually loaded already).

        No ``cover_url``: nothing ever wrote ``Collection.cover_url``, and the
        only cover a collection could sensibly show is one of its own members',
        which a client derives from the membership without a stored column.
        """
        return {
            "id": row.id,
            "name": row.name,
            "description": row.description,
            "sort_order": row.sort_order,
            "series_count": len(row.series) if series_count is None else series_count,
        }

    # --- tags -----------------------------------------------------

    def _tag_scope(self, stmt):
        stmt = stmt.where(Tag.user_id == self._user_id)
        if self._profile_id is None:
            return stmt.where(Tag.profile_id.is_(None))
        return stmt.where(Tag.profile_id == self._profile_id)

    def _owned_tag(self, tag_id: int) -> Tag:
        row = self._db.get(Tag, tag_id)
        if (
            row is None
            or row.user_id != self._user_id
            or row.profile_id != self._profile_id
        ):
            raise AppError("Tag not found.", code="not_found", status_code=404)
        return row

    @staticmethod
    def _serialize_tag(row: Tag) -> dict[str, Any]:
        return {
            "id": row.id,
            "name": row.name,
            "category": row.category,
            "color": row.color,
        }

    def list_tags(self, *, category: str | None = None) -> list[dict[str, Any]]:
        self._require_owner()
        stmt = self._tag_scope(select(Tag))
        if category:
            stmt = stmt.where(Tag.category == category)
        rows = self._db.execute(stmt.order_by(Tag.name)).scalars().all()
        return [self._serialize_tag(t) for t in rows]

    def create_tag(
        self, *, name: str, category: str = "custom", color: str | None = None
    ) -> dict[str, Any]:
        """Create (or return) this profile's tag of that name.

        The case-insensitive dedupe is scope-local: it used to search every
        row in the table, so a colliding name handed the caller a tag belonging
        to another account — a read of somebody else's data and a write that
        then attached *their* row to *this* profile's series.
        """
        profile_id = self._require_profile()
        name = name.strip()
        existing = self._db.execute(
            self._tag_scope(select(Tag).where(func.lower(Tag.name) == name.lower()))
        ).scalar_one_or_none()
        if existing is not None:
            return self._serialize_tag(existing)
        row = Tag(
            user_id=self._user_id,
            profile_id=profile_id,
            name=name,
            category=category,
            color=color,
        )
        self._db.add(row)
        self._db.commit()
        self._db.refresh(row)
        return self._serialize_tag(row)

    def delete_tag(self, tag_id: int) -> None:
        self._require_owner()
        self._db.delete(self._owned_tag(tag_id))
        self._db.commit()

    def add_tag_to_series(
        self, source_id: str, series_key: str, tag_id: int
    ) -> dict[str, Any]:
        profile_id = self._require_profile()
        self._owned_tag(tag_id)
        series_key = fully_unquote(series_key)
        pk = (self._user_id, profile_id, source_id, series_key, tag_id)
        if self._db.get(ProfileSeriesTag, pk) is None:
            self._db.add(
                ProfileSeriesTag(
                    user_id=self._user_id,
                    profile_id=profile_id,
                    source_id=source_id,
                    series_key=series_key,
                    tag_id=tag_id,
                )
            )
            self._db.commit()
        return {"source_id": source_id, "series_key": series_key, "tag_id": tag_id}

    def remove_tag_from_series(
        self, source_id: str, series_key: str, tag_id: int
    ) -> None:
        profile_id = self._require_profile()
        row = self._db.get(
            ProfileSeriesTag,
            (self._user_id, profile_id, source_id, fully_unquote(series_key), tag_id),
        )
        if row is not None:
            self._db.delete(row)
            self._db.commit()

    # --- serialization -------------------------------------------

    def serialize(
        self, row: FollowedSeries, *, include_chapters: bool = True
    ) -> dict[str, Any]:
        """One followed series as JSON.

        ``include_chapters=False`` omits the ``known_chapters`` array while
        keeping ``chapter_count``. That array is the series' *entire* chapter
        list — 17 KB for a 200-chapter series — and the list endpoints embedded
        it once per row: one page of 40 followed series measured 832 KB, of
        which 830 KB was chapter arrays no list view draws (the web client
        declares the field and reads only ``chapter_count``; the Flutter model
        defaults it to ``const []`` when absent). The detail endpoint, follow
        and patch still send it, so nothing that had the data loses it.

        ``chapter_count`` comes from its own column, so a list page never
        loads or parses the blob at all — see ``FollowedSeries.chapter_count``
        for how the two are kept in step. (This method used to run
        ``json.loads`` over the array *twice* per row: once for the payload,
        once to measure it.)
        """
        payload: dict[str, Any] = {
            "id": row.id,
            "source_id": row.source_id,
            "series_key": row.series_key,
            "title": row.title,
            "cover_url": row.cover_url
            or f"/sources/{row.source_id}/series/{quote(row.series_key, safe='')}/cover",
            "is_favorite": bool(row.is_favorite),
            "reading_status": row.reading_status,
            "notify": bool(row.notify),
            "sort_order": row.sort_order,
            "content_rating": row.content_rating,
            "rating": self._rating(row),
            "mature_override": row.mature_override,
            "chapter_count": row.chapter_count,
            "last_checked_at": row.last_checked_at.isoformat()
            if row.last_checked_at
            else None,
            "created_at": row.created_at.isoformat() if row.created_at else None,
            "updated_at": row.updated_at.isoformat() if row.updated_at else None,
        }
        if include_chapters:
            payload["known_chapters"] = _loads(row.known_chapters) or []
        return payload


def get_followed_series_service(
    db: Annotated[Session, Depends(get_db)],
    browse: Annotated[BrowseService, Depends(get_browse_service)],
    ctx: Annotated[ProfileContext, Depends(resolve_profile_context)],
) -> FollowedSeriesService:
    return FollowedSeriesService(
        db, browse, user_id=ctx.user_id, profile_id=ctx.profile_id
    )
