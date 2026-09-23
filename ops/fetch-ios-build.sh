#!/usr/bin/env bash
# =============================================================================
# Publish the latest CI-built iOS .ipa so SideStore can install it over the air.
#
# iOS builds can't be produced here — they need macOS — so they come from the
# GitHub Actions mirror (.github/workflows/ios-build.yml) which runs on a free
# cloud Mac. This script downloads the newest build and drops it where the
# backend serves it from (see backend/routes/app_distribution.py, MM_IPA_PATH).
# Together with /app/source.json that turns an iOS update into a single tap on
# the phone instead of a manual download-and-sideload.
#
# Two sources, tried in order:
#   1. The newest GitHub *release* asset. Anonymous — no credentials needed on
#      this machine at all, because the repo is public.
#   2. The workflow *artifact*, which needs a token with Actions:read. GitHub
#      demands authentication for artifact downloads even from a public repo,
#      which is exactly why the release path exists and is preferred.
#
# Usage:
#   ops/fetch-ios-build.sh [dest-dir]        # default: /srv/manhwamaniacs/ipa
#
# Exit codes: 0 published, 1 error, 2 nothing new to do.
# =============================================================================
set -uo pipefail

REPO="${MM_IOS_REPO:-yashleell11-ship-it/ManhwaManiacs}"
WORKFLOW="${MM_IOS_WORKFLOW:-ios-build.yml}"
BRANCH="${MM_IOS_BRANCH:-feat/vps-slim-source-native}"
ARTIFACT="${MM_IOS_ARTIFACT:-ManhwaManiacs-ipa}"
DEST="${1:-/srv/manhwamaniacs/ipa}"
STAMP="$DEST/.published-run"

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
say(){ echo "${c_grn}==>${c_rst} $*"; }
warn(){ echo "${c_ylw}!! $*${c_rst}"; }
err(){ echo "${c_red}!! $*${c_rst}" >&2; }

# Serialise publish runs. A 10-minute cron and a 15-minute systemd timer have
# both been installed against this directory at once, and they align every half
# hour. The publish itself is atomic — same-filesystem temp plus `mv -f` — so a
# phone never sees a half-written IPA. What overlapping runs actually cost is a
# duplicate 10 MB download and a read-then-write race on .published-run, spent
# against an anonymous GitHub API budget of 60 requests an hour.
exec 9>"${TMPDIR:-/tmp}/mm-fetch-ios.lock"
if ! flock -n 9; then
  say "another publish run holds the lock — nothing to do"
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A token is optional: only the artifact fallback needs one.
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -r "$HOME/.gh_token" ]; then
  TOKEN="$(tr -d '[:space:]' < "$HOME/.gh_token")"
fi

api(){
  if [ -n "$TOKEN" ]; then
    curl -sS -m 60 -H "Authorization: Bearer $TOKEN" \
                   -H "Accept: application/vnd.github+json" \
                   -H "X-GitHub-Api-Version: 2022-11-28" "$@"
  else
    curl -sS -m 60 -H "Accept: application/vnd.github+json" \
                   -H "X-GitHub-Api-Version: 2022-11-28" "$@"
  fi
}

# ── publish atomically ───────────────────────────────────────────────────────
# $1 = .ipa path, $2 = ios-build.json path (may not exist), $3 = stamp value
publish_files(){
  local ipa="$1" meta="$2" stamp_value="$3" size advertised

  # An .ipa is a zip — a truncated download would otherwise be served to phones
  # as a valid-looking file that fails to install with no useful error.
  #
  # Pick a verifier that actually EXISTS. `unzip -qt` on a host without unzip
  # exits non-zero exactly like a corrupt file does, so the bare check reported
  # a perfectly good .ipa as truncated and refused to publish it for hours
  # (that happened; the VPS image ships no unzip). Fall back to python's
  # zipfile, and only skip the check — loudly — when neither is available.
  if command -v unzip >/dev/null 2>&1; then
    if ! unzip -qt "$ipa" >/dev/null 2>&1; then
      err "downloaded .ipa is not a valid archive — refusing to publish"; return 1
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import sys,zipfile; sys.exit(0 if zipfile.is_zipfile(sys.argv[1]) and zipfile.ZipFile(sys.argv[1]).testzip() is None else 1)" "$ipa"; then
      err "downloaded .ipa is not a valid archive — refusing to publish"; return 1
    fi
  else
    warn "no unzip and no python3 — cannot verify the .ipa, publishing unchecked"
  fi

  mkdir -p "$DEST" || { err "cannot create $DEST"; return 1; }
  # Same-filesystem temp + mv so the backend never serves a half-written file.
  cp "$ipa" "$DEST/.ManhwaManiacs.ipa.tmp" \
    && mv -f "$DEST/.ManhwaManiacs.ipa.tmp" "$DEST/ManhwaManiacs.ipa" \
    || { err "failed to write $DEST/ManhwaManiacs.ipa"; return 1; }

  # The metadata names the version the manifest advertises, so it is published
  # *after* the binary: a crash between the two leaves phones briefly seeing the
  # old version number (nothing offered, corrected on the next run), whereas the
  # reverse order would offer an update that hands back the previous .ipa.
  if [ -f "$meta" ] && python3 -m json.tool "$meta" >/dev/null 2>&1; then
    cp "$meta" "$DEST/.ios-build.json.tmp" \
      && mv -f "$DEST/.ios-build.json.tmp" "$DEST/ios-build.json" \
      || { err "failed to write $DEST/ios-build.json"; return 1; }
  else
    warn "no valid ios-build.json alongside the build — the manifest will fall"
    warn "back to pubspec numbers and will not advertise this as an update"
  fi

  echo "$stamp_value" > "$STAMP"
  # Match the APK drop's ownership so the container (uid 1000) can read it.
  chown -R 1000:1000 "$DEST" 2>/dev/null || true

  size="$(stat -c%s "$DEST/ManhwaManiacs.ipa" 2>/dev/null || echo '?')"
  say "published $DEST/ManhwaManiacs.ipa ($size bytes)"
  if [ -r "$DEST/ios-build.json" ]; then
    advertised="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m.get("version", "?"), "build", m.get("buildVersion", "?"))
' "$DEST/ios-build.json" 2>/dev/null)" || advertised="(unreadable)"
    say "SideStore will advertise $advertised"
  fi
  return 0
}

