from __future__ import annotations

import json
from datetime import datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
    column,
    desc,
    text,
)
from sqlalchemy import event
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

from core.time_utils import utcnow


class Base(DeclarativeBase):
    pass


# ---------------------------------------------------------------------------
# Accounts / sessions / profiles  (kept unchanged — spec §3.1)
# ---------------------------------------------------------------------------


class User(Base):
    """An account. The first user created is the admin/owner (household model)."""

    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("username", name="uq_users_username"),
        # Single-admin invariant (household model): at most ONE row may have
        # is_admin=1 — the owner. The application already serializes the
        # bootstrap claim (AuthService.register, BEGIN IMMEDIATE); this partial
        # unique index is the DB-level backstop so any future lost race or new
        # code path fails loudly instead of silently minting a second owner.
        # There is deliberately no admin-promotion path in the product; if
        # co-admins ever become a feature, drop this index in that migration.
        Index(
            "uq_users_single_admin",
            "is_admin",
            unique=True,
            sqlite_where=text("is_admin = 1"),
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    username: Mapped[str] = mapped_column(String(64), nullable=False)
    email: Mapped[str | None] = mapped_column(String(255))
    display_name: Mapped[str | None] = mapped_column(String(255))
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    is_admin: Mapped[bool] = mapped_column(Integer, nullable=False, default=False)
    is_active: Mapped[bool] = mapped_column(Integer, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime)

    sessions: Mapped[list[UserSession]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class UserSession(Base):
    """An opaque bearer/cookie session. Only the SHA-256 of the token is stored;
    revocation = delete the row (per the locked auth design)."""

    __tablename__ = "sessions"
    __table_args__ = (
        UniqueConstraint("token_hash", name="uq_sessions_token_hash"),
        Index("ix_sessions_user_id", "user_id"),
        Index("ix_sessions_expires_at", "expires_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_used_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    expires_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    user_agent: Mapped[str | None] = mapped_column(String(512))
    ip_address: Mapped[str | None] = mapped_column(String(64))

    user: Mapped[User] = relationship(back_populates="sessions")


class ReadingProfile(Base):
    """A per-user reading profile (Netflix-style avatars/moods)."""

    __tablename__ = "reading_profiles"
    __table_args__ = (
        Index("ix_reading_profiles_user_sort", "user_id", "sort_order"),
        # The target of every scoped table's ``(user_id, profile_id)`` foreign
        # key. Redundant as a key -- ``id`` is already unique -- but SQLite
        # needs a UNIQUE index on exactly the referenced pair before it will
        # accept a composite reference to it.
        UniqueConstraint("user_id", "id", name="uq_reading_profiles_user_scope"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    avatar_key: Mapped[str] = mapped_column(String(64), nullable=False, default="default")
    mood: Mapped[str] = mapped_column(String(32), nullable=False, default="default")
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    mature_content_enabled: Mapped[bool] = mapped_column(
        Integer, nullable=False, default=False, server_default="0"
    )
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class BootstrapState(Base):
    """Singleton row (id=1): when the ``users`` table was first observed empty.

    An empty users table on a public host is an admin-takeover window — whoever
    registers first becomes admin. This timestamp bounds that window (see
    ``Settings.bootstrap_window_minutes``): uninvited bootstrap registration is
    only allowed while ``utcnow() - empty_since`` is inside the window.

    It lives in the database — not ``config/settings.json`` — deliberately: the
    window is a property of *this* database's contents, so the marker must
    travel with the DB file. A backup restore swaps the DB and the state
    follows; ``deploy.sh reset-accounts`` deletes the accounts and re-arms the
    window in the same transaction; and a stale marker can never leak in from a
    side file that outlived a wiped database. The row is deleted when the first
    account registers and (re)created the next time the table is observed empty.
    """

    __tablename__ = "bootstrap_state"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    empty_since: Mapped[datetime] = mapped_column(
        DateTime, nullable=False, default=utcnow
    )


class SourcePin(Base):
    """A source the user pinned to the top of the Sources screen."""

    __tablename__ = "source_pins"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "profile_id", "source_id", name="uq_source_pins_user_source"
        ),
        Index("ix_source_pins_profile_id", "profile_id"),
        Index("ix_source_pins_user_sort", "user_id", "profile_id", "sort_order"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    profile_id: Mapped[int | None] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), nullable=True
    )
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )


class SourceHealth(Base):
    """Whether a source connector is answering, one row per connector. GLOBAL."""

    __tablename__ = "source_health"
    __table_args__ = (
        UniqueConstraint("source_id", name="uq_source_health_source_id"),
        Index("ix_source_health_consecutive_failures", "consecutive_failures"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    last_ok_at: Mapped[datetime | None] = mapped_column(DateTime)
    last_error_at: Mapped[datetime | None] = mapped_column(DateTime)
    last_error: Mapped[str | None] = mapped_column(Text)
    consecutive_failures: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0
    )
    last_checked_at: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )


# ---------------------------------------------------------------------------
# Update system  (kept — spec §3.1, §4.5)
# ---------------------------------------------------------------------------


class UpdateSettings(Base):
    """Global automatic update configuration (singleton row, id=1)."""

    __tablename__ = "update_settings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    enabled: Mapped[bool] = mapped_column(Integer, nullable=False, default=True)
    check_interval_minutes: Mapped[int] = mapped_column(
        Integer, nullable=False, default=60
    )
    notify_enabled: Mapped[bool] = mapped_column(Integer, nullable=False, default=True)
    check_on_startup: Mapped[bool] = mapped_column(Integer, nullable=False, default=True)
    last_run_at: Mapped[datetime | None] = mapped_column(DateTime)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )


class UpdateRun(Base):
    """Audit log for manual and scheduled update checks."""

    __tablename__ = "update_runs"
    __table_args__ = (Index("ix_update_runs_started_at", "started_at"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    trigger: Mapped[str] = mapped_column(String(32), nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="running")
    series_checked: Mapped[int] = mapped_column(Integer, default=0)
    new_chapters_found: Mapped[int] = mapped_column(Integer, default=0)
    error: Mapped[str | None] = mapped_column(Text)
    started_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime)


# ---------------------------------------------------------------------------
# Source-native library  (spec §3.2)
# ---------------------------------------------------------------------------


class FollowedSeries(Base):
    """A series is in a profile's library iff a ``followed_series`` row exists."""

    __tablename__ = "followed_series"
    __table_args__ = (
        # ISO-2 / IL-03: ``user_id`` and ``profile_id`` were independent
        # references, so the database accepted a row owned by one account that
        # pointed at another account's profile -- a row every scoped read then
        # filters out of existence, invisible and undeletable through the app.
        # The pair is now checked as a pair.
        ForeignKeyConstraint(
            ["user_id", "profile_id"],
            ["reading_profiles.user_id", "reading_profiles.id"],
            ondelete="CASCADE",
            name="fk_followed_series_scope",
        ),
        UniqueConstraint(
            "user_id",
            "profile_id",
            "source_id",
            "series_key",
            name="uq_followed_series",
        ),
        Index("ix_followed_series_library", "user_id", "profile_id", "sort_order"),
        Index("ix_followed_series_source_id", "source_id"),
        Index(
            "ix_followed_series_favorite", "user_id", "profile_id", "is_favorite"
        ),
        # Every other index here leads with ``user_id``, so the ON DELETE
        # CASCADE from a profile delete had nothing to seek on and scanned the
        # whole table. ``content_rating`` used to carry an index of its own; it
        # is only ever projected, never a predicate, so nothing could use it.
        Index("ix_followed_series_profile_id", "profile_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), nullable=False
    )
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    series_key: Mapped[str] = mapped_column(String(512), nullable=False)
    title: Mapped[str] = mapped_column(String(512), nullable=False)
    cover_url: Mapped[str | None] = mapped_column(String(1024))
    is_favorite: Mapped[bool] = mapped_column(Integer, nullable=False, default=False)
    reading_status: Mapped[str] = mapped_column(
        String(32), nullable=False, default="reading"
    )
    notify: Mapped[bool] = mapped_column(Integer, nullable=False, default=True)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    content_rating: Mapped[str | None] = mapped_column(String(32))
    mature_override: Mapped[bool | None] = mapped_column(Integer)
    known_chapters: Mapped[str] = mapped_column(
        Text, nullable=False, default="[]", server_default="[]"
    )
    #: ``len(json.loads(known_chapters))``, denormalized.
    #:
    #: The library list endpoints print a chapter count per row and nothing
    #: else off that array, so reading the count used to mean fetching the
    #: whole blob — kilobytes per row, ~5 MB per page for a 300-series library
    #: — and running ``json.loads`` on it in Python. The count is written by
    #: the ``known_chapters`` set-listener below, so it cannot drift: there is
    #: no way to assign the array without the count following it.
    chapter_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    last_checked_at: Mapped[datetime | None] = mapped_column(DateTime)
    last_error: Mapped[str | None] = mapped_column(Text)
    migrated_from_source: Mapped[str | None] = mapped_column(String(64))
    migrated_from_series_key: Mapped[str | None] = mapped_column(String(512))
    migrated_at: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )

    notifications: Mapped[list[UpdateNotification]] = relationship(
        back_populates="followed_series", cascade="all, delete-orphan"
    )


# ---------------------------------------------------------------------------
# Reading position / history  (spec §3.3–§3.5)
# ---------------------------------------------------------------------------


class ChapterProgress(Base):
    """Source-native reading position. Per-profile."""

    __tablename__ = "chapter_progress"
    __table_args__ = (
        # ISO-2 / IL-03: ``user_id`` and ``profile_id`` were independent
        # references, so the database accepted a row owned by one account that
        # pointed at another account's profile -- a row every scoped read then
        # filters out of existence, invisible and undeletable through the app.
        # The pair is now checked as a pair.
        ForeignKeyConstraint(
            ["user_id", "profile_id"],
            ["reading_profiles.user_id", "reading_profiles.id"],
            ondelete="CASCADE",
            name="fk_chapter_progress_scope",
        ),
        UniqueConstraint(
            "user_id",
            "profile_id",
            "source_id",
            "series_key",
            "chapter_key",
            name="uq_chapter_progress",
        ),
        Index(
            "ix_chapter_progress_last_read",
            "user_id",
            "profile_id",
            "last_read_at",
        ),
        # ``continue_reading``'s window function partitions by
        # ``(source_id, series_key)`` and orders each partition by
        # ``(last_read_at DESC, id DESC)``. Stopping at ``series_key`` left
        # SQLite sorting the profile's whole progress history in a temp b-tree
        # on every home-screen paint (15.6 ms over 6k rows); carrying the sort
        # terms — in the direction the query asks for — makes the scan ordered.
        # The four-column prefix this replaces was also a strict prefix of
        # ``uq_chapter_progress``, so it never earned its keep on its own.
        Index(
            "ix_chapter_progress_series",
            "user_id",
            "profile_id",
            "source_id",
            "series_key",
            desc(column("last_read_at")),
            desc(column("id")),
        ),
        # The profile-delete cascade's seek target; see FollowedSeries.
        Index("ix_chapter_progress_profile_id", "profile_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), nullable=False
    )
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    series_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_number: Mapped[float | None] = mapped_column(Float)
    last_page: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    page_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    scroll_offset_px: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_completed: Mapped[bool] = mapped_column(Integer, nullable=False, default=False)
    started_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_read_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )
    completed_at: Mapped[datetime | None] = mapped_column(DateTime)
    time_spent_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


#: ``Bookmark.media_type`` values. The discriminator names what
#: ``anchor_index`` counts; it is stored rather than derived because deriving
#: it would mean a connector-registry lookup per row on every listing, and
#: because the reader that created the bookmark is the only thing that knows
#: for certain which surface the position came off.
BOOKMARK_MEDIA_MANGA = "manga"
BOOKMARK_MEDIA_NOVEL = "novel"
BOOKMARK_MEDIA_TYPES = frozenset({BOOKMARK_MEDIA_MANGA, BOOKMARK_MEDIA_NOVEL})


class Bookmark(Base):
    """A deliberate, user-created marker at an EXACT position in a chapter.

    Not to be confused with ``ChapterProgress``, which is an automatic,
    furthest-wins scalar. These two are merged by completely different rules
    and conflating them is the bug this table's shape exists to prevent
    (design 2026-09-05-smart-bookmarks §4, §5).

    **Position — one generic anchor, one discriminator.** Manga wants
    ``page`` + a fraction of that page's height; novels want
    ``paragraph_index`` + a fraction within that paragraph. Those are
    different *nouns* but structurally the identical triple: an integer index
    into an ordered sequence of units, a 0.0–1.0 fraction within the indexed
    unit, and the number of units the chapter had when the position was
    captured. Every operation over them — the fraction-of-chapter maths, the
    clamp-to-nearest-valid degradation, the sync merge, the serializer — is
    byte-identical between the two media, so two parallel nullable column sets
    would mean writing each of those four things twice behind an ``if``.
    ``media_type`` says which noun ``anchor_index`` denotes; the columns stay
    one set.

    ``anchor_index`` is **1-based for both media** (page 1 is the first page,
    paragraph 1 is ``paragraphs[0]``). One base for one column: the legacy
    ``page`` column it replaces was 1-based, so the migration is a straight
    copy and an old page-only row keeps meaning exactly what it meant.

    ``anchor_total`` is the unit count *at capture time* (0 = the client did
    not know). It is what turns a position into the "62% of chapter 14" the
    Bookmarks screen shows without a second round trip — and it is a snapshot,
    never authoritative: if the chapter has since changed, readers clamp.

    ``chapter_number`` is carried so a bookmark still means something after a
    source re-keys its chapters and ``chapter_key`` stops resolving.

    **Sync — client id + tombstone.** ``client_id`` is a client-generated
    opaque string (uuid4 by convention; the server never parses it) and is the
    sync identity, unique per ``(user_id, profile_id)``. A delete does not
    remove the row, it stamps ``deleted_at``: without a tombstone a stale
    device replaying its create outbox resurrects a bookmark the owner
    deleted. Tombstones are retained (this table is tiny — a few hundred rows
    per profile at most) so a device that has been offline for months still
    learns about the delete on its next ``?since=`` pull.
    """

    __tablename__ = "bookmarks"
    __table_args__ = (
        # ISO-2 / IL-03: ``user_id`` and ``profile_id`` were independent
        # references, so the database accepted a row owned by one account that
        # pointed at another account's profile -- a row every scoped read then
        # filters out of existence, invisible and undeletable through the app.
        # The pair is now checked as a pair.
        ForeignKeyConstraint(
            ["user_id", "profile_id"],
            ["reading_profiles.user_id", "reading_profiles.id"],
            ondelete="CASCADE",
            name="fk_bookmarks_scope",
        ),
        # The sync identity. Scoped to the profile, not global: a client id is
        # the profile's own namespace, so two profiles colliding on one is
        # harmless, and scoping it means the "does this id already exist?"
        # lookup that drives the whole merge is structurally incapable of
        # seeing another profile's row.
        UniqueConstraint(
            "user_id", "profile_id", "client_id", name="uq_bookmarks_client_id"
        ),
        Index("ix_bookmarks_profile_id", "profile_id"),
        Index(
            "ix_bookmarks_series",
            "user_id",
            "profile_id",
            "source_id",
            "series_key",
        ),
        # The delta-pull index: ``?since=`` walks this, and the Bookmarks
        # screen's default listing sorts on it.
        Index(
            "ix_bookmarks_updated_at",
            "user_id",
            "profile_id",
            "updated_at",
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), nullable=False
    )
    #: Client-generated, opaque, never parsed server-side. See the class docstring.
    client_id: Mapped[str] = mapped_column(String(64), nullable=False)
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    series_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_number: Mapped[float | None] = mapped_column(Float)
    media_type: Mapped[str] = mapped_column(
        String(16),
        nullable=False,
        default=BOOKMARK_MEDIA_MANGA,
        server_default=BOOKMARK_MEDIA_MANGA,
    )
    #: 1-based page (manga) or paragraph (novel) index.
    anchor_index: Mapped[int] = mapped_column(
        Integer, nullable=False, default=1, server_default="1"
    )
    #: 0.0–1.0 position WITHIN the indexed unit. A fraction, not pixels: the
    #: same chapter renders at different widths on phone and web, so
    #: ``scroll_offset_px``' device-dependence must not be repeated here.
    anchor_fraction: Mapped[float] = mapped_column(
        Float, nullable=False, default=0.0, server_default="0"
    )
    #: Units in the chapter at capture time; 0 means the client did not know.
    anchor_total: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    note: Mapped[str | None] = mapped_column(Text)
    #: Tombstone. NULL = live. Set (never unset) by a delete.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    #: Last mutation. The last-write-wins clock for the note/position, and the
    #: cursor a client's ``?since=`` delta pull walks.
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )


class ReadingSession(Base):
    """One recorded stretch of reading. Per-profile, append-only.

    Read by ``services.reading_stats_service`` (the statistics screen) and
    written by ``services.progress_service``; nothing updates a row after
    insert.
    """

    __tablename__ = "reading_sessions"
    __table_args__ = (
        # ISO-2 / IL-03: ``user_id`` and ``profile_id`` were independent
        # references, so the database accepted a row owned by one account that
        # pointed at another account's profile -- a row every scoped read then
        # filters out of existence, invisible and undeletable through the app.
        # The pair is now checked as a pair.
        ForeignKeyConstraint(
            ["user_id", "profile_id"],
            ["reading_profiles.user_id", "reading_profiles.id"],
            ondelete="CASCADE",
            name="fk_reading_sessions_scope",
        ),
        Index(
            "ix_reading_sessions_started_at",
            "user_id",
            "profile_id",
            "started_at",
        ),
        # The per-source / per-series roll-ups group by exactly this prefix,
        # and it is also the join key onto ``followed_series`` that resolves
        # the 18+ gate — without it every breakdown sorts the profile's whole
        # session history on a 2-vCPU box.
        Index(
            "ix_reading_sessions_series",
            "user_id",
            "profile_id",
            "source_id",
            "series_key",
        ),
        # The profile-delete cascade's seek target; see FollowedSeries.
        Index("ix_reading_sessions_profile_id", "profile_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), nullable=False
    )
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    series_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_number: Mapped[float | None] = mapped_column(Float)
    start_page: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    end_page: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    pages_read: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    started_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime)
    #: ``ended_at - started_at`` in whole seconds, never negative; 0 while the
    #: session is unclosed. Denormalized, and maintained by the mapper listener
    #: below so it cannot drift from the two timestamps it derives from.
    #:
    #: Every statistics roll-up sums reading time, and computing it in SQL cost
    #: two ``strftime`` parses per row per roll-up — 15 ms of the 32 ms a
    #: totals query took over 12,000 sessions, paid six times per request.
    #: Stored raw rather than capped: ``SESSION_SECONDS_CAP`` is a *reading*
    #: policy (see reading_stats_service), so it stays applied at read time and
    #: can change without a data migration.
    duration_seconds: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )


class ReadingDayStats(Base):
    """One profile's reading, rolled up to a calendar day.

    ``reading_sessions`` is append-only and never pruned, and the statistics
    screen aggregates the WHOLE of it — totals, streaks, per-hour, per-source,
    per-series — on every open. That cost grows with every chapter the owner
    ever read, on a 2-vCPU box, for a screen whose answer for any day but
    today can never change again. This table is where that settled answer
    lives: sessions are still the record of truth, and this is a derived
    summary that may be dropped and rebuilt from them at any time.

    ``day`` is TEXT, not a date: it is the ``YYYY-MM-DD`` string the roll-ups
    already group on (``strftime('%Y-%m-%d', started_at, <tz modifier>)``), so
    the key is written in the same units the reader compares in and no
    timezone conversion happens on the read path.

    Scoped ``(user_id, profile_id)`` and cascaded off the profile exactly like
    ``chapter_progress`` and ``reading_sessions``: a rollup is per-profile
    reading data, so deleting a profile must take it with them.
    """

    __tablename__ = "reading_day_stats"
    __table_args__ = (
        # The primary key leads with ``user_id``, so the profile-delete
        # cascade has nothing to seek on without this — the same gap IDX-3
        # closed on the tables this one summarises.
        Index("ix_reading_day_stats_profile_id", "profile_id"),
    )

    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"), primary_key=True
    )
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), primary_key=True
    )
    #: ``YYYY-MM-DD`` in the reader's configured timezone. See the docstring.
    day: Mapped[str] = mapped_column(String(10), primary_key=True)
    sessions: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    pages_read: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    seconds_read: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    #: Distinct ``(source_id, series_key)`` pairs touched that day. Stored
    #: rather than summed at read time: distinct counts do not add across
    #: days, so this column answers "how many series on THAT day" and nothing
    #: wider.
    series_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )


