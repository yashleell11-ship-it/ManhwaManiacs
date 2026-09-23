#!/usr/bin/env bash
# =============================================================================
# ManhwaManiacs multi-environment deploy engine.
#
# One script drives every environment (production / staging / preview-<pr>) as a
# fully isolated stack: own compose project, container, image tag, env vars, build,
# volume, restart policy, logs, deploy directory and Caddy vhost. Reuses the existing
# platform (Caddy on the shared `edge` network, Cloudflare Tunnel, Homepage, Docker).
#
# Usage:
#   ops/deploy.sh production                 # deploy production   (branch: main)
#   ops/deploy.sh staging                    # deploy staging      (branch: develop)
#   ops/deploy.sh preview <pr>               # deploy PR preview   (pr-<n>.manhwamaniacs.xyz)
#   ops/deploy.sh destroy-preview <pr>       # tear a preview down (container+vhost+volume+dir)
#   ops/deploy.sh rollback production|staging|preview [<pr>]
#   ops/deploy.sh list                       # show every env + live health
#   ops/deploy.sh homepage-sync              # rebuild the Homepage ManhwaManiacs block
#
# Runs with write access to /srv and /apps (i.e. inside the CI `ci-tools` container as
# root, or as root on the host). Health checks reach Caddy at $HEALTH_RESOLVE
# (default 127.0.0.1; CI sets `caddy`). Source is taken from this script's own repo
# checkout, so CI just clones and calls this script.
# =============================================================================
set -uo pipefail

APP=manhwamaniacs
DOMAIN=manhwamaniacs.xyz
ROOT=/srv/apps/$APP
CADDY_CONF=/srv/caddy/conf.d
LOGDIR=$ROOT/logs
HEALTH_RESOLVE="${HEALTH_RESOLVE:-127.0.0.1}"
HOMEPAGE_CFG=/apps/homepage/config/services.yaml
# Repo root = parent of the dir holding this script (…/repo/ops/deploy.sh -> …/repo)
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
say(){ echo "${c_grn}==>${c_rst} $*"; }
warn(){ echo "${c_ylw}!! $*${c_rst}"; }
err(){ echo "${c_red}!! $*${c_rst}" >&2; }
logline(){ mkdir -p "$LOGDIR"; echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}" >> "$LOGDIR/$1.log"; }

# ---------------------------------------------------------------------------
# resolve_env <production|staging|preview> [pr]  -> sets SLUG HOST APP_ENV BRANCH
#   RESTART DIR PROJECT CONTAINER IMAGE VOLUME VHOST IS_APEX
# ---------------------------------------------------------------------------
resolve_env(){
  local kind="$1" pr="${2:-}"
  IS_APEX=0
  # APP_HOST: the Android-app subdomain served by the backend directly (landing
  # page + APK download). Only production and staging get one; previews don't.
  APP_HOST=""
  case "$kind" in
    production)
      SLUG=production; HOST="$DOMAIN"; APP_ENV=production; BRANCH=main
      RESTART=unless-stopped; DIR="$ROOT/production"; IS_APEX=1
      APP_HOST="app.$DOMAIN" ;;
    staging)
      SLUG=staging; HOST="staging.$DOMAIN"; APP_ENV=staging; BRANCH=develop
      RESTART=unless-stopped; DIR="$ROOT/staging"
      APP_HOST="app.staging.$DOMAIN" ;;
    preview)
      [ -n "$pr" ] || { err "preview requires a PR number"; exit 2; }
      SLUG="preview-$pr"; HOST="pr-$pr.$DOMAIN"; APP_ENV=preview; BRANCH="${PREVIEW_BRANCH:-pr-$pr}"
      RESTART=on-failure:3; DIR="$ROOT/preview/pr-$pr" ;;
    *) err "unknown environment '$kind'"; exit 2 ;;
  esac
  PROJECT="$APP-$SLUG"
  CONTAINER="$APP-$SLUG"
  IMAGE="local/$APP:$SLUG"
  VOLUME="$APP-$SLUG-data"
  VHOST="$CADDY_CONF/$APP-$SLUG.caddy"
  APP_VHOST="$CADDY_CONF/$APP-$SLUG-app.caddy"
}

