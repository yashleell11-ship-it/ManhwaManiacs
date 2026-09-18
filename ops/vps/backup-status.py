"""Write the nightly backup's verdict where the backend can read it.

Invoked by ``backup-db.sh`` from its EXIT/INT/TERM trap, so every run leaves a
verdict — including one killed by systemd's TimeoutStartSec, which is the case
bash's plain EXIT trap misses.

Runs under the VPS's system python with no virtualenv, so it imports nothing
beyond the standard library.

Timestamps and sizes only, never a path. ``GET /backup/status`` is the one
backup endpoint any signed-in account may call, and this instance has accounts
that are not the owner's, so the payload must not disclose the host's layout.

Usage: backup-status.py <tmp-path> <exit-code> <phase> <bytes>
"""

import json
import os
import sys
import time


def main() -> int:
    if len(sys.argv) < 5:
        return 2
    tmp, rc, phase, size = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    try:
        code = int(rc)
    except ValueError:
        code = 1
    try:
        written = int(size)
    except ValueError:
        written = 0

    doc = {
        "ok": code == 0,
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "bytes": written,
        # Where it got to. "done" is a clean run; anything else names the step
        # that failed, which is the difference between "backups are broken" and
        # "the disk filled up last night".
        "phase": phase or "unknown",
    }
    with open(tmp, "w") as handle:
        json.dump(doc, handle)
        handle.flush()
        os.fsync(handle.fileno())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
