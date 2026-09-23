#!/usr/bin/env bash
# =============================================================================
# Push this working tree to the VPS and redeploy. Run from the LAPTOP.
#
# The VPS checkout has no .git (the repo is rsynced, not cloned — pushing to
# GitHub from this laptop has no credentials yet), so "deploy" means: sync the
# source, then rebuild the images there. The commit id is carried across in
# .deploy-info so the running containers can still be traced to a revision.
#
#   ops/vps/push.sh              sync frontend+backend+ops, rebuild, restart
#   ops/vps/push.sh frontend     sync only the frontend, rebuild, restart
#   ops/vps/push.sh backend      sync only the backend, rebuild, restart
#   ops/vps/push.sh apk          copy the built release APK to the app subdomain
#
# Gates: a full or frontend push runs the frontend build locally first, because
# a Next build failure on the VPS leaves the old container up but wastes a slow
# remote rebuild — and the box has 2 vCores. A full or backend push runs the
# backend test suite first, for the same reason and a worse one: unlike a failed
# Next build, a backend that imports cleanly and behaves wrongly starts happily
# and serves the fault. `apk` checks what is inside the APK before publishing
# it: /app/download serves ONE file to every phone, so an APK that is missing an
# ABI is not a smaller download, it is a friend staring at "App not installed"
# with nothing on screen to explain why.
#
# MM_SKIP_TESTS=1 bypasses the backend gate. It exists for an incident where the
# fix matters more than the suite; it prints a warning because a bypass that is
# quiet becomes the default.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${MM_VPS_HOST:-ubuntu@135.148.43.147}"
REMOTE="${MM_VPS_PATH:-/srv/manhwamaniacs/app}"
NODE_BIN="${MM_NODE_BIN:-/home/yash/.local/node/bin}"
PY_BIN="${MM_PY_BIN:-$REPO/backend/.venv/bin/python}"

RSYNC_EXCLUDES=(
  --exclude .git
  --exclude node_modules
  --exclude .next
  --exclude .venv
  --exclude __pycache__
  --exclude '*.pyc'
  --exclude .pytest_cache
  --exclude manhwamaniacs.db
  --exclude build
  --exclude .dart_tool
  # Gradle/NDK scratch. mobile/android/.gradle alone is ~25 MB of pure cache on
  # a box whose whole disk budget is the point of the VPS move.
  --exclude .gradle
  --exclude .cxx
  --exclude captures
  # SECRETS. Nothing on the VPS builds an APK, so the release signing key has no
  # business travelling there — and `all` used to rsync mobile/ wholesale, which
  # carried android/key.properties (passwords in plaintext) and
  # android/app/manhwamaniacs-upload.jks with it. Belt and braces alongside
  # sync_mobile_meta below, so any future sync_dir call is safe by default.
  --exclude key.properties
  --exclude '*.jks'
  --exclude '*.keystore'
  --exclude .env
)

say(){ printf '\033[32m==>\033[0m %s\n' "$*"; }

verify_frontend(){
  say "building the frontend locally (fail fast before a slow remote rebuild)"
  ( cd "$REPO/frontend" && PATH="$NODE_BIN:$PATH" npm run build >/dev/null )
  say "local build OK"
}

verify_backend(){
  if [ "${MM_SKIP_TESTS:-0}" = "1" ]; then
    printf '\033[33m==>\033[0m %s\n' \
      "MM_SKIP_TESTS=1 — shipping the backend WITHOUT running its tests"
    return 0
  fi
  if [ ! -x "$PY_BIN" ]; then
    echo "no backend interpreter at $PY_BIN (set MM_PY_BIN)" >&2
    exit 1
  fi
  say "running the backend test suite (fail fast before a slow remote rebuild)"
  ( cd "$REPO/backend" && "$PY_BIN" -m pytest -q -x --no-header )
  say "backend tests OK"
}

sync_dir(){
  local dir="$1"
  say "syncing $dir/"
  rsync -az --delete -e "ssh -o BatchMode=yes" "${RSYNC_EXCLUDES[@]}" \
    "$REPO/$dir/" "$HOST:$REMOTE/$dir/"
}

