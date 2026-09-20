"""Alembic baseline guard (spec §3, §7).

The VPS slim-down wiped the database and collapsed ``alembic/versions/*`` to a
single baseline revision ``0001_source_native``. These tests pin that the
baseline upgrades an empty database to head with the full source-native schema
(every ORM table + the ``chapter_ocr_fts`` FTS5 virtual table and its triggers),
matches the ORM models exactly, and is idempotent.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta
from pathlib import Path

from alembic.runtime.migration import MigrationContext
from alembic.autogenerate import compare_metadata
from sqlalchemy import create_engine, inspect, text

import database.session as dbs
from database.models import Base
from database.session import run_alembic_migrations

_BASELINE = "0001_source_native"
_HEAD = "0014_narrator_voice"

# Every revision, oldest first. A new migration is added here deliberately —
# the point of the guard is that revisions arrive on purpose, not that there is
# only ever one.
_REVISIONS = [
    "0001_source_native.py",
    "0002_tags_per_profile.py",
    "0003_bootstrap_state.py",
    "0004_source_browse_cache.py",
    "0005_single_admin_guard.py",
    "0006_reading_session_stats_index.py",
    "0007_novel_chapter_cache.py",
    "0008_followed_series_chapter_count.py",
    "0009_reading_session_duration.py",
    "0010_smart_bookmarks.py",
    "0011_source_cover_cache.py",
    "0012_audit_indexes.py",
    "0013_novel_attribution.py",
    "0014_narrator_voice.py",
]

# Every ORM-mapped table the baseline must create (spec §3).
_EXPECTED_TABLES = {
    "users",
    "sessions",
    "bootstrap_state",
    "reading_profiles",
    "source_pins",
    "source_health",
    "update_settings",
    "update_runs",
    "followed_series",
    "chapter_progress",
    "bookmarks",
    "reading_sessions",
    "collections",
    "collection_series",
    "tags",
    "profile_series_tags",
    "update_notifications",
    "chapter_ocr",
    "source_series_cache",
    "source_browse_cache",
    "novel_chapter_cache",
    "source_cover_cache",
}

# Tables that must be gone (spec §3.11).
_DELETED_TABLES = {
    "libraries",
    "series",
    "chapters",
    "volumes",
    "pages",
    "downloads",
    "download_queue",
    "source_chapter_links",
    "import_history",
    "series_trackers",
    "user_series_state",
    "ocr_jobs",
    "page_texts",
    "chapter_texts",
    "reading_progress",
    "series_fts",
}


def _fresh_engine(tmp_path: Path):
    engine = create_engine(f"sqlite:///{tmp_path / 'baseline.db'}")
    run_alembic_migrations(engine)
    return engine


def test_revision_set_is_exactly_what_we_expect():
    versions_dir = Path(dbs.__file__).resolve().parents[1] / "alembic" / "versions"
    revisions = sorted(p.name for p in versions_dir.glob("*.py"))
    assert revisions == _REVISIONS, revisions


def test_migrations_upgrade_empty_db_to_full_schema(tmp_path):
    engine = _fresh_engine(tmp_path)
    tables = set(inspect(engine).get_table_names())

    missing = _EXPECTED_TABLES - tables
    assert not missing, f"baseline did not create: {missing}"

    leftover = _DELETED_TABLES & tables
    assert not leftover, f"baseline created deleted tables: {leftover}"

    # Alembic stamped a real head revision.
    with engine.connect() as conn:
        assert MigrationContext.configure(conn).get_current_revision() == _HEAD


def test_baseline_creates_chapter_ocr_fts_and_triggers(tmp_path):
    engine = _fresh_engine(tmp_path)
    with engine.connect() as conn:
        tables = {
            r[0]
            for r in conn.execute(
                text("SELECT name FROM sqlite_master WHERE type='table'")
            )
        }
        assert "chapter_ocr_fts" in tables
        triggers = {
            r[0]
            for r in conn.execute(
                text("SELECT name FROM sqlite_master WHERE type='trigger'")
            )
        }
        assert {
            "chapter_ocr_fts_ai",
            "chapter_ocr_fts_ad",
            "chapter_ocr_fts_au",
        } <= triggers

    # The FTS index actually populates from a chapter_ocr insert.
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO chapter_ocr "
                "(source_id, series_key, chapter_key, full_text, engine, word_count, "
                " created_at, updated_at) "
                "VALUES ('mangadex', 's1', 'c1', 'the dragon roared loudly', 'test', 4, "
                " '2026-01-01', '2026-01-01')"
            )
        )
    with engine.connect() as conn:
        hit = conn.execute(
            text(
                "SELECT c.chapter_key FROM chapter_ocr_fts f "
                "JOIN chapter_ocr c ON c.id = f.rowid "
                "WHERE chapter_ocr_fts MATCH 'dragon'"
            )
        ).all()
        assert [r[0] for r in hit] == ["c1"]


def test_create_all_also_builds_a_working_fts_index(db_engine):
    """The other schema path: ``Base.metadata.create_all`` (every test DB, any
    create_all bootstrap) must produce the same working ``chapter_ocr_fts`` index
    the Alembic baseline does — via the ``after_create`` hook in database.models.
    """
    with db_engine.connect() as conn:
        objects = {
            r[0]
            for r in conn.execute(
                text(
                    "SELECT name FROM sqlite_master "
                    "WHERE type IN ('table', 'trigger')"
                )
            )
        }
    assert "chapter_ocr_fts" in objects
    assert {
        "chapter_ocr_fts_ai",
        "chapter_ocr_fts_ad",
        "chapter_ocr_fts_au",
    } <= objects

    with db_engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO chapter_ocr "
                "(source_id, series_key, chapter_key, full_text, engine, "
                " word_count, created_at, updated_at) "
                "VALUES ('mangadex', 's1', 'c1', 'the phantom knight returned', "
                " 'test', 4, '2026-01-01', '2026-01-01')"
            )
        )
    with db_engine.connect() as conn:
        hit = conn.execute(
            text(
                "SELECT c.chapter_key FROM chapter_ocr_fts f "
                "JOIN chapter_ocr c ON c.id = f.rowid "
                "WHERE chapter_ocr_fts MATCH 'phantom'"
            )
        ).all()
    assert [r[0] for r in hit] == ["c1"]


def test_create_all_fts_hook_is_idempotent(db_engine):
    """A second ``create_all`` on the same engine must not fail on the FTS DDL."""
    from database.models import Base

    Base.metadata.create_all(bind=db_engine)  # would raise without IF NOT EXISTS


def test_alembic_head_matches_models(tmp_path):
    """``upgrade head`` must reproduce the ORM models exactly — a model change
    without a matching migration shows up here as a non-empty diff."""
    engine = _fresh_engine(tmp_path)
    with engine.connect() as conn:
        ctx = MigrationContext.configure(
            conn, opts={"compare_type": True, "render_as_batch": True}
        )
        diffs = compare_metadata(ctx, Base.metadata)
    # FTS virtual tables and their shadow tables are not ORM-mapped; Alembic
    # reports them as "extra". Everything else must match.
    real = [
        d
        for d in diffs
        if not (
            isinstance(d, tuple)
            and d[0] == "remove_table"
            and getattr(d[1], "name", "").startswith("chapter_ocr_fts")
        )
    ]
    assert real == [], f"ORM models drifted from the Alembic baseline: {real}"


def test_run_alembic_migrations_does_not_silence_existing_loggers(tmp_path, caplog):
    """Regression test: ``alembic/env.py`` used to call ``fileConfig(...)``
    unconditionally at import time, even when Alembic is driven
    programmatically from app startup (``database.session.run_alembic_migrations``,
    which ``init_db()`` calls). ``fileConfig``'s default
    ``disable_existing_loggers=True`` silently disables every logger that
    already exists in the process at that point — including every
    module-level ``logging.getLogger(__name__)`` logger the app's own modules
    already created at import time — so from that point on the running
    backend emitted zero log lines (no request errors, no update-sweep
    failures, no security warnings). This was invisible precisely because
    nothing tested it.

    Reproduces the real app-boot ordering: obtain a logger the way every
    backend module does, *before* triggering migrations, then confirm it
    still emits and reaches a handler afterward.
    """
    app_logger_name = "app.some_already_imported_module"
    app_logger = logging.getLogger(app_logger_name)
    assert not app_logger.disabled  # sanity: default state before migrating

    engine = create_engine(f"sqlite:///{tmp_path / 'logging.db'}")
    run_alembic_migrations(engine)

    assert not app_logger.disabled, (
        "run_alembic_migrations() disabled a pre-existing logger — "
        "alembic/env.py's fileConfig() call is killing app logging again"
    )

    caplog.clear()
    with caplog.at_level(logging.WARNING, logger=app_logger_name):
        app_logger.warning("post-migration warning: this must be visible")
    assert any(
        "post-migration warning" in record.message for record in caplog.records
    ), "logger survived but no record reached the handler — logging is still broken"


def test_run_alembic_migrations_is_idempotent(tmp_path):
    engine = _fresh_engine(tmp_path)
    with engine.connect() as conn:
        rev1 = MigrationContext.configure(conn).get_current_revision()
    run_alembic_migrations(engine)  # second run: no-op at head
    with engine.connect() as conn:
        rev2 = MigrationContext.configure(conn).get_current_revision()
    assert rev1 == rev2 == _HEAD


# --- 0002_tags_per_profile ------------------------------------------------


def _upgrade_to(engine, revision: str) -> None:
    """Upgrade ``engine``'s database to a specific revision (not just head)."""
    from alembic import command
    from alembic.config import Config

    backend_root = Path(dbs.__file__).resolve().parents[1]
    cfg = Config(str(backend_root / "alembic.ini"))
    cfg.set_main_option("script_location", str(backend_root / "alembic"))
    cfg.attributes["db_url"] = engine.url.render_as_string(hide_password=False)
    command.upgrade(cfg, revision)


