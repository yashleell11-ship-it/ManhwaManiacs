#!/usr/bin/env bash
# Keep the desktop rendering audiobooks, and keep Neiro off it.
#
# The priority here is the OPPOSITE of gpu-watchdog.sh, which existed to keep
# training alive. Yash has stopped Neiro deliberately and asked for the card to
# go to TTS, so this holds that arrangement: if the training task ever
# re-enables itself — it has a boot trigger, and Neiro re-chains it — this
# disables it again rather than letting it take the card back mid-render.
#
# It also survives the desktop going away. The box reboots, sleeps, and moves
# between the LAN cable and tailscale; a render task is not restarted by a
# reboot on its own, so on every reconnect this checks whether there is still
# work and starts it.
#
# Tries the LAN cable first: sub-millisecond, and it does not depend on a
# coordination server being up.

set -uo pipefail
# State (log, lock, pause file) stays on the machine; the SCRIPTS live in the
# repo, because they encode decisions worth versioning and reviewing.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS="${MM_RENDER_OPS:-$HOME/.local/state/manhwamaniacs}"
mkdir -p "$OPS"
LOG="$OPS/render-watchdog.log"
say() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

exec 9>"$OPS/.render-watchdog.lock"
flock -n 9 || exit 0

[[ -f "$OPS/PAUSE" ]] && { say "paused by hand"; exit 0; }

enc() { python3 -c "import base64,pathlib,sys;print(base64.b64encode(pathlib.Path(sys.argv[1]).read_text().encode('utf-16-le')).decode())" "$1"; }

host=""
for candidate in box-lan box; do
    if timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=8 "$candidate" "echo ok" >/dev/null 2>&1; then
        host="$candidate"; break
    fi
done
if [[ -z "$host" ]]; then
    say "box UNREACHABLE on both the cable and tailscale -- nothing to do"
    exit 0
fi

state=$(timeout 60 ssh -o BatchMode=yes "$host" \
    "powershell -NoProfile -EncodedCommand $(enc "$HERE/render-watch.ps1")" 2>/dev/null)
get() { grep -ao "^$1=[^[:cntrl:]]*" <<<"$state" | head -1 | cut -d= -f2- | tr -d '\r'; }

neiro=$(get NEIRO); trainers=$(get TRAINERS); render=$(get RENDER)
plans=$(get PLANS);  done_n=$(get DONE);      finished=$(get FINISHED)
gpu=$(get GPU)

say "via $host | neiro=$neiro trainers=$trainers | render=$render ${done_n}/${plans} finished=$finished | gpu=$gpu"

# Neiro must stay off the card until Yash says otherwise.
if [[ "$neiro" != "Disabled" || "${trainers:-0}" != "0" ]]; then
    say "ACTION Neiro is back (state=$neiro trainers=$trainers) -- disabling and stopping"
    timeout 90 ssh -o BatchMode=yes "$host" 'powershell -NoProfile -Command "Disable-ScheduledTask -TaskName NeiroBoxPersonaTrain -EA SilentlyContinue | Out-Null; Stop-ScheduledTask -TaskName NeiroBoxPersonaTrain -EA SilentlyContinue; Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like \"*persona_train.py*\" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }"' >/dev/null 2>&1
fi

# And the render should be working if there is anything left to render.
if [[ "$finished" == "yes" ]]; then
    say "render finished -- $done_n chapters on disk"
elif [[ "$render" == "Running" ]]; then
    :  # already working
elif [[ "${plans:-0}" != "0" ]]; then
    say "ACTION render is $render with $plans plans and $done_n done -- starting it"
    timeout 90 ssh -o BatchMode=yes "$host" \
        'powershell -NoProfile -Command "Start-ScheduledTask -TaskName MMRenderBatch"' >/dev/null 2>&1
fi
exit 0
