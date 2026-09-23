#!/usr/bin/env bash
# =============================================================================
# ManhwaManiacs — nightly on-VPS backup of the SQLite metadata database.
# Installed by ops/vps/deploy.sh cmd_install_timers as mm-db-backup.{service,timer}.
#
#   backup-db.sh run                   snapshot + verify + rotate (timer entry point)
#   backup-db.sh verify [FILE.zst]     restore drill: decompress newest (or FILE),
#                                      integrity_check it, print counts. Never
#                                      touches the live DB.
#   backup-db.sh list                  what is kept, sizes, log tail
#   backup-db.sh stage-restore FILE.zst
#                                      DESTRUCTIVE (confirm with MM_CONFIRM=RESTORE):
#                                      take a fresh backup, then decompress FILE to
#                                      <db>.pending-restore. The backend validates
#                                      that file on its next start and swaps it in,
#                                      keeping the replaced database as
#                                      <db>.pre-restore-<stamp> (core/backup_restore.py);
#                                      a corrupt file, or one stamped with an alembic
#                                      revision this build does not have, is refused and
#                                      set aside as <db>.pending-restore.rejected.
#
# Why not `cp manhwamaniacs.db`: the DB runs in WAL mode and the main file is
# only rewritten at a checkpoint. On the live box the main file's mtime was
# 08:28 while the -wal kept changing until 14:29 — a plain copy of the .db
# silently drops everything committed since the last checkpoint, and copying
# .db + -wal while the app writes is not a consistent pair either. VACUUM INTO
# reads through the WAL under a read lock and emits one consistent,
# compacted, rollback-journal file, exactly like the admin "export" button
# (backend/services/backup_service.py). It never blocks the app's writers
# (WAL readers don't) and never triggers a checkpoint.
#
# Runs on the HOST as `ubuntu` (uid 1000 == the container's app user, and
# /srv/manhwamaniacs/data is a bind mount), with the host's python3 whose
# sqlite (3.46.1, needs >= 3.27 for VACUUM INTO) opens the file directly with
# ?mode=ro. No docker exec, so a wedged container cannot block a backup.
#
# Layout (on the 49 GB /srv disk — never the 80 %-full root disk):
#   $ROOT/daily/manhwamaniacs-YYYYmmdd-HHMMSS.db.zst   newest KEEP_DAILY
#   $ROOT/weekly/manhwamaniacs-YYYYmmdd-HHMMSS.db.zst  hard-linked from the first
#                                                        successful run of each ISO
#                                                        week, newest KEEP_WEEKLY
#   $ROOT/latest.db.zst -> daily/<newest>
#   $ROOT/backup.log                                   one line per run (also on stdout / journal)
#
# Exit codes: 0 ok, 1 failure (the systemd unit reports it), 2 usage.
# =============================================================================
set -euo pipefail

DB="${MM_DB_PATH:-/srv/manhwamaniacs/data/manhwamaniacs.db}"
ROOT="${MM_BACKUP_ROOT:-/srv/manhwamaniacs/backups}"
# The other half of this instance's state. It holds the registration invite code
# and the global mature-content flag, it lives beside the database on the /data
# volume, and nothing backed it up: a rebuilt box came back with the code gone
# and every 18+ series hidden again (the setting defaults to false), with
# nothing in the runbook to hint a file had been skipped. Copied rather than
# rotated -- it is a few hundred bytes of current configuration, and having it
# at all matters far more than having last Tuesday's.
SETTINGS="${MM_SETTINGS_PATH:-/srv/manhwamaniacs/data/settings.json}"
# The job's own verdict, written where the BACKEND can already see it.
#
# Deliberately in the data directory, not the backup tree: the container mounts
# /srv/manhwamaniacs/data as /data and resolves it from MM_DB_PATH, so this
# needs no compose edit, no container recreate, and it behaves the same on a
# laptop. Mounting the backup tree would hand the backend a directory of
# database dumps just to serve a timestamp.
STATUS_JSON="${MM_BACKUP_STATUS_JSON:-$(dirname "$DB")/backup-status.json}"
STATUS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup-status.py"