def _seed_legacy_tag_world(engine) -> None:
    """Two accounts, three profiles, and the old *global* tag vocabulary."""
    with engine.begin() as conn:
        for uid, name in ((1, "alice"), (2, "bob")):
            conn.execute(
                text(
                    "INSERT INTO users (id, username, password_hash, is_admin,"
                    " is_active, created_at, updated_at) VALUES"
                    " (:id, :n, 'x', 0, 1, '2026-01-01', '2026-01-01')"
                ),
                {"id": uid, "n": name},
            )
        for pid, uid, name in ((10, 1, "A"), (11, 1, "B"), (20, 2, "C")):
            conn.execute(
                text(
                    "INSERT INTO reading_profiles (id, user_id, name,"
                    " avatar_key, mood, mature_content_enabled, sort_order,"
                    " created_at) VALUES (:p, :u, :n, 'a', 'calm', 0, 0,"
                    " '2026-01-01')"
                ),
                {"p": pid, "u": uid, "n": name},
            )
        for tid, name in ((1, "Peak"), (2, "Dropped"), (3, "Orphan")):
            conn.execute(
                text(
                    "INSERT INTO tags (id, name, category, color, created_at)"
                    " VALUES (:t, :n, 'custom', '#fff', '2026-01-01')"
                ),
                {"t": tid, "n": name},
            )
        # "Peak" is used by profile A (acct 1) and profile C (acct 2);
        # "Dropped" only by profile B; "Orphan" by nobody.
        for uid, pid, tid, series in (
            (1, 10, 1, "s-a"),
            (2, 20, 1, "s-c"),
            (1, 11, 2, "s-b"),
        ):
            conn.execute(
                text(
                    "INSERT INTO profile_series_tags (user_id, profile_id,"
                    " source_id, series_key, tag_id, is_ai_generated)"
                    " VALUES (:u, :p, 'mangadex', :s, :t, 0)"
                ),
                {"u": uid, "p": pid, "t": tid, "s": series},
            )


