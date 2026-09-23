"""AUDIT (migrations shard) — downgrades of 0010 and 0002 destroy more than they document.

Walked head -> 0009 -> 0001 -> head on a seeded fresh database
(``alembic/versions/0010_smart_bookmarks.py:186-196``,
``alembic/versions/0002_tags_per_profile.py:146-167`` and ``:81-91``):

* 0010 ``downgrade()`` copies ``anchor_index`` into ``page`` for every live row
  with no ``media_type`` filter, so a NOVEL bookmark (paragraph 12) comes back
  as a MANGA bookmark on page 12 — and the re-upgrade then stamps it
  ``media_type='manga'`` for good. The docstring only says the fraction and
  paragraph index have "nowhere to go"; it does not say the row is silently
  re-typed.
* 0002 ``downgrade()`` merges same-named tags across profiles with
  ``MIN(category), MIN(color)`` — one profile's authored colour replaces
  another's — and the re-upgrade can only recover owners through
  ``profile_series_tags``, so a tag that was created but never applied is
  deleted by a plain "downgrade to look, then upgrade" round trip.

Resolution:

* 0010 ``downgrade()`` carries manga rows only and logs what it drops. A
  novel bookmark has no representation in a page-only table; dropping it is
  the honest outcome, retyping it was silent corruption.
* 0002 ``downgrade()`` keeps the oldest same-named tag whole — its own
  category and colour together — instead of ``MIN()`` per column. What it
  still cannot do is hand a never-applied tag back to its owner on the way
  up: the 0001 schema has nowhere to keep the owner. The third test pins that
  documented loss rather than a fix.
"""
from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config

import database.session as dbs

_HEAD = "0016_backfill_last_login"
_BEFORE_0010 = "0009_reading_session_duration"
_BEFORE_0002 = "0001_source_native"


def _cfg(db_path: Path) -> Config:
    root = Path(dbs.__file__).resolve().parents[1]
    cfg = Config(str(root / "alembic.ini"))
    cfg.set_main_option("script_location", str(root / "alembic"))
    cfg.attributes["db_url"] = f"sqlite:///{db_path}"
    return cfg


def _q(db_path: Path, sql: str) -> list[tuple]:
    c = sqlite3.connect(db_path)
    try:
        return c.execute(sql).fetchall()
    finally:
        c.close()


def _seed(db_path: Path) -> None:
    c = sqlite3.connect(db_path)
    c.execute(
        "INSERT INTO users(id,username,password_hash,is_admin,is_active,created_at,updated_at)"
        " VALUES (1,'a','x',1,1,'2026-01-01','2026-01-01')"
    )
    for pid in (1, 2):
        c.execute(
            "INSERT INTO reading_profiles(id,user_id,name,avatar_key,mood,sort_order,"
            "mature_content_enabled,created_at) VALUES (?,1,?,'d','d',0,0,'2026-01-01')",
            (pid, f"p{pid}"),
        )
    cols = (
        "id,user_id,profile_id,client_id,source_id,series_key,chapter_key,chapter_number,"
        "media_type,anchor_index,anchor_fraction,anchor_total,note,deleted_at,created_at,updated_at"
    )
    c.execute(
        f"INSERT INTO bookmarks({cols}) VALUES "
        "(1,1,1,'c1','md','s','ch1',NULL,'manga',5,0.0,0,'n1',NULL,'2026-01-01','2026-01-01')"
    )
    c.execute(
        f"INSERT INTO bookmarks({cols}) VALUES "
        "(2,1,1,'c2','nv','s','ch3',3.0,'novel',12,0.5,40,NULL,NULL,'2026-01-02','2026-01-03')"
    )
    c.execute(
        "INSERT INTO tags(id,user_id,profile_id,name,category,color,created_at) VALUES "
        "(1,1,1,'action','custom','#f00','2026-01-01'),"
        "(2,1,1,'unused','custom','#aaa','2026-01-01'),"
        "(3,1,2,'action','custom','#0f0','2026-01-02')"
    )
    c.execute(
        "INSERT INTO profile_series_tags(user_id,profile_id,source_id,series_key,tag_id,"
        "is_ai_generated,confidence) VALUES (1,1,'md','s1',1,0,NULL),(1,2,'md','s2',3,0,NULL)"
    )
    c.commit()
    c.close()


@pytest.fixture
def seeded(tmp_path: Path) -> tuple[Path, Config]:
    db = tmp_path / "audit.db"
    cfg = _cfg(db)
    command.upgrade(cfg, "head")
    assert _q(db, "SELECT version_num FROM alembic_version") == [(_HEAD,)]
    _seed(db)
    return db, cfg


def test_0010_downgrade_does_not_retype_a_novel_bookmark_as_manga(seeded):
    db, cfg = seeded
    command.downgrade(cfg, _BEFORE_0010)
    command.upgrade(cfg, "head")
    rows = _q(db, "SELECT id, media_type, anchor_index FROM bookmarks WHERE id = 2")
    # Today: [(2, 'manga', 12)] — paragraph 12 of a novel became page 12 of a manga.
    assert rows == [] or rows[0][1] == "novel", rows


def test_0002_downgrade_does_not_replace_one_profiles_tag_colour_with_anothers(seeded):
    db, cfg = seeded
    command.downgrade(cfg, _BEFORE_0002)
    command.upgrade(cfg, "head")
    rows = _q(db, "SELECT color FROM tags WHERE user_id=1 AND profile_id=1 AND name='action'")
    # Was [('#0f0',)]: profile 2's colour (MIN over both profiles) won.
    assert rows == [("#f00",)], rows
    # The documented loss: the survivor's colour is what every profile gets
    # back. Profile 2's own '#0f0' had nowhere to live in a global vocabulary.
    assert _q(db, "SELECT profile_id, color FROM tags WHERE name='action' ORDER BY profile_id") == [
        (1, "#f00"),
        (2, "#f00"),
    ]


def test_0002_round_trip_loses_only_the_tags_that_were_never_applied(seeded):
    """Pins the documented loss, not a fix: the 0001 schema has no owner
    column, so once ``downgrade()`` has collapsed the vocabulary nothing but
    ``profile_series_tags`` can say whose tag "unused" was. ``upgrade()``
    therefore drops it — and only it: every applied tag comes back."""
    db, cfg = seeded
    command.downgrade(cfg, _BEFORE_0002)
    # The downgrade itself keeps the row; it is the re-upgrade that has
    # nowhere to put it.
    assert _q(db, "SELECT name FROM tags WHERE name='unused'") == [("unused",)]
    command.upgrade(cfg, "head")
    assert _q(db, "SELECT name FROM tags WHERE name='unused'") == []
    assert _q(db, "SELECT user_id, profile_id, name FROM tags ORDER BY profile_id") == [
        (1, 1, "action"),
        (1, 2, "action"),
    ]
