"""Authentication endpoints: register, login, logout, session management.

Web clients receive the session token as an httpOnly cookie (set automatically);
mobile clients read the same token from the response body and send it back as
``Authorization: Bearer <token>``. Both are the same opaque session — logout on
either revokes the row.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, ConfigDict, Field

from core.config import get_settings
from core.errors import AppError
from core.rate_limit import (
    auth_limit,
    bootstrap_status_limit,
    change_password_limit,
    limiter,
    register_limit,
    session_key,
)
from database.models import User
from services.auth_service import (
    REMEMBER_ME_TTL,
    SESSION_COOKIE_NAME,
    SESSION_TTL,
    AuthService,
    get_auth_service,
    get_current_user,
    get_session_token,
    require_admin_user,
)

router = APIRouter(prefix="/auth", tags=["auth"])

AuthDep = Annotated[AuthService, Depends(get_auth_service)]
CurrentUser = Annotated[User, Depends(get_current_user)]
AdminUser = Annotated[User, Depends(require_admin_user)]


# --- schemas -----------------------------------------------------------------


class RegisterRequest(BaseModel):
    username: str
    password: str
    email: str | None = Field(default=None, max_length=255)
    display_name: str | None = Field(default=None, max_length=255)
    # Required (403 invite_code_required) whenever the deployment has an invite
    # code configured — except for the very first account while the bootstrap
    # window is open. GET /auth/bootstrap-status says whether to send it.
    invite_code: str | None = Field(default=None, max_length=255)
    remember: bool = False


class LoginRequest(BaseModel):
    username: str
    password: str
    remember: bool = False


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    username: str
    email: str | None
    display_name: str | None
    is_admin: bool
    created_at: datetime
    last_login_at: datetime | None


class AccountOut(BaseModel):
    """A user as the owner administers them.

    Deliberately not a subclass of ``UserOut``: this is the members-screen
    shape, so it carries the two things administration turns on — whether the
    account is still allowed in, and how many devices it is signed in on — and
    drops the contact fields (email, display_name) that the account's own
    ``/auth/me`` is for. Managing someone is not a reason to read their inbox
    address."""

    id: int
    username: str
    is_admin: bool
    is_active: bool
    created_at: datetime
    last_login_at: datetime | None
    session_count: int


class AccountUpdate(BaseModel):
    is_active: bool


class AuthResponse(BaseModel):
    user: UserOut
    # Bearer token for mobile clients. Web clients ignore this and rely on the
    # httpOnly cookie set on the same response.
    token: str


class SessionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    created_at: datetime
    last_used_at: datetime
    expires_at: datetime
    user_agent: str | None
    ip_address: str | None
    current: bool = False


class BootstrapStatus(BaseModel):
    """Public pre-auth probe: everything a client needs to decide which form to
    render (login / register / claim-this-instance) — and nothing more. The
    invite code itself is NEVER included here."""

    # True while zero accounts exist. Kept for existing clients; new UI logic
    # should key the "create the first admin" form on `bootstrap_open`, because
    # an empty table with an expired window no longer grants uninvited signup.
    needs_bootstrap: bool
    # True while zero accounts exist AND the bootstrap window is still open:
    # registering right now needs no invite code and yields the admin account.
    bootstrap_open: bool
    # The deployment's self-service registration switch (post-bootstrap).
    registration_enabled: bool
    # True when a registration attempt right now must carry `invite_code`.
    # Render the invite-code field iff this is true.
    invite_code_required: bool
    # Convenience: can POST /auth/register succeed right now at all (with a
    # valid invite code where required)? False => hide/disable the signup form.
    registration_open: bool
    # Server-side novels switch (MM_NOVELS_ENABLED, spec 2026-09-04 §2).
    # Clients mount their novel UI ONLY when this is true — the binaries ship
    # with the code dormant, and this pre-auth flag is what wakes it. False
    # in production until the owner flips the env var on the VPS.
    novels_enabled: bool = False


# --- helpers -----------------------------------------------------------------


def _set_session_cookie(response: Response, token: str, *, remember: bool) -> None:
    settings = get_settings()
    max_age = int((REMEMBER_ME_TTL if remember else SESSION_TTL).total_seconds())
    response.set_cookie(
        key=SESSION_COOKIE_NAME,
        value=token,
        max_age=max_age,
        httponly=True,
        secure=settings.session_cookie_secure,
        samesite=settings.session_cookie_samesite,
        path="/",
    )


def _clear_session_cookie(response: Response) -> None:
    settings = get_settings()
    response.delete_cookie(
        key=SESSION_COOKIE_NAME,
        path="/",
        httponly=True,
        secure=settings.session_cookie_secure,
        samesite=settings.session_cookie_samesite,
    )


def _client_ip(request: Request) -> str | None:
    """The address to record on a session row.

    Prefers the header the edge writes — and OVERWRITES — on every request
    (``MM_TRUSTED_CLIENT_IP_HEADER``, CF-Connecting-IP by default), which is
    the same source ``core.rate_limit.client_ip`` keys on, so the sessions
    screen and the rate limiter no longer disagree about where a request came
    from.

    X-Forwarded-For is only the fallback, and then its LAST hop: proxies
    *append* to XFF, so the leftmost entry is whatever the client typed — this
    used to read it, which meant the "recognise this device?" list showed an
    address the attacker chose. The rightmost entry is the one our own nearest
    proxy wrote. Behind the tunnel that is the cloudflared container rather
    than a real client, but a useless-and-honest address beats a
    plausible-and-forged one. The socket peer closes it out for direct hits.
    """
    trusted_header = (get_settings().trusted_client_ip_header or "").strip()
    if trusted_header:
        trusted = (request.headers.get(trusted_header) or "").strip()
        if trusted:
            return trusted
    forwarded = request.headers.get("x-forwarded-for") or ""
    hops = [hop.strip() for hop in forwarded.split(",") if hop.strip()]
    if hops:
        return hops[-1]
    return request.client.host if request.client else None


def _client_meta(request: Request) -> tuple[str | None, str | None]:
    return request.headers.get("user-agent"), _client_ip(request)


# --- routes ------------------------------------------------------------------


@router.get("/bootstrap-status", response_model=BootstrapStatus)
@limiter.limit(bootstrap_status_limit)
def bootstrap_status(
    request: Request,
    response: Response,  # slowapi injects X-RateLimit-* headers into this
    auth: AuthDep,
) -> BootstrapStatus:
    """Public: report whether the instance still needs its first (admin) account
    and what a registration attempt would currently require, so the client can
    render the right form. Never echoes the invite code.

    Rate-limited (MM_RATE_LIMIT_BOOTSTRAP_STATUS): ``bootstrap_open`` tells an
    unauthenticated caller exactly when an empty instance can be claimed, so an
    unthrottled version is a free polling oracle for timing a registration
    burst at the reset-accounts window. Normal clients call this once per
    launch and never notice the limit."""
    settings = get_settings()
    needs_bootstrap = auth.user_count() == 0
    bootstrap_open = needs_bootstrap and auth.bootstrap_window_open()
    invite_configured = bool(settings.registration_invite_code)
    return BootstrapStatus(
        needs_bootstrap=needs_bootstrap,
        bootstrap_open=bootstrap_open,
        registration_enabled=settings.registration_enabled,
        invite_code_required=invite_configured and not bootstrap_open,
        registration_open=bootstrap_open or settings.registration_enabled,
        novels_enabled=bool(getattr(settings, "novels_enabled", False)),
    )


@router.post("/register", response_model=AuthResponse, status_code=201)
@limiter.limit(register_limit)
def register(
    body: RegisterRequest,
    request: Request,
    response: Response,
    auth: AuthDep,
) -> AuthResponse:
    """Create an account and start a session.

    While the users table is empty and the bootstrap window is open, the first
    registration is allowed uninvited and becomes the admin/owner. Otherwise
    ``registration_enabled`` must be on (403 ``registration_disabled``) and,
    when the deployment has an invite code configured, ``invite_code`` must
    match (403 ``invite_code_required`` / ``invite_code_invalid``). See
    ``AuthService.ensure_registration_allowed``. Rate-limited on its own
    tight bucket (``MM_RATE_LIMIT_REGISTER``) against invite brute force.

    The ``ensure_registration_allowed`` call here is only the cheap pre-flight
    (fail before the Argon2 hash); the authoritative permission check and the
    first-account-becomes-admin decision both happen atomically inside
    ``register``'s serialized claim transaction (``enforce_policy=True``), so
    concurrent registrations cannot each observe an empty users table.
    """
    auth.ensure_registration_allowed(body.invite_code)
    user = auth.register(
        body.username,
        body.password,
        email=body.email,
        display_name=body.display_name,
        invite_code=body.invite_code,
        enforce_policy=True,
    )
    user_agent, ip = _client_meta(request)
    token, _ = auth.create_session(
        user, remember=body.remember, user_agent=user_agent, ip_address=ip
    )
    _set_session_cookie(response, token, remember=body.remember)
    return AuthResponse(user=UserOut.model_validate(user), token=token)


@router.post("/login", response_model=AuthResponse)
@limiter.limit(auth_limit)
def login(
    body: LoginRequest,
    request: Request,
    response: Response,
    auth: AuthDep,
) -> AuthResponse:
    user = auth.authenticate(body.username, body.password)
    user_agent, ip = _client_meta(request)
    token, _ = auth.create_session(
        user, remember=body.remember, user_agent=user_agent, ip_address=ip
    )
    _set_session_cookie(response, token, remember=body.remember)
    return AuthResponse(user=UserOut.model_validate(user), token=token)


@router.post("/logout", status_code=204)
def logout(
    response: Response,
    auth: AuthDep,
    _user: CurrentUser,
    token: Annotated[str | None, Depends(get_session_token)],
) -> Response:
    """Revoke the current session and clear the cookie."""
    auth.revoke_token(token)
    _clear_session_cookie(response)
    response.status_code = 204
    return response


@router.post("/logout-all", status_code=204)
def logout_all(
    response: Response,
    auth: AuthDep,
    user: CurrentUser,
) -> Response:
    """Revoke every session for the current user (sign out everywhere)."""
    auth.revoke_all(user.id)
    _clear_session_cookie(response)
    response.status_code = 204
    return response


@router.get("/me", response_model=UserOut)
def me(user: CurrentUser) -> UserOut:
    return UserOut.model_validate(user)


@router.post("/change-password", status_code=204)
@limiter.limit(change_password_limit)
@limiter.limit(change_password_limit, key_func=session_key)
def change_password(
    body: ChangePasswordRequest,
    request: Request,
    response: Response,  # slowapi injects X-RateLimit-* headers into this
    auth: AuthDep,
    user: CurrentUser,
    token: Annotated[str | None, Depends(get_session_token)],
) -> Response:
    """Change the password and revoke all *other* sessions (keep this one).

    One call, one transaction: the revocation used to be a second commit here,
    so a failure between them left the new password live and every old session
    with it.

    Rate-limited like login (MM_RATE_LIMIT_CHANGE_PASSWORD), per IP and per
    session: the current-password check is an Argon2 verify, so an unlimited
    route is a guessing oracle for a stolen token and a memory flood for any
    account."""
    auth.change_password(
        user, body.current_password, body.new_password, keep_token=token
    )
    response.status_code = 204
    return response


@router.get("/sessions", response_model=list[SessionOut])
def list_sessions(
    auth: AuthDep,
    user: CurrentUser,
    token: Annotated[str | None, Depends(get_session_token)],
) -> list[SessionOut]:
    from core.auth import hash_session_token

    current_hash = hash_session_token(token) if token else None
    out: list[SessionOut] = []
    for session in auth.list_sessions(user.id):
        item = SessionOut.model_validate(session)
        item.current = session.token_hash == current_hash
        out.append(item)
    return out


@router.delete("/sessions/{session_id}", status_code=204)
def revoke_session(
    session_id: int,
    response: Response,
    auth: AuthDep,
    user: CurrentUser,
) -> Response:
    revoked = auth.revoke_session_id(user.id, session_id)
    if not revoked:
        raise AppError("Session not found.", code="not_found", status_code=404)
    response.status_code = 204
    return response


# --- account administration (owner only) -------------------------------------
#
# Registration is open on this deployment by choice, so these are the other
# half of it: the owner must be able to disable or remove an account that
# signed up. Both mutations refuse the admin's own account (400
# cannot_manage_self) — see AuthService.get_managed_user.


def _account_out(user: User, session_count: int) -> AccountOut:
    return AccountOut(
        id=user.id,
        username=user.username,
        is_admin=bool(user.is_admin),
        is_active=bool(user.is_active),
        created_at=user.created_at,
        last_login_at=user.last_login_at,
        session_count=session_count,
    )


@router.get("/users", response_model=list[AccountOut])
def list_users(auth: AuthDep, _admin: AdminUser) -> list[AccountOut]:
    """Every account, so the owner can see who signed up, who is disabled, and
    who is signed in where."""
    return [
        _account_out(user, count)
        for user, count in auth.list_users_with_session_counts()
    ]


@router.patch("/users/{user_id}", response_model=AccountOut)
def update_user(
    user_id: int,
    body: AccountUpdate,
    auth: AuthDep,
    admin: AdminUser,
) -> AccountOut:
    """Enable or disable an account.

    Disabling is immediate and total: the account's sessions are deleted and
    every token it holds stops resolving on the next request (401), not at
    expiry — a 90-day remember-me token is otherwise a quarter of continued
    access after the owner thought they had removed someone. Its next login
    attempt is refused with 403 ``account_disabled``. Re-enabling restores
    login only; the revoked sessions stay revoked.
    """
    user = auth.set_user_active(
        auth.get_managed_user(admin, user_id), body.is_active
    )
    return _account_out(user, auth.count_live_sessions(user.id))


@router.delete("/users/{user_id}", status_code=204)
def delete_user(
    user_id: int,
    response: Response,
    auth: AuthDep,
    admin: AdminUser,
) -> Response:
    """Delete an account and everything it owns (profiles, library, progress,
    bookmarks, collections, tags, notifications, stats, sessions). Irreversible.
    """
    auth.delete_user(auth.get_managed_user(admin, user_id))
    response.status_code = 204
    return response