def test_tags_migration_splits_a_shared_tag_per_profile(tmp_path):
    """The shared "Peak" row becomes one owned tag per profile that used it,
    and every association follows its own copy."""
    engine = create_engine(f"sqlite:///{tmp_path / 'tags.db'}")
    _upgrade_to(engine, _BASELINE)
    _seed_legacy_tag_world(engine)
    _upgrade_to(engine, "head")

    with engine.connect() as conn:
        tags = {
            (r[1], r[2], r[3]): r[0]
            for r in conn.execute(
                text("SELECT id, user_id, profile_id, name FROM tags")
            )
        }
        # "Peak" split in two; "Dropped" kept its single owner.
        assert set(tags) == {
            (1, 10, "Peak"),
            (2, 20, "Peak"),
            (1, 11, "Dropped"),
        }
        # ...and "Orphan" — used by nobody, owner unrecoverable — is gone.
        assert not any(name == "Orphan" for (_u, _p, name) in tags)

        links = {
            (r[0], r[1], r[2]): r[3]
            for r in conn.execute(
                text(
                    "SELECT user_id, profile_id, series_key, tag_id"
                    " FROM profile_series_tags"
                )
            )
        }
        assert links[(1, 10, "s-a")] == tags[(1, 10, "Peak")]
        assert links[(2, 20, "s-c")] == tags[(2, 20, "Peak")]
        assert links[(1, 11, "s-b")] == tags[(1, 11, "Dropped")]

        # Scope-local uniqueness replaced the global UNIQUE(name): two
        # profiles may now both own a tag called "Peak" (proved above), and a
        # single profile still may not own two.
        cols = {
            r[1] for r in conn.execute(text("PRAGMA table_info(tags)"))
        }
        assert {"user_id", "profile_id"} <= cols


