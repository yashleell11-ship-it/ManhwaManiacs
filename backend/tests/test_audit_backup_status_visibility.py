"""The nightly backup's verdict reaches /backup/status.

Before this, the endpoint returned one field — restore_pending — and the
backend could not see the backup tree at all. Every failure path in
ops/vps/backup-db.sh just exited 1, the systemd unit had no OnFailure, and so
the free-space guard, an unreadable database, a held lock and a failed integrity
check were all completely silent. The one screen the owner would open to check
on backups kept looking perfectly healthy.

The rule these tests exist to hold: UNKNOWN must never read as OK.
"""

from __future__ import annotations

import json

import pytest
from services import backup_service


@pytest.fixture
def status_file(tmp_path, monkeypatch):
    monkeypatch.setattr(backup_service, "spool_dir", lambda: tmp_path)
    return tmp_path / "backup-status.json"


def test_never_reported_is_unknown_not_healthy(status_file):
    assert backup_service.nightly_status() is None


def test_a_clean_run_is_reported(status_file):
    status_file.write_text(
        json.dumps(
            {
                "ok": True,
                "finished_at": "2026-09-18T03:30:00Z",
                "phase": "done",
                "bytes": 54245,
            }
        )
    )

    state = backup_service.nightly_status()

    assert state == {
        "ok": True,
        "finished_at": "2026-09-18T03:30:00Z",
        "phase": "done",
        "bytes": 54245,
    }


def test_a_failed_run_names_the_step_it_died_at(status_file):
    # The difference between "backups are broken" and "the disk filled up".
    status_file.write_text(
        json.dumps({"ok": False, "phase": "free-space", "finished_at": "x", "bytes": 0})
    )

    state = backup_service.nightly_status()

    assert state["ok"] is False
    assert state["phase"] == "free-space"


def test_malformed_json_reads_as_unknown(status_file):
    status_file.write_text("{not json at all")
    assert backup_service.nightly_status() is None


def test_a_non_object_reads_as_unknown(status_file):
    status_file.write_text(json.dumps(["ok"]))
    assert backup_service.nightly_status() is None


def test_a_truncated_write_never_reads_as_ok(status_file):
    # The job writes to a temp file and renames, so this should not happen --
    # but if it ever does, silence must not look like success.
    status_file.write_text('{"ok": true, "phase": "do')
    assert backup_service.nightly_status() is None


def test_garbage_field_types_do_not_crash_or_lie(status_file):
    status_file.write_text(
        json.dumps({"ok": "yes", "finished_at": 5, "phase": [], "bytes": "big"})
    )

    state = backup_service.nightly_status()

    # "yes" is truthy, which is the one field a caller may take at face value;
    # everything it cannot type-check degrades to None rather than a wrong value.
    assert state["finished_at"] is None
    assert state["phase"] is None
    assert state["bytes"] is None


def test_the_payload_never_carries_a_filesystem_path(status_file):
    # /backup/status is the one backup endpoint any signed-in account may call,
    # and this instance has accounts that are not the owner's.
    status_file.write_text(
        json.dumps(
            {
                "ok": True,
                "finished_at": "2026-09-18T03:30:00Z",
                "phase": "done",
                "bytes": 1,
                "path": "/srv/manhwamaniacs/backups/daily/x.db.zst",
                "name": "x.db.zst",
            }
        )
    )

    state = backup_service.nightly_status()

    assert "path" not in state
    assert "name" not in state
    assert not any("/" in str(v) for v in state.values() if v is not None)