# ---------------------------------------------------------------------------
# Collections / tags  (spec §3.6–§3.7)
# ---------------------------------------------------------------------------


class Collection(Base):
    __tablename__ = "collections"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "profile_id", "name", name="uq_collections_user_name"
        ),
        Index("ix_collections_profile_id", "profile_id"),
        Index("ix_collection_sort_order", "sort_order"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    cover_url: Mapped[str | None] = mapped_column(String(1024))
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )

    series: Mapped[list[CollectionSeries]] = relationship(
        back_populates="collection", cascade="all, delete-orphan"
    )


class CollectionSeries(Base):
    __tablename__ = "collection_series"
    __table_args__ = (
        Index("ix_collection_series_series", "source_id", "series_key"),
    )

    collection_id: Mapped[int] = mapped_column(
        ForeignKey("collections.id", ondelete="CASCADE"), primary_key=True
    )
    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    series_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    added_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    collection: Mapped[Collection] = relationship(back_populates="series")


class Tag(Base):
    """A profile's own label vocabulary.

    This used to be one global row set on the theory that "a tag is a word, not
    owned data". It is not: the name is user-authored text, and sharing the rows
    meant ``DELETE /library/tags/{id}`` destroyed a row every account read (plus
    every account's associations, via the ``profile_series_tags`` cascade), and
    ``create_tag`` handed back somebody else's row on a case-insensitive name
    collision. Owned per ``(user_id, profile_id)`` like everything else, so the
    uniqueness that used to be global is now scope-local (revision
    ``0002_tags_per_profile``).
    """

    __tablename__ = "tags"
    __table_args__ = (
        UniqueConstraint("user_id", "profile_id", "name", name="uq_tags_scope_name"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    category: Mapped[str] = mapped_column(String(64), nullable=False, default="custom")
    color: Mapped[str | None] = mapped_column(String(16))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    series: Mapped[list[ProfileSeriesTag]] = relationship(
        back_populates="tag", cascade="all, delete-orphan"
    )


class ProfileSeriesTag(Base):
    __tablename__ = "profile_series_tags"
    __table_args__ = (Index("ix_profile_series_tags_tag_id", "tag_id"),)

    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"), primary_key=True
    )
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), primary_key=True
    )
    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    series_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    tag_id: Mapped[int] = mapped_column(
        ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True
    )
    is_ai_generated: Mapped[bool] = mapped_column(
        Integer, nullable=False, default=False
    )
    confidence: Mapped[float | None] = mapped_column(Float)

    tag: Mapped[Tag] = relationship(back_populates="series")