# Record the outcome for /backup/status. Called from the single EXIT/INT/TERM
# trap, so a run that dies still leaves a verdict -- silence was the whole
# problem: every failure path here just exited 1, the unit had no OnFailure, and
# the one screen the owner would look at kept saying nothing at all.
write_status(){
  local rc="$1" phase="$2" tmp="$STATUS_JSON.tmp"
  [ -r "$STATUS_PY" ] || return 0
  "$PY" "$STATUS_PY" "$tmp" "$rc" "$phase" "${STATUS_BYTES:-0}" >/dev/null 2>&1 || return 0
  mv -f "$tmp" "$STATUS_JSON" 2>/dev/null || true
  chown 1000:1000 "$STATUS_JSON" 2>/dev/null || true
}
KEEP_DAILY="${MM_BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${MM_BACKUP_KEEP_WEEKLY:-4}"
ZSTD_LEVEL="${MM_BACKUP_ZSTD_LEVEL:-9}"
PY="${MM_PYTHON:-python3}"
# The one list of cache tables, shared with the in-app export so the two cannot
# drift (backend/core/cache_tables.py is dependency-free precisely so this
# script's bare system python can read it).
CACHE_TABLES_PY="${MM_CACHE_TABLES_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/backend/core/cache_tables.py}"
# 1 keeps the regenerable cache in the snapshot, for cloning a box that should
# come up warm. The default drops it: on the live box those tables are ~96% of
# the file and are worthless the moment they are restored.
INCLUDE_CACHE="${MM_BACKUP_INCLUDE_CACHE:-0}"
LOG="$ROOT/backup.log"

