#!/usr/bin/env bash
# =============================================================================
# Cron entry point for the iOS build sync.
#
# Wraps ops/fetch-ios-build.sh so a 10-minute poll stays quiet: the script is
# chatty by design when run by hand, but ~144 runs a day of "nothing to do"
# would bury the lines worth reading. Output is logged only when something
# actually happened (a new build published, or an error), and cron itself stays
# silent because all output is captured rather than printed.
#
# Install (as root — see ops/vps/manhwamaniacs-ios-sync.cron):
#   sudo install -m 644 ops/vps/manhwamaniacs-ios-sync.cron \
#        /etc/cron.d/manhwamaniacs-ios-sync
#
# Exit code mirrors fetch-ios-build.sh, except "nothing new" (2) is reported as
# success so a failed run is distinguishable in the log.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${MM_IOS_SYNC_LOG:-/var/log/manhwamaniacs-ios-sync.log}"
MAX_BYTES=$(( 1024 * 1024 ))

out="$("$HERE/fetch-ios-build.sh" "$@" 2>&1)"
rc=$?

# 2 = "this run is already published" — the normal, boring case between pushes.
if [ "$rc" -eq 2 ]; then
  exit 0
fi

# Self-trimming so this needs no logrotate config of its own.
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_BYTES" ]; then
  tail -c "$(( MAX_BYTES / 2 ))" "$LOG" > "$LOG.tmp" 2>/dev/null \
    && mv -f "$LOG.tmp" "$LOG"
fi

{
  echo "── $(date -u '+%Y-%m-%d %H:%M:%S UTC')  (exit $rc)"
  # The script colours its output for a terminal; strip the escapes so the log
  # stays greppable.
  printf '%s\n' "$out" | sed -e 's/\x1b\[[0-9;]*m//g'
} >> "$LOG" 2>/dev/null

exit "$rc"