# ---------------------------------------------------------------------------
# build_apk — produce the latest Android APK into $DIR/apk so the backend serves
# it at app.<host>/app/download. Best-effort: never fails the deploy.
#   1. Build fresh with Flutter if the toolchain is present (always-latest).
#   2. Otherwise fall back to a prebuilt APK carried in the source tree.
# Only production and staging (which have an app subdomain) build one.
# ---------------------------------------------------------------------------
build_apk(){
  [ -n "${APP_HOST:-}" ] || return 0          # previews have no app subdomain
  mkdir -p "$DIR/apk"
  local out="$DIR/apk/app-release.apk"
  local built="$DIR/mobile/build/app/outputs/flutter-apk/app-release.apk"

  # Locate the Flutter toolchain — the deploy host may not have it on PATH.
  local fl=""
  if command -v flutter >/dev/null 2>&1; then fl="$(command -v flutter)"
  elif [ -x /home/yash/flutter/bin/flutter ]; then fl="/home/yash/flutter/bin/flutter"
  elif [ -n "${FLUTTER_HOME:-}" ] && [ -x "$FLUTTER_HOME/bin/flutter" ]; then fl="$FLUTTER_HOME/bin/flutter"
  fi
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/home/yash/Android/Sdk}}"
  local jdk="${JAVA_HOME:-/home/yash/jdk17}"

  if [ -n "$fl" ] && [ -d "$sdk" ] && [ -d "$jdk" ]; then
    local flroot; flroot="$(cd "$(dirname "$fl")/.." && pwd)"
    say "building Android APK for $APP_HOST (flutter build apk --release)"
    ( cd "$DIR/mobile" \
        && printf 'sdk.dir=%s\nflutter.sdk=%s\n' "$sdk" "$flroot" > android/local.properties \
        && ANDROID_SDK_ROOT="$sdk" ANDROID_HOME="$sdk" JAVA_HOME="$jdk" \
           PATH="$jdk/bin:$sdk/platform-tools:$PATH" \
           XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$DIR/.flutterconfig}" \
           "$fl" pub get \
        && ANDROID_SDK_ROOT="$sdk" ANDROID_HOME="$sdk" JAVA_HOME="$jdk" \
           PATH="$jdk/bin:$sdk/platform-tools:$PATH" \
           XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$DIR/.flutterconfig}" \
           "$fl" build apk --release \
             --dart-define=FLAVOR=prod \
             --dart-define=API_URL="https://$APP_HOST" ) 2>&1 | sed 's/^/   /'
    [ -f "$built" ] && cp "$built" "$out"
  else
    warn "Flutter/Android toolchain not found — falling back to a prebuilt APK if present"
  fi

  # Publish the prebuilt APK carried in the source tree (mobile/build/...).
  # ALWAYS overwrite the served copy — a previously-deployed $out must never be
  # served in place of the current tree's build, or /app/download serves a stale
  # APK forever (the served version silently lags the pubspec version).
  if [ -f "$built" ]; then
    cp "$built" "$out"; say "published prebuilt APK from the source tree"
  fi

  if [ -f "$out" ]; then
    chown -R 1000:1000 "$DIR/apk" 2>/dev/null || true
    say "APK ready: $out ($(du -h "$out" | cut -f1))"
  else
    warn "no APK produced — https://$APP_HOST/app/download will 404 until one is built"
  fi
}

