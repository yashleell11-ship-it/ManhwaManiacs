from __future__ import annotations

# Must run before any other backend import: if a restore was staged (see
# core.backup_restore / routes.backup), this swaps the database file in on
# disk before database.session ever opens (and process-lifetime caches) a
# connection to it. core.backup_restore is stdlib + core.config only, so
# importing it here can never transitively trigger database.session itself.
from core.backup_restore import apply_pending_restore_if_present

_restore_applied_on_boot = apply_pending_restore_if_present()

import inspect
import json
import logging
import os
from contextlib import asynccontextmanager
from dataclasses import dataclass

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.concurrency import run_in_threadpool
from starlette.requests import HTTPConnection
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from api.router import api_router
from connectors.registry import log_registered_connectors, validate_registry
from core.auth import tokens_equal
from core.config import get_settings
from core.errors import register_error_handlers
from core.rate_limit import limiter, rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from database.session import SessionLocal, get_db, init_db
from services.auth_service import (
    SESSION_COOKIE_NAME,
    AuthService,
    _extract_token,
)
from services.update_scheduler import get_update_manager


def log_registration_posture() -> None:
    """Make the admin-takeover surface observable in the startup log: is the
    bootstrap window open (empty users table => first registration becomes
    admin), when does it close, and what does a registration attempt require
    right now?"""
    log = logging.getLogger("uvicorn.error")
    settings = get_settings()
    db = SessionLocal()
    try:
        auth = AuthService(db)
        count = auth.user_count()
        invite = "set" if settings.registration_invite_code else "NOT set"
        if count == 0:
            deadline = auth.bootstrap_window_deadline()
            if auth.bootstrap_window_open():
                log.warning(
                    "BOOTSTRAP OPEN: users table is empty — the first account "
                    "to register becomes admin, no invite code needed. Window "
                    "closes at %s (MM_BOOTSTRAP_WINDOW_MINUTES=%d).",
                    deadline.isoformat() if deadline else "?",
                    settings.bootstrap_window_minutes,
                )
            else:
                log.warning(
                    "Bootstrap window EXPIRED (closed at %s): users table is "
                    "empty but uninvited registration is refused. Claim the "
                    "instance with ops/vps/deploy.sh create-owner, or re-arm "
                    "the window with reset-accounts.",
                    deadline.isoformat() if deadline else "?",
                )
        else:
            log.info(
                "Auth posture: %d account(s); registration_enabled=%s; "
                "invite code %s.",
                count,
                settings.registration_enabled,
                invite,
            )
        if settings.registration_enabled and not settings.registration_invite_code:
            log.warning(
                "registration_enabled=true with NO invite code: registration "
                "is OPEN to anyone who can reach this host. Set "
                "MM_REGISTRATION_INVITE_CODE (ops/vps/deploy.sh "
                "set-invite-code) if this deployment is public."
            )
        code = settings.registration_invite_code
        if code and len(code) < 8:
            log.warning(
                "The configured invite code is only %d characters — short "
                "codes are brute-forceable even behind the register rate "
                "limit. Use at least 8.",
                len(code),
            )
    finally:
        db.close()


def prune_expired_sessions() -> None:
    """Opportunistically delete expired auth sessions at startup. Individual
    tokens are also pruned lazily when resolved, but this clears in one pass any
    backlog that accumulated while the process was down."""
    db = SessionLocal()
    try:
        removed = AuthService(db).cleanup_expired()
        if removed:
            logging.getLogger("uvicorn.error").info(
                "Pruned %d expired auth session(s) at startup.", removed
            )
    finally:
        db.close()


def sweep_cache_retention_at_startup() -> None:
    """Apply the cache retention rules once at boot.

    The daily pass lives on the update-scheduler thread; this one exists for
    the case that cadence is worst at. A source is deregistered by editing
    ``connectors/catalog.py`` or ``connectors/excluded.py`` and shipping it,
    and shipping it restarts this process — so its orphaned cache rows go on
    the boot that dropped it rather than up to a day later, which matters
    because those rows are readable by anything that reads the cache tables
    without resolving a connector first."""
    db = SessionLocal()
    try:
        from services.source_cache_service import sweep_cache_retention

        sweep_cache_retention(db)
    except Exception:
        db.rollback()
        logging.getLogger("uvicorn.error").exception(
            "Cache retention sweep failed at startup"
        )
    finally:
        db.close()


