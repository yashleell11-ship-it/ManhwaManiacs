"""Inbound rate limiting (slowapi).

A single process-wide limiter, keyed by the real client IP as reported by the
outermost proxy (the app runs behind Caddy/Cloudflare, so the socket peer is
the proxy — see :func:`client_ip` for why that is *not* X-Forwarded-For).
Applied selectively to the expensive/abusable endpoints — auth
(login/register/change-password), the admin backup restore-upload, source proxying
(browse/search/cover/page-image), the bulk chapter windows, and the OCR
transcript upload — via the per-bucket limit callables below.

The limit *values* are read from Settings on every request, so they stay
env-configurable (MM_RATE_LIMIT_AUTH / _IMPORT / _SOURCES) without touching
code. Set MM_RATE_LIMIT_ENABLED=false to turn limiting off globally.

Storage is in-memory: limits are enforced per worker process. That is sufficient
as a brute-force/abuse backstop; it is not a precise cluster-wide quota.
"""

from __future__ import annotations

from fastapi import Request
from fastapi.responses import JSONResponse
from slowapi import Limiter
from slowapi.errors import RateLimitExceeded

from core.config import get_settings


def client_ip(request: Request) -> str:
    """Rate-limit key: the originating client IP.

    Behind Caddy/Cloudflare the socket peer is the proxy, so the real address
    has to come from a header — but **X-Forwarded-For is not that header**.
    Proxies *append* to XFF rather than replacing it, so a client that sends
    ``X-Forwarded-For: 1.2.3.4`` arrives at the origin as
    ``1.2.3.4, <its real address>``. Keying on the first hop therefore let a
    brute-forcer mint a fresh bucket per request by varying a header, which is
    the entire login limit gone.

    So: prefer the header written by the outermost proxy — Cloudflare's
    ``CF-Connecting-IP``, which CF overwrites on every request and a client
    cannot influence — and fall back to XFF's first hop, then the socket peer,
    only when it is absent.

    **The assumption this rests on** is that the origin is reachable *only*
    through that proxy (here: a Cloudflare tunnel, so there is no direct route
    to the container). A deployment that exposes the origin directly would let
    a client forge ``CF-Connecting-IP`` too; point
    ``MM_TRUSTED_CLIENT_IP_HEADER`` at whatever its own edge sets, or to an
    empty string to key on XFF/peer as before.
    """
    trusted_header = (get_settings().trusted_client_ip_header or "").strip()
    if trusted_header:
        trusted = request.headers.get(trusted_header)
        if trusted and trusted.strip():
            return trusted.strip()
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        first = forwarded.split(",")[0].strip()
        if first:
            return first
    return request.client.host if request.client else "anonymous"


limiter = Limiter(
    key_func=client_ip,
    enabled=get_settings().rate_limit_enabled,
    headers_enabled=True,
)


# Per-bucket limit values, evaluated per request so env overrides take effect
# without re-importing. Each is a callable returning a slowapi rate string.
def auth_limit() -> str:
    return get_settings().rate_limit_auth


def register_limit() -> str:
    """Limit for POST /auth/register — tighter than the general auth bucket
    because registration is the invite-code brute-force surface (and account
    creation is rare, so a hard cap costs a real user nothing). The value may
    combine several limits with ";" (e.g. "5/minute;30/hour")."""
    return get_settings().rate_limit_register


def change_password_limit() -> str:
    """Limit for POST /auth/change-password. Every call is an Argon2 verify of
    the current password, so it is login by another door: without a bucket a
    token holder guesses the password with no limit, and a flood of wrong
    guesses allocates 64 MiB apiece. See Settings.rate_limit_change_password;
    the route applies it per IP *and* per session (:func:`session_key`)."""
    return get_settings().rate_limit_change_password


def session_key(request: Request) -> str:
    """Rate-limit key: the caller's session, for routes that require one.

    An IP key alone is the wrong shape for a signed-in route: whoever holds a
    token can rotate addresses and get a fresh bucket each time, while a
    hostel full of readers behind one NAT would share a single one. The token
    itself is the stable identity here. Only its SHA-256 is used, as in the
    sessions table, so the limiter's storage never holds a live credential.
    Falls back to the client IP when there is no token (the route rejects
    those with 401 before the limit is checked anyway)."""
    from core.auth import hash_session_token
    from services.auth_service import SESSION_COOKIE_NAME, _extract_token

    token = _extract_token(
        request.cookies.get(SESSION_COOKIE_NAME),
        request.headers.get("authorization"),
    )
    if token:
        return "session:" + hash_session_token(token)
    return client_ip(request)


def bootstrap_status_limit() -> str:
    """Limit for GET /auth/bootstrap-status. Public and cheap, but it announces
    when the bootstrap window is open — the polling oracle an attacker watches
    to time a registration burst at a freshly wiped instance. One call per app
    launch is normal use; see Settings.rate_limit_bootstrap_status for the
    sizing rationale."""
    return get_settings().rate_limit_bootstrap_status


def backup_limit() -> str:
    """Limit for the admin backup restore-upload endpoint. (The old ``import``
    bucket had one other user — folder library import — which is gone; spec
    §6.) ``rate_limit_import`` remains the backing setting/env key for
    compatibility."""
    return get_settings().rate_limit_import


# Back-compat alias — `routes/backup.py` historically imported this name.
import_limit = backup_limit


def sources_limit() -> str:
    return get_settings().rate_limit_sources


def bulk_limit() -> str:
    """Limit for the bulk *window* endpoints (POST /reader/chapters/manifest,
    POST /novels/chapters).

    Deliberately its own, much tighter bucket rather than reusing ``sources``:
    one request there fans out to as many as ``*_bulk_max_chapters`` upstream
    scrapes on the sync threadpool, so charging it the same as a single manifest
    would multiply the effective outbound rate by twenty. Sized in
    ``Settings.rate_limit_bulk`` (MM_RATE_LIMIT_BULK)."""
    return get_settings().rate_limit_bulk


def suggest_limit() -> str:
    """Limit for POST /library/suggest.

    Its own bucket because one accepted request is one *paid* API call. The
    other buckets here protect somebody else's server or this box's disk; this
    one protects a bill, which is the only resource in the app that does not
    recover on its own. Sized in ``Settings.rate_limit_suggest``
    (MM_RATE_LIMIT_SUGGEST)."""
    return get_settings().rate_limit_suggest


def ocr_limit() -> str:
    """Limit for POST /ocr/chapter.

    Every other limited route is bounded by what it costs *upstream*; this one
    is bounded by disk. An accepted upload is up to 2 MB of text plus its FTS5
    index — ~3.8 MB of SQLite measured — and SQLite here is not a cache but the
    entire application state, on a volume small enough to fill. With no bucket,
    one logged-in account fills it in minutes and every write in the app starts
    failing: no progress, no bookmarks, no logins. Sized in
    ``Settings.rate_limit_ocr`` (MM_RATE_LIMIT_OCR)."""
    return get_settings().rate_limit_ocr


def rate_limit_exceeded_handler(request: Request, exc: RateLimitExceeded) -> JSONResponse:
    """Render a 429 in the app's standard ``{code, message, details}`` envelope,
    preserving slowapi's Retry-After / X-RateLimit-* headers."""
    response = JSONResponse(
        status_code=429,
        content={
            "code": "rate_limited",
            "message": "Too many requests. Please slow down and try again shortly.",
            "details": {"limit": str(exc.detail)},
        },
    )
    return request.app.state.limiter._inject_headers(
        response, request.state.view_rate_limit
    )