# ── source 1: newest release asset (anonymous) ───────────────────────────────
publish_from_release(){
  local json tag ipa_url meta_url
  json="$(api "https://api.github.com/repos/$REPO/releases/latest")" || return 1

  read -r tag ipa_url meta_url < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
assets = {a["name"]: a["browser_download_url"] for a in d.get("assets") or []}
ipa = next((u for n, u in assets.items() if n.endswith(".ipa")), "")
if "tag_name" not in d or not ipa:
    sys.exit(1)
print(d["tag_name"], ipa, assets.get("ios-build.json", "-"))
' <<< "$json") || return 1

  say "latest release: $tag"
  if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$tag" ]; then
    say "release $tag already published — nothing to do"
    return 2
  fi

  say "downloading release assets (no credentials required)"
  curl -sSL -m 600 -o "$TMP/ManhwaManiacs.ipa" "$ipa_url" \
    || { err "ipa download failed"; return 1; }
  if [ "$meta_url" != "-" ]; then
    curl -sSL -m 60 -o "$TMP/ios-build.json" "$meta_url" || true
  fi

  publish_files "$TMP/ManhwaManiacs.ipa" "$TMP/ios-build.json" "$tag"
}

# ── source 2: workflow artifact (needs a token) ──────────────────────────────
publish_from_artifact(){
  local runs_json arts_json run_id run_sha dl_url ipa meta

  if [ -z "$TOKEN" ]; then
    err "no release asset found, and the artifact fallback needs a token"
    err "set GH_TOKEN or write one with Actions:read to ~/.gh_token"
    return 1
  fi

  say "querying latest successful $WORKFLOW run on $BRANCH"
  runs_json="$(api "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW/runs?status=success&branch=$BRANCH&per_page=1")" \
    || { err "GitHub API request failed"; return 1; }

  read -r run_id run_sha < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
runs = d.get("workflow_runs") or []
if not runs:
    sys.exit(1)
print(runs[0]["id"], runs[0]["head_sha"][:7])
' <<< "$runs_json") || { err "no successful run found (or bad token / bad branch)"; return 1; }

  say "run $run_id (commit $run_sha)"
  if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$run_id" ]; then
    say "run $run_id already published — nothing to do"
    return 2
  fi

  arts_json="$(api "https://api.github.com/repos/$REPO/actions/runs/$run_id/artifacts")" \
    || { err "could not list artifacts"; return 1; }

  dl_url="$(python3 -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)
for a in d.get("artifacts") or []:
    if a["name"] == want and not a.get("expired"):
        print(a["archive_download_url"]); break
' "$ARTIFACT" <<< "$arts_json")"

  if [ -z "$dl_url" ]; then
    err "artifact '$ARTIFACT' not found on run $run_id (expired after 90 days?)"
    return 1
  fi

  say "downloading artifact"
  curl -sSL -m 600 -H "Authorization: Bearer $TOKEN" -o "$TMP/artifact.zip" "$dl_url" \
    || { err "artifact download failed"; return 1; }

  # GitHub always wraps artifacts in its own zip; the .ipa is inside.
  unzip -qo "$TMP/artifact.zip" -d "$TMP/unpacked" || { err "artifact zip is corrupt"; return 1; }

  ipa="$(find "$TMP/unpacked" -name '*.ipa' -type f | head -1)"
  [ -n "$ipa" ] || { err "no .ipa inside the artifact"; return 1; }
  meta="$(find "$TMP/unpacked" -name 'ios-build.json' -type f | head -1)"

  publish_files "$ipa" "${meta:-/nonexistent}" "$run_id"
}

# ── main ─────────────────────────────────────────────────────────────────────
publish_from_release
rc=$?
if [ "$rc" -eq 1 ]; then
  warn "no usable release — falling back to the workflow artifact"
  publish_from_artifact
  rc=$?
fi
exit "$rc"