# --- request-body size limit -------------------------------------------------
#
# FastAPI reads and json-parses a request body BEFORE it runs any dependency,
# and the session gate is a dependency. So without this, an anonymous caller
# could post a ~100 MB JSON array to any route and have the whole thing held
# in memory -- the bytes plus a Python object per element, several hundred MB
# -- only to be told 401 afterwards. A handful of those in parallel is the
# whole of a 3.8 GB box that also runs recall and the MC bots. Neither uvicorn
# nor the Caddy in front sets a cap, so it is enforced here, in a middleware
# that sees the body before routing, auth or parsing do.

#: Every route not listed in ``_large_body_routes``. The largest legitimate
#: JSON body elsewhere is an offline-sync batch (200 progress or bookmark
#: items, a few hundred KB at the very most); 2 MiB is well clear of that and
#: small enough that parsing it costs nothing worth attacking.
DEFAULT_BODY_LIMIT = 2 * 1024 * 1024

#: A whole-database restore. Starlette spools a multipart file to disk, not
#: memory, so this bounds disk, not RAM -- and the backup a restore uploads is
#: the database itself, which grows with the library. Sized many times over
#: today's database rather than near it, because a limit that refuses a real
#: restore is worse than no limit at all.
#: ``MM_MAX_RESTORE_BYTES`` raises it without a code change if that ever stops
#: being true.
DEFAULT_RESTORE_LIMIT = 2 * 1024 * 1024 * 1024

#: ``POST /ocr/chapter`` (routes/ocr.py). The model admits up to 2M characters
#: of text and 500 pages x 300 boxes, and the mobile client clamps to exactly
#: those bounds. At their maximum -- every box carrying the five doubles the
#: app sends, the text all three-byte CJK -- that encodes to ~30 MB, so this
#: is sized to the model rather than to a typical chapter (a few hundred KB):
#: a payload the route would accept must never be refused before it gets
#: there. tests/test_body_size_limit.py builds that payload and checks it fits.
OCR_UPLOAD_LIMIT = 40 * 1024 * 1024

#: ``POST /novels/render/complete`` (routes/novel_render.py): two parts, the
#: audio and its timing map, each capped at that module's ``_MAX_UPLOAD``
#: (32 MiB) while it streams them to disk, plus the form fields and multipart
#: framing. A test pins this to that constant so the two cannot drift apart.
RENDER_UPLOAD_LIMIT = 2 * 32 * 1024 * 1024 + 1024 * 1024


@dataclass(frozen=True)
class BodyAllowance:
    """A route allowed a body larger than ``DEFAULT_BODY_LIMIT``.

    ``gate`` names who may use the larger allowance: ``"admin"``,
    ``"session"`` (any signed-in account) or ``"render_token"`` (the render
    box). It is checked BEFORE a byte past the default is read, so an
    anonymous caller gets the same 2 MiB on these routes as everywhere else --
    otherwise the big allowance would just be the new target. This is not
    the route's authorization, which still runs as normal afterwards; it only
    decides how much of the body is worth reading to find out.
    """

    limit: int
    gate: str


def _restore_limit() -> int:
    raw = os.getenv("MM_MAX_RESTORE_BYTES", "").strip()
    try:
        value = int(raw) if raw else 0
    except ValueError:
        value = 0
    return value if value > 0 else DEFAULT_RESTORE_LIMIT


def _large_body_routes() -> dict[tuple[str, str], BodyAllowance]:
    """Every route that legitimately takes more than the default.

    Exact ``(method, path)`` matches, as the backend sees them (the web app's
    ``/api`` prefix is stripped by its rewrite before a request gets here).
    Enumerated by grepping for ``UploadFile``, ``File(``/``Form(`` and large
    list models across routes/: these three are the only ones.
    """
    return {
        ("POST", "/backup/import"): BodyAllowance(_restore_limit(), "admin"),
        ("POST", "/ocr/chapter"): BodyAllowance(OCR_UPLOAD_LIMIT, "session"),
        ("POST", "/novels/render/complete"): BodyAllowance(
            RENDER_UPLOAD_LIMIT, "render_token"
        ),
    }


class _BodyTooLarge(Exception):
    """Raised out of ``receive`` once a streamed body crosses its limit."""