sync_mobile_meta(){
  # The VPS runs no Flutter build; ops/vps/docker-compose.yml mounts exactly two
  # things out of mobile/ — pubspec.yaml (the /app/version label) and
  # docs/screenshots (the landing page + SideStore listing imagery). `all` used
  # to rsync the whole of mobile/, which pushed ~30 MB of Dart source, tests and
  # Gradle cache, plus the release signing key and its plaintext passwords, onto
  # a production host that needs none of it.
  say "syncing mobile/ metadata (pubspec + screenshots only)"
  rsync -a --inplace -e "ssh -o BatchMode=yes" \
    "$REPO/mobile/pubspec.yaml" "$HOST:$REMOTE/mobile/pubspec.yaml"
  rsync -az --delete -e "ssh -o BatchMode=yes" "${RSYNC_EXCLUDES[@]}" \
    "$REPO/mobile/docs/screenshots/" "$HOST:$REMOTE/mobile/docs/screenshots/"
  # Everything mobile/ that earlier pushes left behind stays where it is —
  # rsync only deletes inside a directory it is syncing. That is harmless for
  # stale Dart source and NOT harmless for the signing key, so say so rather
  # than reach into a production host and delete things from a script.
  local leftover
  leftover="$(ssh -o BatchMode=yes "$HOST" \
    "ls -1 $REMOTE/mobile/android/key.properties $REMOTE/mobile/android/app/*.jks 2>/dev/null" || true)"
  if [ -n "$leftover" ]; then
    cat >&2 <<EOF

  !! The release signing key is still on the VPS from an earlier push:
$(sed 's/^/       /' <<<"$leftover")
     Nothing there uses it. Remove it by hand, then rotate if you want to be
     thorough (a new key means everyone reinstalls once):
       ssh $HOST 'rm -rf $REMOTE/mobile/android $REMOTE/mobile/lib $REMOTE/mobile/test'

EOF
  fi
}

# ABIs an APK can actually RUN on, one per line (e.g. arm64-v8a, armeabi-v7a).
#
# A lib/<abi>/ directory on its own proves nothing. Several plugins ship
# prebuilt .so files for every architecture whatever the build targets, so
# `flutter build apk --target-platform android-arm64` still leaves a 79 KB
# lib/armeabi-v7a/ behind — enough to fool a directory listing, nowhere near
# enough to start the app. An ABI counts only when both halves of Flutter are
# there: the engine (libflutter.so) and the app's compiled Dart (libapp.so).
apk_abis(){
  local names abi
  names="$(unzip -Z1 "$1" 2>/dev/null)"
  while read -r abi; do
    [ -n "$abi" ] || continue
    # An `if`, not `grep ... && echo`: under `set -e` a failing AND-list as the
    # last command of a loop body aborts the whole script, so the one APK this
    # check exists to catch — engine present, libapp.so missing — would have
    # exited 1 with nothing printed instead of refusing out loud.
    if grep -qx "lib/$abi/libapp.so" <<<"$names"; then echo "$abi"; fi
  done < <(sed -n 's|^lib/\([^/]*\)/libflutter\.so$|\1|p' <<<"$names" | sort -u)
}

# Refuse to publish an APK that some phone in the owner's circle cannot install.
# The release build packages arm64-v8a + armeabi-v7a and drops x86_64
# (mobile/android/app/build.gradle.kts). Both ARM ABIs must be present: 64-bit
# covers everything modern, and armeabi-v7a is the 32-bit-only budget hardware
# that is still inside minSdk 24. A --split-per-abi build does not produce
# app-release.apk at all, so it fails the earlier existence check instead.
# versionName+versionCode read out of the APK itself. A Flutter release build
# can FAIL while still exiting 0 — a bad JAVA_HOME does exactly that — and it
# leaves the PREVIOUS apk sitting in build/app/outputs/ for this script to
# publish. Comparing file size or mtime does not catch it either: two releases
# whose only difference is a same-length version string can weigh exactly the
# same to the byte, which 2.2.0 and 2.3.0 did.
apk_version(){
  local aapt
  aapt="$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/*/aapt2 2>/dev/null \
          | sort -V | tail -1)"
  [ -x "$aapt" ] || return 1
  "$aapt" dump badging "$1" 2>/dev/null \
    | sed -n "s/.*versionCode='\([^']*\)'.*versionName='\([^']*\)'.*/\2+\1/p" \
    | head -1
}