say(){ echo "==> $*"; }
err(){ echo "!! $*" >&2; }
log(){ printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

need(){ command -v "$1" >/dev/null 2>&1 || { err "missing tool: $1"; exit 1; }; }

# Snapshot $1 (live db) into $2 (fresh path) with VACUUM INTO over a read-only
# connection, then integrity_check the COPY and print a JSON summary line.
snapshot(){
  "$PY" - "$1" "$2" "$CACHE_TABLES_PY" "$INCLUDE_CACHE" <<'PY'
import json, os, sqlite3, sys, time
src, dst = sys.argv[1], sys.argv[2]
cache_list_path = sys.argv[3] if len(sys.argv) > 3 else ""
include_cache = (sys.argv[4] if len(sys.argv) > 4 else "0") == "1"


def _cache_tables(path):
    """The shared tuple, read without importing the backend package.

    exec of a module whose entire body is one tuple literal: this runs under the
    VPS's system python, which has none of the backend's dependencies. Returns
    () when the file is missing so a snapshot NEVER fails over this -- keeping
    the cache makes a fat backup, not a broken one, and a fat backup beats none.
    """
    if not path or not os.path.exists(path):
        return ()
    namespace = {}
    try:
        with open(path) as handle:
            exec(compile(handle.read(), path, "exec"), namespace)
        return tuple(namespace.get("CACHE_TABLES") or ())
    except Exception:
        return ()
t0 = time.time()
if os.path.exists(dst):
    os.remove(dst)
# mode=ro: this connection can never write to the live database. VACUUM INTO
# only needs a read transaction and writes solely to `dst`.
con = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=30)
try:
    con.execute("VACUUM INTO ?", (dst,))
finally:
    con.close()

# Empty the derived tables, then vacuum again -- a DELETE alone leaves the freed
# pages allocated, and it is the second vacuum that actually makes the file
# small. Same policy the in-app export has always had; the nightly job simply
# never got it, so the backups that matter were the fat ones.
dropped = []
if not include_cache:
    work = sqlite3.connect(dst)
    try:
        present = {
            r[0] for r in work.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        for table in _cache_tables(cache_list_path):
            if table in present:
                work.execute(f"DELETE FROM {table}")
                dropped.append(table)
        if dropped:
            work.commit()
            work.execute("VACUUM")
    finally:
        work.close()

# SQLite does not fsync a VACUUM INTO target; do it ourselves before we trust it.
fd = os.open(dst, os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
copy = sqlite3.connect(f"file:{dst}?mode=ro", uri=True)
try:
    ic = [r[0] for r in copy.execute("PRAGMA integrity_check")]
    if ic != ["ok"]:
        print(json.dumps({"ok": False, "integrity_check": ic[:5]}))
        sys.exit(1)
    fk = copy.execute("PRAGMA foreign_key_check").fetchall()
    counts = {}
    for t in ("users", "reading_profiles", "followed_series", "chapter_progress", "bookmarks"):
        try:
            counts[t] = copy.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
        except sqlite3.Error:
            counts[t] = None
    info = {
        "ok": True,
        "alembic": (copy.execute("SELECT version_num FROM alembic_version").fetchone() or ["?"])[0],
        "bytes": os.path.getsize(dst),
        "live_bytes": os.path.getsize(src),
        "live_wal_bytes": os.path.getsize(src + "-wal") if os.path.exists(src + "-wal") else 0,
        "fk_violations": len(fk),
        "counts": counts,
        "snapshot_s": round(time.time() - t0, 3),
        "cache_dropped": dropped,
    }
finally:
    copy.close()
print(json.dumps(info))
PY
}

cmd_run(){
  need zstd; need flock; need "$PY"
  mkdir -p "$ROOT/daily" "$ROOT/weekly"

  # Set BEFORE any guard that can exit -- the free-space guard and the lock
  # contention check are both below, and they are the likeliest failures, so a
  # trap installed after them would miss exactly the runs worth reporting.
  #
  # ONE trap, covering INT/TERM as well as EXIT. Two reasons this is not the
  # obvious `trap ... EXIT`: a later `trap` in this file REPLACES an earlier one
  # rather than adding to it, and bash does not run an EXIT trap when the shell
  # dies from an untrapped SIGTERM -- exactly what systemd sends on
  # TimeoutStartSec. Without INT/TERM a timed-out run leaves no verdict, which
  # is the failure this whole thing exists to make visible.
  PHASE=starting
  trap 'rc=$?; rm -f "${tmp_db:-}" "${tmp_zst:-}"; write_status "$rc" "${PHASE:-unknown}"' EXIT INT TERM

  # After the trap on purpose: an unreadable database is a failure worth
  # reporting, and reporting it is the entire point of the trap.
  [ -r "$DB" ] || { err "database not readable: $DB"; PHASE=unreadable-db; exit 1; }
  exec 9>"$ROOT/.lock"
  flock -n 9 || { err "another backup run holds $ROOT/.lock"; PHASE=locked; exit 1; }

  # Refuse rather than fill the disk: need room for the uncompressed copy plus
  # the compressed one, with a margin. On the current 21 MB DB this is ~100 MB.
  local need_bytes avail_bytes
  need_bytes=$(( ( $(stat -c %s "$DB") + $(stat -c %s "$DB-wal" 2>/dev/null || echo 0) ) * 3 ))
  avail_bytes=$(df --output=avail -B1 "$ROOT" | tail -1)
  if [ "$avail_bytes" -lt "$need_bytes" ]; then
    log "FAIL free-space guard: need $need_bytes B, have $avail_bytes B on $ROOT"
    PHASE=free-space
    exit 1
  fi

  # tmp_db / tmp_zst are deliberately NOT local: the EXIT trap that removes
  # them runs at top level, where a function-local would already be gone.
  local stamp base final info t0
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  base="manhwamaniacs-$stamp.db"
  tmp_db="$ROOT/daily/.$base.tmp"
  tmp_zst="$ROOT/daily/.$base.zst.tmp"
  final="$ROOT/daily/$base.zst"
  t0=$(date +%s)

  PHASE=snapshot
  if ! info="$(snapshot "$DB" "$tmp_db")"; then
    log "FAIL snapshot/integrity: ${info:-no output}"
    exit 1
  fi

  PHASE=compress
  zstd -q -T0 "-$ZSTD_LEVEL" "$tmp_db" -o "$tmp_zst"
  rm -f "$tmp_db"
  mv -f "$tmp_zst" "$final"            # same directory: atomic rename
  sync -f "$final"                     # flush the filesystem holding it
  ln -sfn "daily/$base.zst" "$ROOT/latest.db.zst"

  # Weekly: hard-link (no extra space) the first successful run of each ISO
  # week, so every weekly slot is a distinct week. It used to link every run
  # on a Sunday: a manual run or a stage-restore on a Sunday took a second slot
  # for the same week (the live box held 4 weeklies covering 3 weeks), and a
  # Sunday whose run failed, or that the box slept through, left its week with
  # none at all. The week is read from the NEWEST weekly's own name rather than
  # a stamp file, so deleting or restoring files by hand cannot desync it, and
  # an empty weekly/ (a fresh install) links straight away. Both sides come from
  # the run stamps, not a second `date` call, so a run that straddles midnight
  # into Monday is judged by the week it was taken in.
  local this_week last_weekly last_week=""
  this_week="$(date -u -d "${stamp%%-*}" +%G-W%V)"
  last_weekly="$(ls -1 "$ROOT/weekly"/manhwamaniacs-*.db.zst 2>/dev/null | sort | tail -n 1 || true)"
  if [ -n "$last_weekly" ]; then
    last_weekly="${last_weekly##*/manhwamaniacs-}"
    last_week="$(date -u -d "${last_weekly%%-*}" +%G-W%V 2>/dev/null || true)"
  fi
  if [ "$this_week" != "$last_week" ]; then
    ln -f "$final" "$ROOT/weekly/$base.zst"
  fi

  # Rotation: names sort chronologically. Keep the newest N of each tier.
  ls -1 "$ROOT/daily"/manhwamaniacs-*.db.zst  2>/dev/null | sort | head -n "-$KEEP_DAILY"  | xargs -r rm -f
  ls -1 "$ROOT/weekly"/manhwamaniacs-*.db.zst 2>/dev/null | sort | head -n "-$KEEP_WEEKLY" | xargs -r rm -f

  # Refreshed in place beside the rotated snapshots. Deliberately NOT one file
  # per run: the rotation globs manhwamaniacs-*.db.zst, so a second timestamped
  # artefact per run would accumulate forever with nothing pruning it.
  local settings_state="absent"
  if [ -r "$SETTINGS" ]; then
    if cp -f "$SETTINGS" "$ROOT/settings.json.bak.tmp" \
       && mv -f "$ROOT/settings.json.bak.tmp" "$ROOT/settings.json.bak"; then
      settings_state="saved"
    else
      settings_state="FAILED"
      rm -f "$ROOT/settings.json.bak.tmp"
    fi
  fi

  PHASE=done
  local zst_bytes total_bytes
  zst_bytes=$(stat -c %s "$final")
  STATUS_BYTES="$zst_bytes"
  total_bytes=$(du -sb "$ROOT" | cut -f1)
  log "OK $final zst_bytes=$zst_bytes elapsed_s=$(( $(date +%s) - t0 )) backups_total_bytes=$total_bytes settings=$settings_state info=$info"
}

cmd_verify(){
  need zstd; need "$PY"
  local src="${1:-$ROOT/latest.db.zst}"
  [ -r "$src" ] || { err "no backup at $src"; exit 1; }
  src="$(readlink -f "$src")"          # zstd refuses to read through a symlink
  # verify_tmp is not local for the same reason as tmp_db above.
  verify_tmp="$(mktemp -d "${TMPDIR:-/tmp}/mm-verify.XXXXXX")"
  trap 'rm -rf "${verify_tmp:-}"' EXIT
  zstd -q -d "$src" -o "$verify_tmp/restore.db"
  say "verifying $src ($(stat -c %s "$verify_tmp/restore.db") bytes uncompressed)"
  "$PY" - "$verify_tmp/restore.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
ic = [r[0] for r in c.execute("PRAGMA integrity_check")]
print("integrity_check:", ic[:5])
print("alembic_version:", c.execute("SELECT version_num FROM alembic_version").fetchone())
for t in ("users", "reading_profiles", "followed_series", "chapter_progress", "bookmarks"):
    try:
        print(f"{t:18s}", c.execute(f"SELECT count(*) FROM {t}").fetchone()[0])
    except sqlite3.Error as e:
        print(f"{t:18s} ? ({e})")
sys.exit(0 if ic == ["ok"] else 1)
PY
}

cmd_list(){
  say "daily  ($KEEP_DAILY kept):";  ls -lh "$ROOT/daily"  2>/dev/null | grep -v '^total' || true
  say "weekly ($KEEP_WEEKLY kept):"; ls -lh "$ROOT/weekly" 2>/dev/null | grep -v '^total' || true
  say "latest -> $(readlink "$ROOT/latest.db.zst" 2>/dev/null || echo none)"
  say "total: $(du -sh "$ROOT" 2>/dev/null | cut -f1)"
  [ -f "$LOG" ] && { say "last runs:"; tail -n 5 "$LOG"; }
}

cmd_stage_restore(){
  need zstd
  local src="${1:-}"
  [ -n "$src" ] && [ -r "$src" ] || { err "usage: $0 stage-restore FILE.zst"; exit 2; }
  src="$(readlink -f "$src")"
  local pending="$DB.pending-restore"
  cat <<EOT

  ############################################################################
  ##  DESTRUCTIVE: on the backend's next start the live database is        ##
  ##  REPLACED by $(readlink -f "$src")
  ##  Everything written after that backup was taken is lost. The backend   ##
  ##  moves the database it replaces aside as <db>.pre-restore-<stamp>      ##
  ##  (core/backup_restore.py), and this command also takes a fresh backup  ##
  ##  first; the Undo line printed at the end names that exact file.        ##
  ############################################################################

EOT
  if [ "${MM_CONFIRM:-}" != "RESTORE" ]; then
    err "refusing: re-run with MM_CONFIRM=RESTORE $0 stage-restore $src"; exit 2
  fi
  say "taking a pre-restore backup first"; cmd_run
  # Resolved NOW, while latest.db.zst still points at the copy just taken. The
  # symlink moves on every run, so an Undo that named it would, after the next
  # 03:30 run, restore a snapshot of the RESTORED data and silently undo
  # nothing, while the real pre-restore copy sat in daily/ under a name nobody
  # was shown.
  local pre
  pre="$(readlink -f "$ROOT/latest.db.zst")"
  say "verifying the file you are about to restore"; cmd_verify "$src"
  zstd -q -d "$src" -o "$pending.tmp"; mv -f "$pending.tmp" "$pending"
  say "staged: $pending"
  cat <<EOT
  Now:   docker restart manhwamaniacs-backend
  then:  docker logs --since 2m manhwamaniacs-backend | grep -i restore
         (expect "Applied a staged database restore before startup.")
  Undo:  MM_CONFIRM=RESTORE $0 stage-restore $pre
         (the pre-restore copy just taken; it stays in daily/ for $KEEP_DAILY runs)
  Abort before restarting:  rm -f $pending
EOT
}

case "${1:-}" in
  run)            cmd_run ;;
  verify)         cmd_verify "${2:-}" ;;
  list)           cmd_list ;;
  stage-restore)  cmd_stage_restore "${2:-}" ;;
  *) echo "usage: $0 {run|verify [FILE.zst]|list|stage-restore FILE.zst}"; exit 2 ;;
esac