class BodySizeLimitMiddleware:
    """Refuse an oversized request body with 413 before anything parses it.

    Pure ASGI rather than ``BaseHTTPMiddleware``: that one hands the handler a
    re-wrapped body stream, and the point here is to be the stream. Two
    shapes of body are covered:

    - A declared ``Content-Length`` over the limit is refused before a single
      byte is read.
    - A chunked body (no length) is counted as it arrives, and refused the
      moment the running total crosses the limit -- the app never gets the
      chunk that crossed it.

    In the second case the app is mid-read when it is cut off, and FastAPI
    answers a failed body read with its own 400. That answer is swallowed and
    replaced with the 413, which is what actually happened.
    """

    def __init__(
        self,
        app: ASGIApp,
        *,
        owner: FastAPI | None = None,
        default_limit: int = DEFAULT_BODY_LIMIT,
        routes: dict[tuple[str, str], BodyAllowance] | None = None,
    ) -> None:
        self.app = app
        self._owner = owner
        self._default = default_limit
        self._routes = _large_body_routes() if routes is None else routes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        allowance = self._routes.get((scope["method"], scope["path"]))
        # What THIS caller may send: the default, until the route's gate has
        # admitted them to its larger allowance. Asked at most once, and only
        # once a body actually needs more than the default.
        limit = self._default
        admitted: bool | None = None

        async def limit_for_caller() -> int:
            nonlocal admitted, limit
            if admitted is None:
                admitted = await self._admits(allowance, scope)
                if admitted and allowance is not None:
                    limit = allowance.limit
            return limit

        declared = _declared_length(scope)
        if declared is not None and declared > limit:
            if declared > await limit_for_caller():
                await self._refuse(send, limit)
                return

        received = 0
        exceeded = False
        response_started = False

        async def limited_receive() -> Message:
            nonlocal received, exceeded
            message = await receive()
            if message["type"] != "http.request":
                return message
            received += len(message.get("body", b""))
            if received > limit and received > await limit_for_caller():
                exceeded = True
                raise _BodyTooLarge
            return message

        async def guarded_send(message: Message) -> None:
            nonlocal response_started
            if exceeded:
                # Whatever the app made of the cut-off read (a 400, usually)
                # is not the answer; the 413 below is.
                return
            if message["type"] == "http.response.start":
                response_started = True
            await send(message)

        try:
            await self.app(scope, limited_receive, guarded_send)
        except _BodyTooLarge:
            pass
        if exceeded and not response_started:
            await self._refuse(send, limit)

    async def _admits(self, allowance: BodyAllowance | None, scope: Scope) -> bool:
        """Whether this caller may send more than the default to this route."""
        if allowance is None:
            return False
        conn = HTTPConnection(scope)
        try:
            if allowance.gate == "render_token":
                configured = str(
                    getattr(get_settings(), "render_worker_token", "") or ""
                )
                presented = conn.headers.get("x-render-token") or ""
                return bool(configured and presented) and tokens_equal(
                    presented, configured
                )
            token = _extract_token(
                conn.cookies.get(SESSION_COOKIE_NAME),
                conn.headers.get("authorization"),
            )
            if not token:
                return False
            user = await run_in_threadpool(self._resolve_user, token)
        except Exception:
            # Fail closed: a caller this cannot identify gets the default
            # allowance, never the large one.
            logging.getLogger("uvicorn.error").exception(
                "Could not check who is sending a large body to %s",
                scope.get("path"),
            )
            return False
        if user is None:
            return False
        if allowance.gate == "admin":
            return bool(user.is_admin)
        return True

    def _resolve_user(self, token: str):
        # Through the app's own get_db so a dependency override (the test
        # suite's database) is honoured here exactly as in a route.
        factory = get_db
        if self._owner is not None:
            factory = self._owner.dependency_overrides.get(get_db, get_db)
        made = factory()
        if inspect.isgenerator(made):
            db = next(made)
            try:
                return AuthService(db).resolve_session(token)
            finally:
                made.close()
        return AuthService(made).resolve_session(token)

    async def _refuse(self, send: Send, limit: int) -> None:
        # ``limit`` is the one that applied to THIS caller: an anonymous
        # upload to a large route was held to the default, and saying so is
        # more useful than quoting a figure they were never going to get.
        body = json.dumps(
            {
                "code": "request_too_large",
                "message": (
                    f"Request body too large. The limit for this request is "
                    f"{limit} bytes."
                ),
                "details": {"limit_bytes": limit},
            }
        ).encode("utf-8")
        await send(
            {
                "type": "http.response.start",
                "status": 413,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                    # Whatever of the body is still in flight is not going to
                    # be read; the connection cannot be reused after it.
                    (b"connection", b"close"),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})


