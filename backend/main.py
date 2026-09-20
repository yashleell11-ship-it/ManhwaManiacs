from __future__ import annotations

# Must run before any other backend import: if a restore was staged (see
# core.backup_restore / routes.backup), this swaps the database file in on
# disk before database.session ever opens (and process-lifetime caches) a
# connection to it. core.backup_restore is stdlib + core.config only, so
# importing it here can never transitively trigger database.session itself.
from core.backup_restore import apply_pending_restore_if_present

_restore_applied_on_boot = apply_pending_restore_if_present()

import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from api.router import api_router
from connectors.registry import log_registered_connectors, validate_registry
from core.config import get_settings
from core.errors import register_error_handlers
from core.rate_limit import limiter, rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from database.session import SessionLocal, init_db
from services.auth_service import AuthService
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