# --- 0008_followed_series_chapter_count -----------------------------------


def _seed_pre_0008_follows(engine) -> None:
    """Follows written before ``chapter_count`` existed, with varied blobs."""
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO users (id, username, password_hash, is_admin,"
                " is_active, created_at, updated_at) VALUES"
                " (1, 'owner', 'x', 1, 1, '2026-01-01', '2026-01-01')"
            )
        )
        conn.execute(
            text(
                "INSERT INTO reading_profiles (id, user_id, name, avatar_key,"
                " mood, mature_content_enabled, sort_order, created_at)"
                " VALUES (10, 1, 'A', 'a', 'calm', 0, 0, '2026-01-01')"
            )
        )
        blobs = {
            1: json.dumps([{"key": f"c{n}", "number": float(n)} for n in range(219)]),
            2: json.dumps([{"key": "c1", "number": 1.0, "title": 'a "key": trap'}]),
            3: "[]",
            4: "this is not json",
        }
        for fid, blob in blobs.items():
            conn.execute(
                text(
                    "INSERT INTO followed_series (id, user_id, profile_id,"
                    " source_id, series_key, title, is_favorite,"
                    " reading_status, notify, sort_order, known_chapters,"
                    " created_at, updated_at) VALUES (:i, 1, 10, 'mangadex',"
                    " :k, 't', 0, 'reading', 1, 0, :b, '2026-01-01',"
                    " '2026-01-01')"
                ),
                {"i": fid, "k": f"s-{fid}", "b": blob},
            )


def test_chapter_count_backfill_matches_the_parsed_array(tmp_path):
    """0008 backfills the exact ``len(known_chapters)``, corrupt rows included.

    The counts must equal what the read path's ``json.loads`` would produce —
    including for a title that embeds an escaped ``"key":``, which any
    substring-counting shortcut would miscount, and for a blob that is not
    JSON at all (0, matching the readers' ``_loads(...) or []`` fallback).
    """
    engine = create_engine(f"sqlite:///{tmp_path / 'count.db'}")
    _upgrade_to(engine, "0007_novel_chapter_cache")
    _seed_pre_0008_follows(engine)
    _upgrade_to(engine, "0008_followed_series_chapter_count")

    with engine.connect() as conn:
        rows = dict(
            conn.execute(
                text("SELECT id, chapter_count FROM followed_series")
            ).all()
        )
    assert rows == {1: 219, 2: 1, 3: 0, 4: 0}


def test_chapter_count_cannot_drift_from_known_chapters(tmp_path):
    """Every way of writing the array updates the count with it.

    The column is denormalized, so the guarantee that makes it safe is that no
    call site can write one without the other — the attribute listener in
    ``database.models`` fires for the declarative constructor's keyword and for
    plain assignment alike. If that listener is ever removed, this fails.
    """
    from sqlalchemy.orm import Session

    from database.models import FollowedSeries

    engine = _fresh_engine(tmp_path)
    with engine.begin() as conn:
        _seed_pre_0008_follows_accounts(conn)
    with Session(engine) as session:
        row = FollowedSeries(
            user_id=1,
            profile_id=10,
            source_id="mangadex",
            series_key="s-new",
            title="t",
            known_chapters=json.dumps([{"key": f"c{n}"} for n in range(7)]),
        )
        session.add(row)
        session.commit()
        assert row.chapter_count == 7, "constructor keyword did not set the count"

        row.known_chapters = json.dumps([{"key": "c1"}, {"key": "c2"}])
        session.commit()
        assert row.chapter_count == 2, "assignment did not update the count"

        row.known_chapters = "not json"
        session.commit()
        assert row.chapter_count == 0, "corrupt blob should count as no chapters"

        bare = FollowedSeries(
            user_id=1,
            profile_id=10,
            source_id="mangadex",
            series_key="s-bare",
            title="t",
        )
        session.add(bare)
        session.commit()
        assert bare.chapter_count == 0, "default row should count as no chapters"


