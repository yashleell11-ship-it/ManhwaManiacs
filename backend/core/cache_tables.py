"""The tables that hold nothing but derived data.

Deliberately dependency-free — no imports at all — because two very different
things read it and one of them cannot afford the backend's dependency tree:

* ``services.backup_service``, for the in-app export (``/backup/export``).
* ``ops/vps/backup-db.sh``, the nightly host job, which runs under the VPS's
  system python with no virtualenv and must not import FastAPI or SQLAlchemy to
  learn four table names.

Keeping one tuple that both read is the point. They were separate before: the
export had excluded these since it was written, while the nightly job took
everything — so the backups that actually matter were the ones carrying the
dead weight. Measured on the live box: the nightly artefact grew 9 MB -> 45 MB
between 2026-09-06 and 2026-09-13 while the account count stayed at three, and
zstd's ratio fell from 57% to 22% because the payload had become
already-compressed WebP. A drifted copy of this list would quietly bring that
back, so ``tests/test_audit_backup_cache_tables.py`` fails if the shell script
and this module disagree.

Everything here is rebuilt by the next connector fetch, nothing references it by
foreign key, and a restore comes up cold rather than wrong.
"""

CACHE_TABLES = (
    "source_series_cache",
    "novel_chapter_cache",
    "source_cover_cache",
    "source_browse_cache",
)