def _declared_length(scope: Scope) -> int | None:
    for name, value in scope.get("headers") or ():
        if name == b"content-length":
            try:
                return int(value)
            except ValueError:
                # Unparseable: count the body as it arrives instead.
                return None
    return None


def create_app(*, run_migrations: bool = True, run_workers: bool = True) -> FastAPI:
    settings = get_settings()

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        if _restore_applied_on_boot:
            logging.getLogger("uvicorn.error").info(
                "Applied a staged database restore before startup."
            )
        if run_migrations:
            init_db()
            prune_expired_sessions()
            sweep_cache_retention_at_startup()
            log_registration_posture()
        update_manager = get_update_manager()
        if run_workers:
            update_manager.start()
        startup_logger = logging.getLogger("uvicorn.error")
        validate_registry()
        log_registered_connectors(startup_logger)
        _log_registered_routes(_app)
        yield
        if run_workers:
            update_manager.stop()

    # Interactive API docs + the OpenAPI schema publish the full endpoint map
    # (including admin backup/import ops) to anonymous callers, so gate them
    # behind debug for the public, currently-unauthenticated deployment.
    _docs_enabled = bool(getattr(settings, "debug", False))
    app = FastAPI(
        title="ManhwaManiacs Backend",
        version=settings.version,
        description="ManhwaManiacs backend API for manhwa library management",
        docs_url="/docs" if _docs_enabled else None,
        redoc_url="/redoc" if _docs_enabled else None,
        openapi_url="/openapi.json" if _docs_enabled else None,
        lifespan=lifespan,
    )

    if "*" in settings.cors_origins and not getattr(settings, "debug", False):
        raise RuntimeError(
            "CORS wildcard ('*') is not permitted outside debug mode. "
            "Set CORS_ORIGINS to specific allowed origins before deploying."
        )

    # Added BEFORE CORS so it sits inside it: Starlette makes the last-added
    # middleware the outermost, and a 413 the browser cannot read (no CORS
    # headers) looks like a network failure rather than an answer. Inside
    # CORS is still ahead of routing, every dependency and every body read.
    app.add_middleware(BodySizeLimitMiddleware, owner=app)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    register_error_handlers(app)
    # Inbound rate limiting: the limiter is referenced by the per-route
    # decorators via app.state, and a 429 is rendered in our standard envelope.
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, rate_limit_exceeded_handler)
    app.include_router(api_router)
    if getattr(settings, "novels_enabled", False):
        # Novels (spec 2026-09-04-novels-design §2): the /novels router is
        # mounted ONLY when MM_NOVELS_ENABLED is on. Off means the routes do
        # not exist — a stock 404 with no auth challenge, indistinguishable
        # from a feature that was never built. Mounted directly on the app
        # (not the module-level api_router, which include_router would mutate
        # for the whole process) under the same global session gate.
        from routes.novels import router as novels_router
        from services.auth_service import enforce_authentication

        app.include_router(
            novels_router, dependencies=[Depends(enforce_authentication)]
        )
        # The render box's own routes. Mounted ONLY when a token is
        # configured, and deliberately outside enforce_authentication: the box
        # has no session. Its token is valid on these five paths and nowhere
        # else, so a compromised renderer can upload audio and cannot read a
        # library.
        if str(getattr(settings, "render_worker_token", "") or ""):
            from routes.novel_render import router as novel_render_router

            app.include_router(novel_render_router)
    return app


def _log_registered_routes(app: FastAPI) -> None:
    schema = app.openapi()
    tags: set[str] = set()
    for path_item in schema.get("paths", {}).values():
        for operation in path_item.values():
            if isinstance(operation, dict):
                for tag in operation.get("tags", []):
                    tags.add(str(tag))
    tag_list = ", ".join(sorted(tags)) or "none"
    logging.getLogger("uvicorn.error").info(
        "Registered API route groups: %s (%d paths)",
        tag_list,
        len(schema.get("paths", {})),
    )


app = create_app()


def main() -> None:
    import os

    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        # Auto-reload is a dev-only convenience; never enable it in a real deploy.
        reload=os.getenv("MM_DEV_RELOAD", "").lower() in ("1", "true", "yes"),
    )


if __name__ == "__main__":
    main()