def _seed_pre_0008_follows_accounts(conn) -> None:
    conn.execute(
        text(
            "INSERT INTO users (id, username, password_hash, is_admin,"
            " is_active, created_at, updated_at) VALUES"
            " (1, 'owner', 'x', 1, 1, '2026-01-01', '2026-01-01')"
        )
    )
    conn.execute(
        text(
            "INSERT INTO reading_profiles (id, user_id, name, avatar_key,"
            " mood, mature_content_enabled, sort_order, created_at)"
            " VALUES (10, 1, 'A', 'a', 'calm', 0, 0, '2026-01-01')"
        )
    )


# --- 0009_reading_session_duration ----------------------------------------


def test_session_duration_backfill_matches_the_old_sql_expression(tmp_path):
    """0009 reproduces exactly what the read path used to compute.

    The statistics payload is a set of numbers the owner has been looking at,
    so the migration must not move any of them. The cases that matter are the
    ones the old expression special-cased: an unclosed session, and one whose
    ``ended_at`` precedes its ``started_at`` (a client with a skewed clock),
    both of which had to contribute zero rather than a negative.
    """
    engine = create_engine(f"sqlite:///{tmp_path / 'dur.db'}")
    _upgrade_to(engine, "0008_followed_series_chapter_count")
    with engine.begin() as conn:
        _seed_pre_0008_follows_accounts(conn)
        rows = [
            (1, "2026-01-01 10:00:00", "2026-01-01 10:00:30", 30),   # 30s
            (2, "2026-01-01 10:00:00", "2026-01-01 12:00:00", 7200),  # uncapped
            (3, "2026-01-01 10:00:00", None, 0),                      # unclosed
            (4, "2026-01-01 10:00:00", "2026-01-01 09:00:00", 0),     # backwards
        ]
        for sid, start, end, _ in rows:
            conn.execute(
                text(
                    "INSERT INTO reading_sessions (id, user_id, profile_id,"
                    " source_id, series_key, chapter_key, start_page,"
                    " end_page, pages_read, started_at, ended_at) VALUES"
                    " (:i, 1, 10, 'mangadex', 's', :c, 1, 2, 2, :s, :e)"
                ),
                {"i": sid, "c": f"c{sid}", "s": start, "e": end},
            )
    _upgrade_to(engine, "0009_reading_session_duration")

    with engine.connect() as conn:
        stored = dict(
            conn.execute(
                text("SELECT id, duration_seconds FROM reading_sessions")
            ).all()
        )
    assert stored == {sid: expected for sid, _, _, expected in rows}


def test_session_duration_is_written_however_the_row_is_built(tmp_path):
    """The mapper listener covers every insert path, not just the writer.

    ``duration_seconds`` derives from two columns, so nothing at a call site
    is expected to maintain it. If the listener is removed, reading time
    silently reads as zero everywhere — hence this test rather than trust.
    """
    from sqlalchemy.orm import Session

    from database.models import ReadingSession

    engine = _fresh_engine(tmp_path)
    with engine.begin() as conn:
        _seed_pre_0008_follows_accounts(conn)

    base = datetime(2026, 1, 1, 10, 0, 0)
    with Session(engine) as session:
        cases = {
            "closed": (base, base + timedelta(seconds=45), 45),
            "unclosed": (base, None, 0),
            "backwards": (base, base - timedelta(hours=1), 0),
            "long": (base, base + timedelta(hours=3), 10800),
        }
        for key, (start, end, _) in cases.items():
            session.add(
                ReadingSession(
                    user_id=1,
                    profile_id=10,
                    source_id="mangadex",
                    series_key="s",
                    chapter_key=key,
                    start_page=1,
                    end_page=2,
                    pages_read=2,
                    started_at=start,
                    ended_at=end,
                )
            )
        session.commit()

        stored = {
            r.chapter_key: r.duration_seconds
            for r in session.query(ReadingSession).all()
        }
    assert stored == {key: expected for key, (_, _, expected) in cases.items()}