# ---------------------------------------------------------------------------
# Caddy vhost (first line is always the primary hostname). Public TLS is terminated
# by Cloudflare; origin uses Caddy's internal CA (tunnel connects with noTLSVerify).
# ---------------------------------------------------------------------------
write_vhost(){
  mkdir -p "$CADDY_CONF"
  if [ "$IS_APEX" = 1 ]; then
    cat > "$VHOST" <<CADDY
$HOST {
	tls internal
	import sec
	import zip
	import logroll $APP-$SLUG
	reverse_proxy $CONTAINER:3000
}

www.$DOMAIN {
	tls internal
	import sec
	redir https://$HOST{uri} permanent
}
CADDY
    # Retire the pre-multi-env single vhost (same site address) so the cutover is a
    # single atomic Caddy reload — zero downtime. Harmless once it's gone.
    rm -f "$CADDY_CONF/$APP.caddy"
  else
    cat > "$VHOST" <<CADDY
$HOST {
	tls internal
	import sec
	import zip
	import logroll $APP-$SLUG
	reverse_proxy $CONTAINER:3000
}
CADDY
  fi

  # app.<host> — the Android app front door, served by the backend directly
  # (landing page + APK download). Production + staging only; previews skip it.
  if [ -n "${APP_HOST:-}" ]; then
    cat > "$APP_VHOST" <<CADDY
$APP_HOST {
	tls internal
	import sec
	import zip
	import logroll $APP-$SLUG-app
	reverse_proxy $CONTAINER-backend:8000
}
CADDY
  else
    rm -f "$APP_VHOST"
  fi
}

reload_caddy(){ /srv/bin/site-reload.sh >/dev/null 2>&1 && say "caddy reloaded" || warn "caddy reload reported an issue"; }

# ---------------------------------------------------------------------------
# health helpers
# ---------------------------------------------------------------------------
wait_health(){ # $1 container
  local st rc
  for _ in $(seq 1 45); do
    st=$(docker inspect "$1" -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing)
    rc=$(docker inspect "$1" -f '{{.RestartCount}}' 2>/dev/null || echo 0)
    case "$st" in
      healthy|running) echo "$st"; return 0 ;;
      unhealthy|exited|dead|missing) echo "$st"; return 1 ;;
    esac
    [ "${rc:-0}" -ge 3 ] && { echo "restart-loop($rc)"; return 1; }
    sleep 2
  done
  echo "$st"; return 1
}

