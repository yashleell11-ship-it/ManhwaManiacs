"""The nightly host job and the in-app export must agree on what is cache.

They did not. ``backup_service`` has excluded the four derived tables since it
was written -- its own comment says they are ~97% of the file -- while
``ops/vps/backup-db.sh`` did a bare ``VACUUM INTO`` and kept everything. So the
backups that actually run unattended were the fat ones: measured on the live
box, the nightly artefact grew 9 MB -> 45 MB between 2026-09-06 and 2026-09-13
while the account count stayed at three, and zstd's ratio collapsed from 57% to
22% because the payload had become already-compressed WebP.

Dropping them takes the compressed nightly file from 43.5 MB to 53 KB on real
production data. The way that regresses is not a bug in either file -- it is the
two lists drifting, so these tests are about the LIST, not the behaviour.
"""

from __future__ import annotations

import re
from pathlib import Path

from core.cache_tables import CACHE_TABLES
from services.backup_service import _CACHE_TABLES

SCRIPT = Path(__file__).resolve().parents[2] / "ops" / "vps" / "backup-db.sh"
MODULE = Path(__file__).resolve().parents[1] / "core" / "cache_tables.py"


def test_the_export_uses_the_shared_list():
    assert _CACHE_TABLES is CACHE_TABLES, (
        "backup_service has its own copy of the cache-table list again"
    )


def test_the_shared_module_imports_nothing():
    # The nightly job runs under the VPS's system python with no virtualenv and
    # reads this file by exec'ing it. One import of anything in the backend's
    # dependency tree and every unattended backup starts silently keeping the
    # cache -- the failure mode is a fat backup, which nothing alerts on.
    source = MODULE.read_text()
    offenders = [
        line
        for line in source.splitlines()
        if re.match(r"\s*(import|from)\s+\w", line)
    ]
    assert not offenders, f"core/cache_tables.py must stay import-free: {offenders}"


def test_the_nightly_job_reads_the_list_rather_than_repeating_it():
    script = SCRIPT.read_text()
    assert "cache_tables.py" in script, (
        "backup-db.sh no longer points at the shared list"
    )
    for table in CACHE_TABLES:
        assert table not in script, (
            f"backup-db.sh hardcodes {table!r}; that is the drift this shared "
            "list exists to prevent"
        )


def test_the_nightly_job_still_has_an_escape_hatch():
    # Cloning a box that should come up warm is a real need; it just must not
    # be the default.
    script = SCRIPT.read_text()
    assert "MM_BACKUP_INCLUDE_CACHE" in script
    assert 'INCLUDE_CACHE="${MM_BACKUP_INCLUDE_CACHE:-0}"' in script, (
        "keeping the cache must be opt-IN"
    )


def test_a_missing_list_keeps_the_cache_rather_than_failing():
    # A snapshot must never fail over this: keeping the cache makes a fat
    # backup, not a broken one, and a fat backup beats no backup at all.
    script = SCRIPT.read_text()
    assert "return ()" in script and "os.path.exists(path)" in script, (
        "backup-db.sh must degrade to keeping the cache when the list is gone"
    )