# Build the APK this script is about to publish, with the dart-defines a
# production build REQUIRES.
#
# Why this exists: `apk` used to only grade an APK you had built in another
# shell, and the rebuild command it suggested omitted both defines. Without them
# Env.flavor is 'dev' and Env.defaultApiUrl is http://127.0.0.1:8000
# (mobile/lib/core/config/env.dart:7-16), so hasBakedProductionUrl is false and a
# FRESH install opens the manual setup screen pre-filled with localhost instead
# of connecting — and allowInsecureBaseUrl becomes true, defeating the
# https-only rule that exists so the bearer token never travels in clear text.
# 2.7.3 shipped exactly that way. An existing install hides it, because the
# server URL lives in secure storage.
#
# JAVA_HOME is equally load-bearing: without JDK 17 Gradle fails while still
# exiting 0, leaving the PREVIOUS apk in build/app/outputs for this script to
# publish.
APK_API_URL="${MM_APK_API_URL:-https://app.manhwamaniacs.xyz}"
APK_JAVA_HOME="${MM_APK_JAVA_HOME:-$HOME/jdk17}"

build_apk(){
  local flutter_bin="${MM_FLUTTER:-$HOME/flutter/bin/flutter}"
  [ -x "$flutter_bin" ] || { echo "!! no flutter at $flutter_bin (set MM_FLUTTER)" >&2; exit 1; }
  [ -d "$APK_JAVA_HOME" ] || { echo "!! no JDK 17 at $APK_JAVA_HOME (set MM_APK_JAVA_HOME)" >&2; exit 1; }
  say "building the release APK (FLAVOR=prod, API_URL=$APK_API_URL)"
  ( cd "$REPO/mobile" && JAVA_HOME="$APK_JAVA_HOME" "$flutter_bin" build apk --release \
      --dart-define=FLAVOR=prod \
      --dart-define=API_URL="$APK_API_URL" ) \
    || { echo "!! flutter build apk failed" >&2; exit 1; }
}

# The production API URL must be COMPILED IN, not merely passed on a command
# line that may have been forgotten. dart-defines land in libapp.so, so read it
# back out of the artifact — the only check that cannot be fooled by a build
# that failed and left the previous apk behind.
verify_apk_is_production(){
  local apk="$1" host
  host="${APK_API_URL#https://}"; host="${host%%/*}"
  python3 - "$apk" "$host" <<'PYBAKED'
import sys, zipfile
apk, host = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk) as z:
    names = [n for n in z.namelist() if n.endswith("/libapp.so")]
    if not names:
        print("!! no libapp.so in the APK — cannot confirm the baked URL", file=sys.stderr)
        raise SystemExit(3)
    blob = z.read(names[0])
if blob.count(host.encode()) == 0:
    print(f"!! REFUSING TO PUBLISH: {host} is not compiled into this APK.", file=sys.stderr)
    print( "   It was built without --dart-define=API_URL, so it defaults to", file=sys.stderr)
    print( "   http://127.0.0.1:8000 and a fresh install lands on the setup", file=sys.stderr)
    print( "   screen instead of connecting. Rebuild via: ops/vps/push.sh apk", file=sys.stderr)
    raise SystemExit(3)
print(f"   production URL baked in: {host}")
PYBAKED
}

verify_apk(){
  local apk="$1" abis missing=""
  local want got
  want="$(sed -n 's/^version: *//p' "$REPO/mobile/pubspec.yaml" | head -1 | tr -d '[:space:]')"
  got="$(apk_version "$apk")" || got=""
  if [ -z "$got" ]; then
    say "note: no aapt2 on this machine — cannot confirm the APK's version"
  elif [ "$got" != "$want" ]; then
    cat >&2 <<EOF
!! REFUSING TO PUBLISH: this APK is $got, but mobile/pubspec.yaml says $want.
   A Flutter release build can fail and still exit 0, leaving the PREVIOUS apk
   in build/app/outputs/ for this script to find. Rebuild before publishing:
     ops/vps/push.sh apk
   Do NOT hand-run `flutter build apk --release`: without
   --dart-define=FLAVOR=prod --dart-define=API_URL=https://app.manhwamaniacs.xyz
   the APK defaults to http://127.0.0.1:8000 and a fresh install cannot connect.
EOF
    exit 3
  else
    say "APK version: $got (matches the pubspec)"
  fi
  abis="$(apk_abis "$apk")"
  [ -n "$abis" ] || {
    echo "!! $apk carries no runnable ABI (no lib/<abi>/ with both libflutter.so" >&2
    echo "   and libapp.so in it) — refusing" >&2; exit 3; }
  for want in arm64-v8a armeabi-v7a; do
    grep -qx "$want" <<<"$abis" || missing="$missing $want"
  done
  if [ -n "$missing" ]; then
    cat >&2 <<EOF
!! REFUSING TO PUBLISH: this APK cannot run on:$missing
   it runs on: $(tr '\n' ' ' <<<"$abis")
   /app/download hands one file to every phone. Publishing this one means any
   friend on a missing architecture gets "App not installed" and no reason why.
   Rebuild with: flutter build apk --release
   (If per-ABI downloads are what you want, that needs a serving change in
    backend/routes/app_distribution.py first — see the ops notes.)
EOF
    exit 3
  fi
  if grep -qx "x86_64" <<<"$abis"; then
    say "note: this APK still carries x86_64 (~21 MB no phone can use) — the"
    say "      release exclusion in android/app/build.gradle.kts did not apply"
  fi
  say "APK check: $(du -h "$apk" | cut -f1), runs on [$(tr '\n' ' ' <<<"$abis" | sed 's/ $//')], built $(( ( $(date +%s) - $(stat -c %Y "$apk") ) / 60 )) min ago"
}