verify_http(){ # $1 host -> checks the app answers through Caddy over HTTPS
  local code
  code=$(curl -sk -m 15 --connect-to "$1:443:$HEALTH_RESOLVE:443" -o /dev/null -w '%{http_code}' "https://$1/api/health" 2>/dev/null || echo 000)
  echo "$code"
  case "$code" in 2*|3*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# deploy <production|staging|preview> [pr]
# ---------------------------------------------------------------------------
do_deploy(){
  local kind="$1" pr="${2:-}"
  resolve_env "$kind" "$pr"
  local commit branch build_time
  git config --global --add safe.directory "$SRC" 2>/dev/null || true
  commit="${GIT_COMMIT:-$(git -C "$SRC" rev-parse --short=7 HEAD 2>/dev/null || echo dev)}"
  branch="${GIT_BRANCH:-$BRANCH}"
  build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  say "deploy $SLUG  host=$HOST  container=$CONTAINER  image=$IMAGE"
  logline "$SLUG" "deploy start commit=$commit branch=$branch resolve=$HEALTH_RESOLVE"

  # 1) sync source into the isolated env directory
  mkdir -p "$DIR"
  # apk/ and ipa/ are runtime drops that live only in the deploy dir, never in
  # the source tree -- so without excluding them --delete removes them on every
  # deploy. For the .ipa that meant each deploy silently unpublished the iOS
  # build (/app/source.json advertising nothing) until the sync cron next ran,
  # up to ten minutes later. The APK is rebuilt in step 1b, but excluding it too
  # closes the window where /app/download would 404 mid-deploy.
  rsync -a --delete \
    --exclude '.git' --exclude '.forgejo' --exclude 'node_modules' --exclude '.next' \
    --exclude 'apk' --exclude 'ipa' \
    "$SRC"/ "$DIR"/
  chown -R 1000:1000 "$DIR" 2>/dev/null || true

  # 1b) build the latest Android APK into $DIR/apk (mounted read-only into the
  #     backend). Best-effort — never fails the deploy.
  build_apk

  # 1c) the iOS .ipa can't be built here (needs macOS) — it's fetched from the
  #     GitHub Actions runner by ops/fetch-ios-build.sh. Just guarantee the mount
  #     point exists so compose doesn't create it root-owned and the backend
  #     reports "not published yet" rather than failing to start.
  if [ -n "${APP_HOST:-}" ]; then
    mkdir -p "$DIR/ipa"
    chown -R 1000:1000 "$DIR/ipa" 2>/dev/null || true
  fi

  # 2) per-environment .env (isolation: compose reads this for build args + runtime env)
  cat > "$DIR/.env" <<ENV
MM_CONTAINER=$CONTAINER
MM_IMAGE=$IMAGE
MM_RESTART=$RESTART
MM_VOLUME=$VOLUME
MM_PUBLIC_API_URL=https://$HOST/api
MM_PUBLIC_BASE_URL=${APP_HOST:+https://$APP_HOST}
APP_ENV=$APP_ENV
GIT_BRANCH=$branch
GIT_COMMIT=$commit
BUILD_TIME=$build_time
ENV
  chown 1000:1000 "$DIR/.env" 2>/dev/null || true

  # 3) preserve current images for rollback (frontend + backend)
  local have_prev=0
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker tag "$IMAGE" "$IMAGE-previous" && have_prev=1
  fi
  docker image inspect "$IMAGE-backend" >/dev/null 2>&1 \
    && docker tag "$IMAGE-backend" "$IMAGE-backend-previous"

  # 4) build + start the isolated stack
  say "build + up ($PROJECT)"
  # --remove-orphans clears containers from a prior compose shape (e.g. the old
  # single-service placeholder, whose container name collides with the new
  # frontend service) so the 1->2 service transition doesn't fail on a name clash.
  ( cd "$DIR" && docker compose -p "$PROJECT" up -d --build --remove-orphans ) 2>&1 | sed 's/^/   /'
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    err "build/start failed — previous version (if any) left running"
    logline "$SLUG" "build FAILED"
    exit 1
  fi

  # 5) write/refresh Caddy vhost and reload (hot, zero-downtime)
  write_vhost; reload_caddy

  # 6) health gate
  local hs code
  hs=$(wait_health "$CONTAINER"); echo "   container: $hs"
  code=$(verify_http "$HOST");    echo "   https://$HOST/api/health -> HTTP $code (via $HEALTH_RESOLVE)"

  if [ "$hs" = healthy ] || [ "$hs" = running ]; then
    if [ "${code:0:1}" = 2 ] || [ "${code:0:1}" = 3 ]; then
      logline "$SLUG" "deploy OK commit=$commit image=$(docker inspect "$CONTAINER" -f '{{.Image}}' 2>/dev/null|cut -c8-19)"
      say "${c_grn}OK${c_rst}: $SLUG healthy at https://$HOST"
      homepage_sync
      return 0
    fi
  fi

  # 7) health failed -> rollback
  err "health check FAILED for $SLUG"
  logline "$SLUG" "health FAILED (container=$hs http=$code)"
  if [ "$have_prev" = 1 ]; then
    say "rolling back $SLUG to previous image"
    docker tag "$IMAGE-previous" "$IMAGE"
    docker image inspect "$IMAGE-backend-previous" >/dev/null 2>&1 \
      && docker tag "$IMAGE-backend-previous" "$IMAGE-backend"
    ( cd "$DIR" && docker compose -p "$PROJECT" up -d --force-recreate --remove-orphans ) 2>&1 | sed 's/^/   /'
    hs=$(wait_health "$CONTAINER"); code=$(verify_http "$HOST")
    if { [ "$hs" = healthy ] || [ "$hs" = running ]; } && { [ "${code:0:1}" = 2 ] || [ "${code:0:1}" = 3 ]; }; then
      say "ROLLED BACK — previous image restored and healthy"; logline "$SLUG" "rollback OK"
    else
      err "ROLLBACK still unhealthy — inspect: docker logs $CONTAINER"; logline "$SLUG" "rollback FAILED"
    fi
  else
    warn "no previous image to roll back to (first deploy). Left running: docker logs $CONTAINER"
    logline "$SLUG" "no previous image; not rolled back"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# rollback <production|staging|preview> [pr]
# ---------------------------------------------------------------------------
do_rollback(){
  local kind="$1" pr="${2:-}"
  resolve_env "$kind" "$pr"
  docker image inspect "$IMAGE-previous" >/dev/null 2>&1 || { err "no previous image for $SLUG ($IMAGE-previous)"; exit 1; }
  say "rollback $SLUG -> $IMAGE-previous"
  logline "$SLUG" "manual rollback start"
  docker tag "$IMAGE-previous" "$IMAGE"
  docker image inspect "$IMAGE-backend-previous" >/dev/null 2>&1 \
    && docker tag "$IMAGE-backend-previous" "$IMAGE-backend"
  ( cd "$DIR" && docker compose -p "$PROJECT" up -d --force-recreate --remove-orphans ) 2>&1 | sed 's/^/   /'
  local hs code; hs=$(wait_health "$CONTAINER"); code=$(verify_http "$HOST")
  echo "   container: $hs | https://$HOST -> HTTP $code"
  if { [ "$hs" = healthy ] || [ "$hs" = running ]; } && { [ "${code:0:1}" = 2 ] || [ "${code:0:1}" = 3 ]; }; then
    say "${c_grn}OK${c_rst}: $SLUG rolled back and healthy"; logline "$SLUG" "manual rollback OK"; homepage_sync
  else
    err "rollback unhealthy — inspect: docker logs $CONTAINER"; logline "$SLUG" "manual rollback FAILED"; exit 1
  fi
}

# ---------------------------------------------------------------------------
# destroy-preview <pr>
# ---------------------------------------------------------------------------
do_destroy_preview(){
  local pr="$1"; resolve_env preview "$pr"
  say "destroy preview pr-$pr"
  ( cd "$DIR" 2>/dev/null && docker compose -p "$PROJECT" down -v ) 2>&1 | sed 's/^/   /' || \
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  docker image rm -f "$IMAGE" "$IMAGE-previous" >/dev/null 2>&1 || true
  rm -f "$VHOST" "$APP_VHOST"; reload_caddy
  rm -rf "$DIR"
  logline "preview-$pr" "destroyed"
  homepage_sync
  say "${c_grn}OK${c_rst}: preview pr-$pr destroyed"
}

# ---------------------------------------------------------------------------
# list — every manhwamaniacs env + live health
# ---------------------------------------------------------------------------
do_list(){
  printf '%-26s %-32s %-10s %-10s\n' CONTAINER HOST STATUS HTTP
  for c in $(docker ps -a --filter "name=^$APP-" --format '{{.Names}}' | sort); do
    local slug host vh code st
    slug="${c#$APP-}"; vh="$CADDY_CONF/$APP-$slug.caddy"
    host=$(awk 'NR==1{sub(/ .*/,"");print;exit}' "$vh" 2>/dev/null || echo '-')
    st=$(docker inspect "$c" -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo '-')
    code=$( [ "$host" != '-' ] && curl -sk -m 8 --connect-to "$host:443:$HEALTH_RESOLVE:443" -o /dev/null -w '%{http_code}' "https://$host/api/health" 2>/dev/null || echo '-')
    printf '%-26s %-32s %-10s %-10s\n' "$c" "$host" "$st" "$code"
  done
}

# ---------------------------------------------------------------------------
# homepage_sync — regenerate the marker-delimited ManhwaManiacs block from the
# currently-running envs (prod/staging/active previews), each with a health monitor.
# ---------------------------------------------------------------------------
homepage_sync(){
  [ -f "$HOMEPAGE_CFG" ] || return 0
  local A="# >>> manhwamaniacs (managed by ops/deploy.sh) >>>"
  local B="# <<< manhwamaniacs <<<"
  local tmp; tmp=$(mktemp)
  { echo "$A"; echo "- ManhwaManiacs:"; } >> "$tmp"
  # Product front door: the Android app landing + APK download (served by the
  # production backend on the app.<domain> subdomain).
  cat >> "$tmp" <<ITEM
    - Android app:
        icon: mdi-android
        href: https://app.$DOMAIN
        description: Install the latest APK
        siteMonitor: http://$APP-production-backend:8000/health
ITEM
  # Order: production, staging, then previews (natural sort).
  local slugs; slugs=$(docker ps --filter "name=^$APP-" --format '{{.Names}}' \
    | sed "s/^$APP-//" | awk '{o=2; if($0=="production")o=0; else if($0=="staging")o=1; print o"\t"$0}' \
    | sort | cut -f2)
  local n=0 slug host title desc icon
  for slug in $slugs; do
    host=$(awk 'NR==1{sub(/ .*/,"");print;exit}' "$CADDY_CONF/$APP-$slug.caddy" 2>/dev/null)
    [ -n "$host" ] || continue
    case "$slug" in
      production) title=Production; desc="Production · main"; icon=mdi-book-open-page-variant ;;
      staging)    title=Staging;    desc="Staging · develop"; icon=mdi-flask-outline ;;
      preview-*)  title="Preview ${slug#preview-}"; desc="PR #${slug#preview-} preview"; icon=mdi-source-pull ;;
      *)          title="$slug"; desc="$slug"; icon=mdi-web ;;
    esac
    cat >> "$tmp" <<ITEM
    - $title:
        icon: $icon
        href: https://$host
        description: $desc
        siteMonitor: http://$APP-$slug:3000/api/health
        server: my-docker
        container: $APP-$slug
