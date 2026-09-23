"""ops/vps/backup-db.sh keeps one weekly per week, and its Undo names a real file.

Two ways the nightly job's promises quietly came apart on the live box:

- The weekly tier linked EVERY run on a Sunday. A manual run or a stage-restore
  on a Sunday took a second slot for the same week, so KEEP_WEEKLY=4 held 4
  files covering 3 weeks (weekly/ really did hold 20260913-033728 and
  20260913-122649). And a Sunday whose run failed, or that the box was off for,
  left its week with no weekly at all.
- stage-restore printed its Undo as ``stage-restore $ROOT/latest.db.zst``. That
  symlink is repointed by every run, so once the 03:30 timer fired it named a
  snapshot of the RESTORED data, and the printed undo restored the restore.

These run the real script against a throwaway ROOT and database, with ``date``
pinned so each run lands on a chosen day. Nothing here can reach a live path:
every location the script writes is passed in explicitly.
"""

from __future__ import annotations

import os
import re
import shutil
import sqlite3
import subprocess
import sys
from datetime import date
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "ops" / "vps" / "backup-db.sh"

pytestmark = pytest.mark.skipif(
    not (sys.platform.startswith("linux") and shutil.which("zstd") and shutil.which("flock")),
    reason="backup-db.sh needs GNU date, zstd and flock",
)


@pytest.fixture
def box(tmp_path):
    """A fake box: a small live database, a backup root, and a pinned clock."""
    data = tmp_path / "data"
    data.mkdir()
    db = data / "manhwamaniacs.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE alembic_version (version_num TEXT)")
    con.execute("INSERT INTO alembic_version VALUES ('0015_test')")
    con.execute("CREATE TABLE users (id INTEGER PRIMARY KEY)")
    con.execute("INSERT INTO users DEFAULT VALUES")
    con.commit()
    con.close()

    # `date` with no -d answers as of MM_FAKE_NOW; with one it is left alone,
    # since the script also uses it to turn a file's stamp into a week.
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    real_date = shutil.which("date")
    shim = bin_dir / "date"
    shim.write_text(
        "#!/usr/bin/env bash\n"
        'for a in "$@"; do case "$a" in -d*|--date*) exec ' + real_date + ' "$@";; esac; done\n'
        'exec ' + real_date + ' -d "$MM_FAKE_NOW" "$@"\n'
    )
    shim.chmod(0o755)

    root = tmp_path / "backups"
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "MM_DB_PATH": str(db),
        "MM_BACKUP_ROOT": str(root),
        "MM_SETTINGS_PATH": str(data / "settings.json"),
        "MM_BACKUP_STATUS_JSON": str(data / "backup-status.json"),
        "MM_PYTHON": sys.executable,
    }
    env.pop("MM_CONFIRM", None)

    def run(when: str, *args: str) -> str:
        result = subprocess.run(
            ["bash", str(SCRIPT), *args],
            env={**env, "MM_FAKE_NOW": when},
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout

    run.root = root
    run.env = env
    return run


def _weeks(root: Path) -> list[str]:
    weeks = []
    for path in sorted((root / "weekly").glob("manhwamaniacs-*.db.zst")):
        stamp = path.name.removeprefix("manhwamaniacs-")[:8]
        year, week, _ = date(int(stamp[:4]), int(stamp[4:6]), int(stamp[6:8])).isocalendar()
        weeks.append(f"{year}-W{week:02d}")
    return weeks


def test_a_second_run_on_sunday_does_not_take_a_second_weekly_slot(box):
    box("2026-09-06 03:30:00 UTC", "run")   # Sun
    box("2026-09-13 03:37:28 UTC", "run")   # Sun, the timer
    box("2026-09-13 12:26:49 UTC", "run")   # Sun, the owner's manual run
    box("2026-09-20 03:33:54 UTC", "run")   # Sun
    box("2026-09-27 03:30:00 UTC", "run")   # Sun

    weeks = _weeks(box.root)
    assert len(weeks) == 4
    assert len(set(weeks)) == 4, f"two weeklies for one week: {weeks}"
    # The oldest week the policy promises is still there.
    assert weeks[0] == "2026-W36"


def test_a_week_whose_sunday_run_never_happened_still_gets_a_weekly(box):
    box("2026-09-19 03:30:00 UTC", "run")   # Sat, week 38
    # Sunday the 20th: the box was off. Persistent=true runs it on Monday.
    box("2026-09-21 09:10:00 UTC", "run")   # Mon, week 39
    box("2026-09-22 03:30:00 UTC", "run")   # Tue, week 39 again

    assert _weeks(box.root) == ["2026-W38", "2026-W39"]


def test_undo_names_the_pre_restore_file_not_the_moving_symlink(box):
    box("2026-09-21 03:30:00 UTC", "run")
    target = sorted((box.root / "daily").glob("manhwamaniacs-*.db.zst"))[0]

    out = subprocess.run(
        ["bash", str(SCRIPT), "stage-restore", str(target)],
        env={**box.env, "MM_FAKE_NOW": "2026-09-23 01:00:05 UTC", "MM_CONFIRM": "RESTORE"},
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    undo = re.search(r"Undo:\s+MM_CONFIRM=RESTORE \S+ stage-restore (\S+)", out)
    assert undo, out
    named = Path(undo.group(1))
    assert "latest.db.zst" not in named.name
    assert named.parent == (box.root / "daily").resolve()
    assert named.name == "manhwamaniacs-20260923-010005.db.zst"

    # The next nightly moves latest.db.zst on; the printed file must not move.
    box("2026-09-23 03:30:00 UTC", "run")
    assert named.exists()
    assert (box.root / "latest.db.zst").resolve() != named


def test_the_banner_no_longer_says_the_backend_keeps_no_copy(box):
    box("2026-09-21 03:30:00 UTC", "run")
    target = sorted((box.root / "daily").glob("manhwamaniacs-*.db.zst"))[0]
    result = subprocess.run(
        ["bash", str(SCRIPT), "stage-restore", str(target)],
        env={**box.env, "MM_FAKE_NOW": "2026-09-23 01:00:00 UTC"},
        capture_output=True,
        text=True,
        check=False,
    )
    # Without MM_CONFIRM it only prints the banner and refuses.
    assert result.returncode == 2
    banner = result.stdout
    assert "keeps no copy" not in banner
    assert ".pre-restore-" in banner