stamp(){
  local commit branch
  commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)"
  branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  printf '%s  %s  %s\n' "$commit" "$(date -u +%FT%TZ)" "$branch" \
    | ssh -o BatchMode=yes "$HOST" "cat > $REMOTE/.deploy-info"
  echo "$commit $branch"
}

remote_deploy(){
  local commit="$1" branch="$2"
  say "rebuilding on the VPS ($branch @ $commit)"
  ssh -o BatchMode=yes "$HOST" \
    "cd $REMOTE && GIT_COMMIT=$commit GIT_BRANCH=$branch bash ops/vps/deploy.sh deploy"
}

case "${1:-all}" in
  all)
    verify_backend
    verify_frontend
    sync_dir frontend; sync_dir backend; sync_dir ops; sync_mobile_meta
    read -r c b < <(stamp); remote_deploy "$c" "$b" ;;
  frontend)
    verify_frontend
    sync_dir frontend; sync_dir ops
    read -r c b < <(stamp); remote_deploy "$c" "$b" ;;
  backend)
    verify_backend
    sync_dir backend; sync_dir ops
    read -r c b < <(stamp); remote_deploy "$c" "$b" ;;
  apk)
    APK="$REPO/mobile/build/app/outputs/flutter-apk/app-release.apk"
    # Build it here unless explicitly told not to. Publishing an artifact this
    # script did not produce is how a dev-flavour APK reached /app/download.
    [ "${MM_APK_NO_BUILD:-0}" = 1 ] || build_apk
    if [ ! -f "$APK" ]; then
      echo "no APK at $APK — run the release build first:" >&2
      echo "    (cd mobile && flutter build apk --release)" >&2
      # --split-per-abi writes app-arm64-v8a-release.apk et al and never
      # app-release.apk, so this is the message that build lands on too.
      ls "$REPO/mobile/build/app/outputs/flutter-apk/"*.apk >/dev/null 2>&1 \
        && { echo "  (found per-ABI split APKs instead — /app/download serves a" >&2
             echo "   single file, so publish a normal universal build)" >&2; }
      exit 1
    fi
    verify_apk "$APK"
    verify_apk_is_production "$APK"
    say "publishing the APK"
    # The version endpoint reads the pubspec through a single-FILE bind mount,
    # and `apk` is usually run on its own — so without this the box happily
    # serves a 1.9.0 APK while /app/version still advertises the previous
    # release. --inplace is load-bearing: replacing a bind-mounted file
    # normally leaves the container holding the old inode, which would need a
    # container recreate to clear.
    say "syncing the pubspec the version endpoint reads"
    rsync -a --inplace -e "ssh -o BatchMode=yes" \
      "$REPO/mobile/pubspec.yaml" "$HOST:$REMOTE/mobile/pubspec.yaml"
    # Same-filesystem temp + mv so the backend never serves a half-written file.
    scp -o BatchMode=yes "$APK" "$HOST:/srv/manhwamaniacs/apk/.app-release.apk.tmp"
    ssh -o BatchMode=yes "$HOST" \
      'mv -f /srv/manhwamaniacs/apk/.app-release.apk.tmp /srv/manhwamaniacs/apk/app-release.apk \
       && sudo chown 1000:1000 /srv/manhwamaniacs/apk/app-release.apk \
       && ls -lh /srv/manhwamaniacs/apk/app-release.apk'
    say "https://app.manhwamaniacs.xyz now serves it" ;;
  *)
    echo "usage: $0 {all|frontend|backend|apk}" >&2; exit 2 ;;
esac