ITEM
    n=$((n+1))
  done
  [ "$n" -eq 0 ] && { echo "    - (no environments running):" >> "$tmp"; echo "        description: none" >> "$tmp"; }
  echo "$B" >> "$tmp"
  # Replace existing block (or append) using awk, then swap in atomically.
  local out; out=$(mktemp)
  awk -v a="$A" -v b="$B" -v blk="$tmp" '
    BEGIN{ while((getline l < blk) > 0) B[++nb]=l }
    $0==a { skip=1; for(i=1;i<=nb;i++) print B[i]; done=1; next }
    skip && $0==b { skip=0; next }
    skip { next }
    { print }
    END{ if(!done){ print ""; for(i=1;i<=nb;i++) print B[i] } }
  ' "$HOMEPAGE_CFG" > "$out"
  cat "$out" > "$HOMEPAGE_CFG"
  rm -f "$tmp" "$out"
  chown 1000:1000 "$HOMEPAGE_CFG" 2>/dev/null || true
  echo "   homepage: ManhwaManiacs block updated ($n env(s))"
  docker restart homepage >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  production|staging) do_deploy "$1" ;;
  preview)            do_deploy preview "${2:-}" ;;
  destroy-preview)    do_destroy_preview "${2:?usage: destroy-preview <pr>}" ;;
  rollback)           do_rollback "${2:?usage: rollback <production|staging|preview> [pr]}" "${3:-}" ;;
  list)               do_list ;;
  homepage-sync)      homepage_sync ;;
  *) cat >&2 <<USAGE
usage: ops/deploy.sh <command>
  production | staging            deploy that environment
  preview <pr>                    deploy a PR preview
  destroy-preview <pr>            tear a preview down
  rollback production|staging|preview [<pr>]
  list                            show all envs + health
USAGE
     exit 2 ;;
esac