def test_session_duration_listener_rounds_the_way_the_backfill_does(tmp_path):
    """Backfilled history and newly written rows must be the same number.

    0009 backfills in SQL with ``strftime('%s', ended_at) - strftime('%s',
    started_at)``, which truncates *each end* to a whole second and then
    subtracts. A plain ``(ended_at - started_at).total_seconds()`` subtracts
    first and truncates after, and the two differ by one second whenever the
    fractions straddle a second boundary — 10:00:00.9 to 10:00:01.1 is 1 to
    SQLite and 0 to the subtraction. ``utcnow()`` keeps microseconds, so every
    real row has fractions and the drift is not hypothetical: it made every
    session written after the migration read up to a second shorter than the
    identical session recorded before it.

    Both halves are asserted against the same rows: the migration backfills
    one set, the mapper listener writes the other, and they must agree.
    """
    from sqlalchemy.orm import Session

    from database.models import ReadingSession

    #: (label, started_at, ended_at) — fractions chosen to straddle, and not
    #: to straddle, a whole-second boundary in both directions.
    cases = [
        ("straddles-one-second", datetime(2026, 1, 1, 10, 0, 0, 900000),
         datetime(2026, 1, 1, 10, 0, 1, 100000)),
        ("inside-one-second", datetime(2026, 1, 1, 10, 0, 0, 100000),
         datetime(2026, 1, 1, 10, 0, 0, 900000)),
        ("straddles-late", datetime(2026, 1, 1, 10, 0, 0, 900000),
         datetime(2026, 1, 1, 10, 0, 59, 100000)),
        ("exact", datetime(2026, 1, 1, 10, 0, 0),
         datetime(2026, 1, 1, 10, 5, 0)),
        ("backwards-fractional", datetime(2026, 1, 1, 10, 0, 1, 100000),
         datetime(2026, 1, 1, 10, 0, 0, 900000)),
    ]

    # --- what revision 0009's SQL backfill stores ---------------------------
    engine = create_engine(f"sqlite:///{tmp_path / 'round.db'}")
    _upgrade_to(engine, "0008_followed_series_chapter_count")
    with engine.begin() as conn:
        _seed_pre_0008_follows_accounts(conn)
        for sid, (label, start, end) in enumerate(cases, start=1):
            conn.execute(
                text(
                    "INSERT INTO reading_sessions (id, user_id, profile_id,"
                    " source_id, series_key, chapter_key, start_page,"
                    " end_page, pages_read, started_at, ended_at) VALUES"
                    " (:i, 1, 10, 'mangadex', 's', :c, 1, 2, 2, :s, :e)"
                ),
                {"i": sid, "c": label, "s": str(start), "e": str(end)},
            )
    _upgrade_to(engine, "0009_reading_session_duration")
    with engine.connect() as conn:
        backfilled = dict(
            conn.execute(
                text("SELECT chapter_key, duration_seconds FROM reading_sessions")
            ).all()
        )

    # --- what the mapper listener writes for the same instants --------------
    listener_dir = tmp_path / "listener"
    listener_dir.mkdir()
    fresh = _fresh_engine(listener_dir)
    with fresh.begin() as conn:
        _seed_pre_0008_follows_accounts(conn)
    with Session(fresh) as session:
        for label, start, end in cases:
            session.add(
                ReadingSession(
                    user_id=1, profile_id=10, source_id="mangadex",
                    series_key="s", chapter_key=label,
                    start_page=1, end_page=2, pages_read=2,
                    started_at=start, ended_at=end,
                )
            )
        session.commit()
        written = {
            r.chapter_key: r.duration_seconds
            for r in session.query(ReadingSession).all()
        }

    assert written == backfilled
    # And the values themselves are SQLite's, not a plain subtraction's.
    assert backfilled["straddles-one-second"] == 1
    assert backfilled["inside-one-second"] == 0
    assert backfilled["straddles-late"] == 59
    assert backfilled["exact"] == 300
    assert backfilled["backwards-fractional"] == 0