# ---------------------------------------------------------------------------
# Notifications  (spec §3.8)
# ---------------------------------------------------------------------------


class UpdateNotification(Base):
    """Notification emitted when a followed series gains new chapters."""

    __tablename__ = "update_notifications"
    __table_args__ = (
        # A chapter notifies a follow ONCE. Without this, a connector that
        # drops a chapter from its listing and lists it again — a pagination
        # hiccup, a partial parse — makes it "new" a second time and the owner
        # gets the same chapter twice, forever, once per flap. The sweep
        # should still skip keys it has already emitted (an IntegrityError at
        # the per-row commit would fail the whole run); this is the backstop
        # that makes the duplicate unrepresentable rather than merely unlikely.
        Index(
            "uq_update_notifications_chapter",
            "followed_series_id",
            "chapter_key",
            unique=True,
        ),
        # Both listings filter on the (user, profile) scope and order by
        # ``created_at`` DESC; the unread bell adds ``is_read``. There were
        # five single-column indexes and no composite, so SQLite walked
        # ``profile_id`` and sorted every notification the profile owns in a
        # temp b-tree on each call. ``is_read`` sits before ``created_at``
        # because it is an equality term, not a range.
        Index(
            "ix_update_notifications_scope_unread",
            "user_id",
            "profile_id",
            "is_read",
            "created_at",
        ),
        Index(
            "ix_update_notifications_scope_created",
            "user_id",
            "profile_id",
            "created_at",
        ),
        # The profile-delete cascade's seek target. The follow-delete cascade
        # seeks on the UNIQUE index above, which leads with
        # ``followed_series_id`` — so the single-column index that used to do
        # that job is now a strict prefix of it and is gone.
        Index("ix_update_notifications_profile_id", "profile_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    profile_id: Mapped[int] = mapped_column(
        ForeignKey("reading_profiles.id", ondelete="CASCADE"), nullable=False
    )
    followed_series_id: Mapped[int] = mapped_column(
        ForeignKey("followed_series.id", ondelete="CASCADE"), nullable=False
    )
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    series_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_title: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_number: Mapped[float | None] = mapped_column(Float)
    is_read: Mapped[bool] = mapped_column(Integer, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    followed_series: Mapped[FollowedSeries] = relationship(
        back_populates="notifications"
    )


# ---------------------------------------------------------------------------
# OCR dialogue text  (spec §3.9 — GLOBAL, one row per chapter)
# ---------------------------------------------------------------------------


class ChapterOcr(Base):
    __tablename__ = "chapter_ocr"
    __table_args__ = (
        UniqueConstraint(
            "source_id", "series_key", "chapter_key", name="uq_chapter_ocr"
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    series_key: Mapped[str] = mapped_column(String(512), nullable=False)
    chapter_key: Mapped[str] = mapped_column(String(512), nullable=False)
    full_text: Mapped[str | None] = mapped_column(Text)
    page_texts: Mapped[str | None] = mapped_column(Text)
    language: Mapped[str | None] = mapped_column(String(16))
    engine: Mapped[str] = mapped_column(String(64), nullable=False, default="unknown")
    word_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    contributed_by_user_id: Mapped[int | None] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, onupdate=utcnow
    )


# ---------------------------------------------------------------------------
# Connector metadata cache  (spec §3.10 — GLOBAL, TTL)
# ---------------------------------------------------------------------------


class SourceSeriesCache(Base):
    __tablename__ = "source_series_cache"

    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    series_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    title: Mapped[str] = mapped_column(String(512), nullable=False, default="")
    cover_url: Mapped[str | None] = mapped_column(String(1024))
    description: Mapped[str | None] = mapped_column(Text)
    author: Mapped[str | None] = mapped_column(String(255))
    artist: Mapped[str | None] = mapped_column(String(255))
    status: Mapped[str | None] = mapped_column(String(64))
    year: Mapped[int | None] = mapped_column(Integer)
    content_rating: Mapped[str | None] = mapped_column(String(32))
    genres: Mapped[str | None] = mapped_column(Text)
    chapters: Mapped[str | None] = mapped_column(Text)
    fetched_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class NovelChapterCache(Base):
    """One novel chapter's sanitized plain-text paragraphs (GLOBAL, TTL+LRU).

    Keyed by the identity triple, keys stored raw like everywhere else.
    ``paragraphs`` is a JSON array of CLEAN plain-text strings — the
    connector sanitizes before anything reaches this table, so a row is
    exactly what ``GET /novels/chapter`` serves and exactly what a future
    TTS pipeline reads (spec 2026-09-04-novels-design §3). Storing chapter
    TEXT server-side does not violate the no-chapter-bytes rule: that rule
    exists for multi-GB image libraries; a novel chapter is ~15 KB.

    Purely a cache: any row may be deleted at any time. TTL is long
    (``settings.novel_cache_ttl_minutes``, default 7 days — published text is
    immutable in practice) and expired rows are served stale when the
    connector is down, like the browse cache. Bounded by
    ``settings.novel_cache_max_rows`` with LEAST-RECENTLY-USED eviction:
    the read path bumps ``last_used_at`` (unlike the browse cache's
    oldest-``fetched_at`` sweep, because a well-read old chapter should
    outlive a once-opened new one) — hence the index.

    ``prev_key``/``next_key`` snapshot the neighbours as of the fetch; the
    novel service recomputes them from the live (cached) chapter list on
    every serve and these only answer when that list is unavailable.
    """

    __tablename__ = "novel_chapter_cache"
    __table_args__ = (
        Index("ix_novel_chapter_cache_last_used_at", "last_used_at"),
    )

    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    series_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    chapter_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    title: Mapped[str] = mapped_column(String(512), nullable=False, default="")
    chapter_number: Mapped[float | None] = mapped_column(Float)
    paragraphs: Mapped[str] = mapped_column(Text, nullable=False)
    word_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    prev_key: Mapped[str | None] = mapped_column(String(512))
    next_key: Mapped[str | None] = mapped_column(String(512))
    fetched_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_used_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class NovelChapterAttribution(Base):
    """Who speaks each quoted line of one novel chapter (GLOBAL).

    Keyed by the same identity triple as ``novel_chapter_cache``, so the
    attribution for a chapter is found by the same key its text is.

    NOT a cache table, despite sitting beside one. Its rows are re-BOUGHT from
    a paid API rather than re-fetched from a source, so dropping them costs
    money instead of bandwidth — which is why these tables are deliberately
    absent from ``core.cache_tables.CACHE_TABLES``.

    ``spans`` is a JSON array of ``{p, s, e, head, ord, cont, speaker, rule}``.
    ``speaker`` is a LABEL, not a foreign key into ``novel_series_cast``:
    resolution (label → alias → cast → voice) happens at serve time, so a
    character who only becomes identifiable at chapter 800 retroactively gets
    their voice at chapter 200 without a single row being rewritten.

    ``text_fingerprint`` is load-bearing. ``novel_chapter_cache`` is a 7-day
    LRU that REFETCHES, so the paragraphs these offsets index will eventually
    be replaced by a re-scrape that may differ by a character. A client
    compares the fingerprint and falls back to unhighlighted playback rather
    than highlighting text it cannot prove the offsets came from.
    """

    __tablename__ = "novel_chapter_attribution"
    __table_args__ = (
        Index("ix_novel_attribution_series", "source_id", "series_key"),
    )

    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    series_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    chapter_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    text_fingerprint: Mapped[str] = mapped_column(String(64), nullable=False)
    paragraph_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    style: Mapped[str] = mapped_column(String(16), nullable=False, default="none")
    spans: Mapped[str] = mapped_column(Text, nullable=False, default="[]")
    pov: Mapped[str | None] = mapped_column(Text)
    pronoun_counts: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="ok")
    model: Mapped[str | None] = mapped_column(String(64))
    prompt_tokens: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    completion_tokens: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    attributed_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class NovelSeriesCast(Base):
    """One character who may get their own voice, in one series.

    This table stores ONLY what picks a voice: a display name, a gender, a
    voice id, and the counts that decide who is a main. ``frontend/AGENTS.md``
    records that knowledge-graph / character / world / timeline extraction was
    permanently abandoned and must never be reintroduced, and a "series cast"
    is one column away from becoming exactly that. A column that would help a
    reader understand the story rather than help a renderer choose a speaker
    does not belong here.

    ``gender`` comes from accumulated pronoun counts and NEVER from the name:
    web-novel casts are transliterated, and a wrong guess is wrong in the
    listener's ear on every line that character ever speaks. ``"unknown"`` is a
    real value that routes to the narrator, not a missing one.

    ``locked`` marks an owner correction. A recast may update counts on a
    locked row but must never overwrite its gender, voice or display name.
    """

    __tablename__ = "novel_series_cast"
    __table_args__ = (
        UniqueConstraint(
            "source_id", "series_key", "normalized_name", name="uq_novel_cast_identity"
        ),
        Index("ix_novel_cast_series", "source_id", "series_key"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    source_id: Mapped[str] = mapped_column(String(64), nullable=False)
    series_key: Mapped[str] = mapped_column(String(512), nullable=False)
    display_name: Mapped[str] = mapped_column(String(128), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(128), nullable=False)
    gender: Mapped[str] = mapped_column(String(8), nullable=False, default="unknown")
    voice_id: Mapped[str | None] = mapped_column(String(64))
    line_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    chapter_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_pov: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    locked: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class NovelSeriesAlias(Base):
    """Another name the same character is called by, in one series.

    The alias is part of the PRIMARY KEY on purpose. One alias cannot point at
    two characters, and the DATABASE is what enforces it — so the failure where
    a name silently splits one character's voice in two surfaces as a
    constraint violation at write time instead of as a series that
    mysteriously reads in two voices.

    This is also what makes a correction cheap: ``"King Grey" is Arthur`` is a
    single INSERT that fixes every chapter at once, because spans store labels
    and resolve through here at serve time.
    """

    __tablename__ = "novel_series_alias"
    __table_args__ = (Index("ix_novel_alias_cast", "cast_id"),)

    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    series_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    alias_normalized: Mapped[str] = mapped_column(String(128), primary_key=True)
    alias_display: Mapped[str] = mapped_column(String(128), nullable=False)
    cast_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("novel_series_cast.id", ondelete="CASCADE"), nullable=False
    )
    locked: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class NovelSeriesCastState(Base):
    """Per-series bookkeeping for the cast.

    ``cast_version`` is bumped whenever the cast changes, so a client can tell
    that a voice assignment it cached is stale without diffing the cast itself.
    """

    __tablename__ = "novel_series_cast_state"

    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    series_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    chapters_attributed: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0
    )
    cast_version: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_recast_at: Mapped[datetime | None] = mapped_column(DateTime)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class SourceBrowseCache(Base):
    """One cached browse *page* of a source's catalog (GLOBAL, TTL).

    Keyed by everything that varies the listing: ``(source_id, sort, genre,
    page)``. ``sort`` and ``genre`` store ``""`` for "not given" so they can be
    primary-key columns (SQLite PKs are NOT NULL). Search results
    (``query=...``) are deliberately NOT cached: their key cardinality is
    unbounded and each user's queries are their own.

    ``payload`` is the serialized listing exactly as the browse endpoint
    returns it (items + pagination fields), so a cache hit is a
    ``json.loads`` away from the wire. Like ``source_series_cache`` this is
    *purely* a cache — any row may be deleted at any time — and rows are
    GLOBAL: the per-caller 18+ gate is applied on every read
    (``SourceCacheService.get_browse_page``), never assumed at write time.

    Bounded: the oldest rows by ``fetched_at`` are evicted once the table
    exceeds ``settings.browse_cache_max_rows`` (hence the index).
    """

    __tablename__ = "source_browse_cache"
    __table_args__ = (Index("ix_source_browse_cache_fetched_at", "fetched_at"),)

    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    sort: Mapped[str] = mapped_column(String(64), primary_key=True, default="")
    genre: Mapped[str] = mapped_column(String(128), primary_key=True, default="")
    page: Mapped[int] = mapped_column(Integer, primary_key=True)
    payload: Mapped[str] = mapped_column(Text, nullable=False)
    fetched_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class SourceCoverCache(Base):
    """One DOWNSCALED series cover, ready to serve (GLOBAL, TTL + LRU).

    Why this exists: covers were proxied at source resolution into thumbnail
    boxes — measured at 1.64 MB average, 6.27 MB max, ~39 MB for one 24-cover
    grid on a phone. ``GET .../cover?w=`` renders the size the client will
    actually paint; this table stops it re-rendering the same one twice on a
    2-vCPU box.

    KEY. ``(source_id, series_key, width, fmt)`` — everything the bytes depend
    on and nothing else. ``width`` is always one of
    ``image_resize.COVER_WIDTHS`` (requests snap onto that closed set), so the
    key space per series is bounded at six widths x two formats rather than
    "whatever integer a caller typed".

    NOT in the key, on purpose: ``user_id``, ``profile_id``, or the 18+ gate.
    Rows are GLOBAL, exactly like ``source_browse_cache`` — a cover is a
    property of the series, not of the reader. What is per-caller is whether
    the reader may see the SOURCE at all, and that is enforced on every single
    read by ``BrowseService.ensure_visible`` *before* this table is consulted
    (``SourceCacheService.get_series_cover``), never assumed at write time.
    Putting the gate in the key instead would be the same bug in a new place:
    it would cache a leak rather than prevent one.

    DISK. Purely a cache; any row may be deleted at any time and is rebuilt on
    the next read. Bounded by TOTAL BYTES (``settings.cover_cache_max_bytes``)
    with least-recently-used eviction, plus a per-row ceiling
    (``settings.cover_cache_max_row_bytes``) — a byte budget rather than the
    row budget the JSON caches use, because these rows are binary and vary in
    size, so a row count is a poor proxy for the thing actually being bounded.
    ``_chapter_memo`` in ``source_cache_service`` already bounds by content
    rather than entries for the same reason.

    This does NOT breach the no-chapter-images-server-side rule. That rule is
    about storing readable content — a chapter is 20-200 images and a library
    is multi-GB. These are 96-720 px thumbnails of the public cover art these
    sites put on their own listing pages, capped in aggregate at a few hundred
    MB, and a full-resolution cover (no ``?w=``) is still streamed straight
    through and never written down.

    COLUMN ORDER IS DELIBERATE: ``byte_size`` is declared before ``data`` so
    the eviction sweep's ``SUM(byte_size)`` can read each record's first page
    and stop, instead of walking every blob's overflow chain.

    NEGATIVE ENTRIES. ``resize_failed_at IS NOT NULL`` marks a row that
    records the ABSENCE of a downscale: the resize produced nothing to gain
    (the original is already smaller than the target), or nothing decodable
    (an animated cover, an HTML error page, no Pillow). Such an outcome used
    to store no row at all, so the same key went upstream on every single read
    — a full-size fetch plus a decode attempt per grid paint, for exactly the
    covers the table exists to stop re-fetching.

    How the service should read one (``SourceCacheService.get_series_cover``):

    * ``resize_failed_at IS NULL`` — an ordinary hit. ``data`` is the
      downscaled bytes; serve them and report ``width`` as the served size.
    * ``resize_failed_at IS NOT NULL`` — a negative hit. ``data`` is the
      ORIGINAL upstream bytes, byte-for-byte what the passthrough would have
      served, and the served size is ``None``: this key does not shrink, so do
      not fetch upstream and do not call ``resize_cover`` again. ``data`` is
      empty (``byte_size == 0``) only when the original exceeded
      ``cover_cache_max_row_bytes``; then there is nothing to serve from here
      and the read has to go upstream anyway.
    * ``resize_failure`` names WHY, so a future policy change can invalidate
      one class of negative entry without flushing the table. It is opaque to
      the schema; the service owns the vocabulary.

    Freshness for both kinds is ``fetched_at`` against
    ``cover_cache_ttl_minutes`` — a negative entry is a cache entry, not a
    verdict, so an expired one is re-attempted and then either promoted to a
    real downscale or re-marked with a new ``resize_failed_at``. Re-marking is
    what stops an expired unshrinkable row being pinned in the table forever
    with its ``fetched_at`` never moving.
    """

    __tablename__ = "source_cover_cache"
    __table_args__ = (
        Index("ix_source_cover_cache_last_used_at", "last_used_at"),
    )

    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    series_key: Mapped[str] = mapped_column(String(512), primary_key=True)
    width: Mapped[int] = mapped_column(Integer, primary_key=True)
    fmt: Mapped[str] = mapped_column(String(8), primary_key=True)
    media_type: Mapped[str] = mapped_column(String(32), nullable=False)
    byte_size: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    data: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    fetched_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    last_used_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    #: NULL on an ordinary row; on a negative entry, why the downscale
    #: produced nothing. See the class docstring.
    resize_failure: Mapped[str | None] = mapped_column(String(32))
    #: NULL on an ordinary row; on a negative entry, when the attempt was
    #: made. This column is the discriminator — read it, not ``resize_failure``.
    resize_failed_at: Mapped[datetime | None] = mapped_column(DateTime)


# ---------------------------------------------------------------------------
# chapter_ocr FTS5 (spec §3.12)
# ---------------------------------------------------------------------------
#
# The ``chapter_ocr_fts`` virtual table + its AI/AD/AU sync triggers are not
# ORM-mapped (SQLAlchemy has no FTS5 construct). Historically they existed only
# as raw DDL inside the Alembic baseline, so any schema built with
# ``Base.metadata.create_all()`` — every test DB, and any create_all bootstrap —
# silently lacked the OCR search index and every ``chapter_ocr_fts MATCH`` query
# raised "no such table".
#
# The ``after_create`` hook below closes that gap: create_all now emits the same
# DDL Alembic does, so both schema paths produce an identical, working index.
# ``IF NOT EXISTS`` keeps it a no-op when Alembic (or a re-run) already built it.

CHAPTER_OCR_FTS_DDL: tuple[str, ...] = (
    """
    CREATE VIRTUAL TABLE IF NOT EXISTS chapter_ocr_fts USING fts5(
        full_text,
        content = 'chapter_ocr',
        content_rowid = 'id',
        tokenize = 'unicode61 remove_diacritics 2'
    )
    """,
    """
    CREATE TRIGGER IF NOT EXISTS chapter_ocr_fts_ai AFTER INSERT ON chapter_ocr BEGIN
        INSERT INTO chapter_ocr_fts(rowid, full_text) VALUES (new.id, new.full_text);
    END
    """,
    """
    CREATE TRIGGER IF NOT EXISTS chapter_ocr_fts_ad AFTER DELETE ON chapter_ocr BEGIN
        INSERT INTO chapter_ocr_fts(chapter_ocr_fts, rowid, full_text)
        VALUES ('delete', old.id, old.full_text);
    END
    """,
    """
    CREATE TRIGGER IF NOT EXISTS chapter_ocr_fts_au AFTER UPDATE ON chapter_ocr BEGIN
        INSERT INTO chapter_ocr_fts(chapter_ocr_fts, rowid, full_text)
        VALUES ('delete', old.id, old.full_text);
        INSERT INTO chapter_ocr_fts(rowid, full_text) VALUES (new.id, new.full_text);
    END
    """,
)


@event.listens_for(FollowedSeries.known_chapters, "set")
def _sync_chapter_count(target, value, _oldvalue, _initiator) -> None:
    """Keep ``FollowedSeries.chapter_count`` in step with ``known_chapters``.

    An attribute listener rather than a discipline the writers have to
    remember: it fires on *every* assignment, the declarative constructor's
    keyword included, so ``FollowedSeries(known_chapters=...)`` in a test and
    ``row.known_chapters = ...`` in the update sweep both leave the count
    correct with no call site aware of it. There is deliberately no path that
    writes one without the other.

    A blob that is not a JSON array counts as 0 — the same thing the readers'
    ``_loads(...) or []`` fallback yields, so a corrupt row degrades to "no
    chapters" rather than failing the write.
    """
    try:
        parsed = json.loads(value) if value else []
    except (TypeError, ValueError):
        parsed = []
    target.chapter_count = len(parsed) if isinstance(parsed, list) else 0


def _session_duration(row: ReadingSession) -> int:
    """``ended_at - started_at`` in whole seconds, floored at 0.

    Unclosed sessions and clock-skewed clients (an ``ended_at`` before its
    ``started_at``) are both 0 — the same answer the SQL expression this
    column replaces gave.

    The seconds are truncated off each timestamp *before* subtracting, not off
    the difference afterwards, because that is what the replaced expression
    did: ``strftime('%s', ended_at) - strftime('%s', started_at)`` rounds both
    ends down to a whole second and then subtracts. The two disagree by one
    second whenever the fractions straddle a second boundary — 10:00:00.9 to
    10:00:01.1 is 1 second to SQLite and 0 to a plain subtraction — and
    ``utcnow()`` keeps microseconds, so every real row has fractions. Matching
    the old rounding is what makes revision 0009's backfilled history and every
    row written afterwards the same kind of number, and keeps this a pure
    speedup rather than a quiet downward revision of the owner's reading time.
    """
    if row.ended_at is None or row.started_at is None:
        return 0
    started = row.started_at.replace(microsecond=0)
    ended = row.ended_at.replace(microsecond=0)
    return max(0, int((ended - started).total_seconds()))


@event.listens_for(ReadingSession, "before_insert")
@event.listens_for(ReadingSession, "before_update")
def _sync_session_duration(_mapper, _connection, target: ReadingSession) -> None:
    """Derive ``duration_seconds`` on the way to the database.

    A mapper-level hook rather than a job for the writer, because the value
    depends on *two* columns: an attribute listener would have to guess which
    of ``started_at`` / ``ended_at`` is assigned last. Here the row is complete
    by construction, so every path that can produce a ``reading_sessions`` row
    — ``ProgressService.record_session``, the test fixtures, a future importer
    — stores the right number without knowing this column exists.
    """
    target.duration_seconds = _session_duration(target)


@event.listens_for(Base.metadata, "after_create")
def _create_chapter_ocr_fts(target, connection, **kw) -> None:  # noqa: ARG001
    """Emit the ``chapter_ocr_fts`` DDL after ``create_all`` builds the tables.

    FTS5 is SQLite-only; on any other dialect this is a no-op. The ``chapter_ocr``
    table must exist first — it always does here because it is part of the same
    metadata being created, but guard anyway for a partial ``create_all(tables=…)``.
    """
    if connection.dialect.name != "sqlite":
        return
    created = {t.name for t in kw.get("tables", target.sorted_tables)}
    if "chapter_ocr" not in created:
        return
    from sqlalchemy import text as _text

    for stmt in CHAPTER_OCR_FTS_DDL:
        connection.execute(_text(stmt))
