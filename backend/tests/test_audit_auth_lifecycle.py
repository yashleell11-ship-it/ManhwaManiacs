"""Data-layer audit — account lifecycle and session hygiene.

Pins the findings the ``auth-sessions`` shard left open:

  * **A-3** every login inserts a 7/90-day session row and nothing ever trims
    it: no per-user cap, and expired rows are removed only at process start
    (``main.prune_expired_sessions``) or when that exact dead token is
    presented again — so a token nobody presents again sits for a quarter.
  * **A-6** a password change rotated the hash in one transaction and revoked
    the other sessions in a second, so the two could disagree.
  * **A-7** there was no way to disable, kick or delete an account:
    ``users.is_active`` had no writer anywhere in the tree and no user-delete
    path existed, on an instance whose registration is deliberately open.
  * **TC-4** nothing asserted that a *deactivated* account's already-issued
    sessions stop working, so the ``is_active`` gate in
    ``AuthService.resolve_session`` survived as a mutant.

The deactivation pin below flips ``is_active`` directly in the database rather
than through the admin endpoint, deliberately: the endpoint also revokes the
rows, which would let the ``resolve_session`` gate be deleted without any test
noticing — exactly the mutant TC-4 reports.
"""

from __future__ import annotations

import contextlib
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from core.auth import verify_password
from core.config import get_settings
from core.time_utils import utcnow
from database.models import (
    Bookmark,
    ChapterOcr,
    ChapterProgress,
    Collection,
    CollectionSeries,
    FollowedSeries,
    ProfileSeriesTag,
    ReadingDayStats,
    ReadingProfile,
    ReadingSession,
    SourcePin,
    Tag,
    UpdateNotification,
    User,
    UserSession,
)
from database.session import get_db
from main import create_app
from services.auth_service import MAX_SESSIONS_PER_USER, AuthService

pytestmark = pytest.mark.real_auth

PASSWORD = "correct-horse-battery"
NEW_PASSWORD = "another-good-passphrase"


@pytest.fixture
def client(session_factory, monkeypatch):
    monkeypatch.setenv("MM_COOKIE_SECURE", "false")
    get_settings.cache_clear()

    def override_get_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    app = create_app(run_migrations=False, run_workers=False)
    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client
    get_settings.cache_clear()


def _session_count(db, user_id: int) -> int:
    return db.execute(
        select(func.count())
        .select_from(UserSession)
        .where(UserSession.user_id == user_id)
    ).scalar_one()


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _anon(client) -> TestClient:
    """A client with an empty cookie jar. ``_extract_token`` prefers the cookie
    over the bearer header, so a token under test has to travel on its own."""
    fresh = TestClient(client.app)
    fresh.cookies.clear()
    return fresh


def _register(client, username: str) -> dict:
    resp = client.post(
        "/auth/register", json={"username": username, "password": PASSWORD}
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


# --- A-3: session table growth ----------------------------------------------


def test_sessions_per_user_are_capped_and_oldest_is_evicted(db_session):
    svc = AuthService(db_session)
    user = svc.register("owner", PASSWORD)
    tokens = [
        svc.create_session(user, remember=True)[0]
        for _ in range(MAX_SESSIONS_PER_USER + 5)
    ]
    assert _session_count(db_session, user.id) == MAX_SESSIONS_PER_USER
    # The device that just logged in keeps its session; the stalest ones went.
    assert svc.resolve_session(tokens[-1]) is not None
    assert svc.resolve_session(tokens[0]) is None


def test_session_cap_only_evicts_the_logging_in_user(db_session):
    svc = AuthService(db_session)
    owner = svc.register("owner", PASSWORD)
    reader = svc.register("reader", PASSWORD)
    reader_token, _ = svc.create_session(reader)
    for _ in range(MAX_SESSIONS_PER_USER + 3):
        svc.create_session(owner)
    assert _session_count(db_session, reader.id) == 1
    assert svc.resolve_session(reader_token).id == reader.id


def test_expired_rows_do_not_hold_a_slot_in_the_cap(db_session):
    svc = AuthService(db_session)
    user = svc.register("owner", PASSWORD)
    keep_token, _ = svc.create_session(user, remember=True)
    # Dead 7-day rows, every one of them created *after* the live remember-me
    # above — so a cap that ranks on age alone would keep these and evict the
    # device still in the reader's hand.
    for n in range(MAX_SESSIONS_PER_USER):
        db_session.add(
            UserSession(
                user_id=user.id,
                token_hash=f"dead-{n}",
                expires_at=utcnow() - timedelta(days=1),
            )
        )
    db_session.commit()

    svc.create_session(user)  # the next login trims

    assert svc.resolve_session(keep_token).id == user.id
    assert _session_count(db_session, user.id) == 2


def test_expired_sessions_are_swept_by_ordinary_traffic(db_session):
    """Only a restart or presenting the dead token itself used to remove an
    expired row, so a 90-day token nobody touches again survives a quarter."""
    svc = AuthService(db_session)
    user = svc.register("owner", PASSWORD)
    live_token, live = svc.create_session(user)
    _, stale = svc.create_session(user)
    stale.expires_at = utcnow() - timedelta(days=30)
    db_session.commit()

    for _ in range(25):
        assert svc.resolve_session(live_token) is not None

    remaining = db_session.execute(
        select(func.count())
        .select_from(UserSession)
        .where(UserSession.expires_at <= utcnow())
    ).scalar_one()
    assert remaining == 0
    # The sweep is not allowed to take live rows with it.
    assert db_session.get(UserSession, live.id) is not None


# --- TC-4: a deactivated account's existing sessions ------------------------


def test_deactivated_account_existing_session_dies_immediately(db_session):
    svc = AuthService(db_session)
    user = svc.register("owner", PASSWORD)
    token, session = svc.create_session(user)
    assert svc.resolve_session(token).id == user.id

    # Straight to the column — no revocation, so only the is_active gate in
    # resolve_session can refuse this still-unexpired, still-present row.
    user.is_active = False
    db_session.commit()

    assert db_session.get(UserSession, session.id) is not None
    assert svc.resolve_session(token) is None


def test_deactivated_account_is_401_over_http(client, session_factory):
    token = _register(client, "owner")["token"]
    assert client.get("/auth/me", headers=_bearer(token)).status_code == 200
    with session_factory() as s:
        s.execute(select(User)).scalar_one().is_active = False
        s.commit()
    assert client.get("/auth/me", headers=_bearer(token)).status_code == 401


# --- A-6: password change + revocation are one transaction ------------------


def test_password_change_and_other_session_revocation_share_one_commit(db_session):
    """They used to be two commits (``change_password`` then ``revoke_all``
    from the route). A failure in between left the NEW password live and every
    session opened with the OLD one still valid — the sessions a password
    change exists to kill, and silently, because the caller had already been
    told it worked.

    Make the second commit fail and assert the two outcomes cannot disagree.
    """
    svc = AuthService(db_session)
    user = svc.register("owner", PASSWORD)
    keep_token, _ = svc.create_session(user)
    other_token, _ = svc.create_session(user)

    real_commit = db_session.commit
    commits = 0

    def flaky_commit():
        nonlocal commits
        commits += 1
        if commits == 2:
            raise RuntimeError("the second write never landed")
        real_commit()

    db_session.commit = flaky_commit
    try:
        with contextlib.suppress(RuntimeError):
            svc.change_password(user, PASSWORD, NEW_PASSWORD, keep_token=keep_token)
    finally:
        del db_session.commit
    db_session.rollback()

    stored = db_session.get(User, user.id).password_hash
    password_changed = verify_password(NEW_PASSWORD, stored)
    others_revoked = svc.resolve_session(other_token) is None
    assert password_changed == others_revoked, (
        f"password_changed={password_changed} but others_revoked="
        f"{others_revoked}: the rotation and the revocation committed apart"
    )
    assert commits == 1, f"{commits} commits — the change is not one transaction"
    # Whichever way it went, the caller's own session is never collateral.
    assert svc.resolve_session(keep_token) is not None


# --- A-7: admin account management ------------------------------------------
#
# The contract the web Members page is built against:
#   GET    /auth/users        -> [AccountOut]
#   PATCH  /auth/users/{id}   {"is_active": bool} -> AccountOut
#   DELETE /auth/users/{id}   -> 204
# Admin only (403 otherwise); the admin's own id is refused on both mutations
# with 400 ``cannot_manage_self``.

ACCOUNT_FIELDS = {
    "id",
    "username",
    "is_admin",
    "is_active",
    "created_at",
    "last_login_at",
    "session_count",
}


def _set_active(client, token: str, user_id: int, active: bool):
    return client.patch(
        f"/auth/users/{user_id}",
        json={"is_active": active},
        headers=_bearer(token),
    )


def test_admin_can_disable_an_account_and_kick_its_sessions(client, session_factory):
    owner = _register(client, "owner")
    victim_client = TestClient(client.app)
    victim_client.cookies.clear()
    victim = _register(victim_client, "reader")
    victim_id = victim["user"]["id"]

    resp = _set_active(client, owner["token"], victim_id, False)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["id"] == victim_id
    assert body["is_active"] is False
    assert body["session_count"] == 0

    with session_factory() as s:
        assert bool(s.get(User, victim_id).is_active) is False
        assert _session_count(s, victim_id) == 0
    # The token in hand stops working *now*, not at expiry, and a fresh login
    # is refused.
    assert (
        _anon(client).get("/auth/me", headers=_bearer(victim["token"])).status_code
        == 401
    )
    login = _anon(client).post(
        "/auth/login", json={"username": "reader", "password": PASSWORD}
    )
    assert login.status_code == 403
    assert login.json()["code"] == "account_disabled"

    # Re-enabling restores login (the account was disabled, not deleted).
    resp = _set_active(client, owner["token"], victim_id, True)
    assert resp.status_code == 200, resp.text
    assert resp.json()["is_active"] is True
    assert (
        _anon(client)
        .post("/auth/login", json={"username": "reader", "password": PASSWORD})
        .status_code
        == 200
    )


def _seed_owned_rows(s, user_id: int, marker: str) -> dict[str, int]:
    """One row in every table an account owns, so a delete has something to
    cascade through. Returns the ids other assertions need."""
    profile = ReadingProfile(user_id=user_id, name=f"{marker} profile")
    s.add(profile)
    s.flush()
    follow = FollowedSeries(
        user_id=user_id,
        profile_id=profile.id,
        source_id="demo",
        series_key=f"{marker}-series",
        title="Series",
    )
    collection = Collection(
        user_id=user_id, profile_id=profile.id, name=f"{marker} shelf"
    )
    tag = Tag(user_id=user_id, profile_id=profile.id, name=f"{marker}-tag")
    s.add_all([follow, collection, tag])
    s.flush()
    s.add_all(
        [
            SourcePin(user_id=user_id, profile_id=profile.id, source_id="demo"),
            ChapterProgress(
                user_id=user_id,
                profile_id=profile.id,
                source_id="demo",
                series_key=f"{marker}-series",
                chapter_key="c1",
            ),
            Bookmark(
                user_id=user_id,
                profile_id=profile.id,
                client_id=f"{marker}-bm",
                source_id="demo",
                series_key=f"{marker}-series",
                chapter_key="c1",
            ),
            ReadingSession(
                user_id=user_id,
                profile_id=profile.id,
                source_id="demo",
                series_key=f"{marker}-series",
                chapter_key="c1",
            ),
            ReadingDayStats(
                user_id=user_id, profile_id=profile.id, day="2026-09-07"
            ),
            CollectionSeries(
                collection_id=collection.id,
                source_id="demo",
                series_key=f"{marker}-series",
            ),
            ProfileSeriesTag(
                user_id=user_id,
                profile_id=profile.id,
                source_id="demo",
                series_key=f"{marker}-series",
                tag_id=tag.id,
            ),
            UpdateNotification(
                user_id=user_id,
                profile_id=profile.id,
                followed_series_id=follow.id,
                source_id="demo",
                series_key=f"{marker}-series",
                chapter_key="c1",
                chapter_title="Chapter 1",
            ),
        ]
    )
    # Global, shared by every account — one row per chapter — but attributed.
    ocr = ChapterOcr(
        source_id="demo",
        series_key=f"{marker}-series",
        chapter_key="c1",
        full_text="dialogue",
        contributed_by_user_id=user_id,
    )
    s.add(ocr)
    s.commit()
    return {
        "profile_id": profile.id,
        "collection_id": collection.id,
        "ocr_id": ocr.id,
    }


#: Every table keyed by ``user_id``, i.e. everything a deleted account owns.
OWNED_BY_USER = (
    ReadingProfile,
    SourcePin,
    FollowedSeries,
    ChapterProgress,
    Bookmark,
    ReadingSession,
    ReadingDayStats,
    Collection,
    Tag,
    ProfileSeriesTag,
    UpdateNotification,
    UserSession,
)


def _owned_counts(s, user_id: int, collection_id: int) -> dict[str, int]:
    counts = {
        model.__tablename__: s.execute(
            select(func.count()).select_from(model).where(model.user_id == user_id)
        ).scalar_one()
        for model in OWNED_BY_USER
    }
    # collection_series has no user_id of its own — it hangs off collections.
    counts["collection_series"] = s.execute(
        select(func.count())
        .select_from(CollectionSeries)
        .where(CollectionSeries.collection_id == collection_id)
    ).scalar_one()
    return counts


def test_admin_can_delete_an_account_and_every_owned_row_cascades(
    client, session_factory
):
    """Counted per table, before and after. The engine runs with
    ``PRAGMA foreign_keys=ON`` (conftest ``db_engine``), so this exercises the
    real ``ON DELETE CASCADE`` chain: users -> reading_profiles -> everything
    per-profile, with ``sessions`` going via the ORM relationship."""
    owner = _register(client, "owner")
    victim_client = TestClient(client.app)
    victim_client.cookies.clear()
    victim = _register(victim_client, "reader")
    victim_id = victim["user"]["id"]
    owner_id = owner["user"]["id"]

    with session_factory() as s:
        victim_ids = _seed_owned_rows(s, victim_id, "reader")
        owner_ids = _seed_owned_rows(s, owner_id, "owner")
        before = _owned_counts(s, victim_id, victim_ids["collection_id"])
        owner_before = _owned_counts(s, owner_id, owner_ids["collection_id"])
    assert all(n > 0 for n in before.values()), f"nothing to cascade: {before}"

    resp = client.delete(f"/auth/users/{victim_id}", headers=_bearer(owner["token"]))
    assert resp.status_code == 204, resp.text

    with session_factory() as s:
        assert s.get(User, victim_id) is None
        after = _owned_counts(s, victim_id, victim_ids["collection_id"])
        owner_after = _owned_counts(s, owner_id, owner_ids["collection_id"])
    orphans = {table: n for table, n in after.items() if n}
    assert not orphans, f"rows outlived the deleted account: {orphans}"
    # The admin's own library is untouched by someone else's deletion.
    assert owner_after == owner_before

    with session_factory() as s:
        # The shared transcript cache survives — everyone reads it — but the
        # attribution does not: contributed_by_user_id has no foreign key, and
        # SQLite reuses rowids, so a leftover id would name a future account.
        ocr = s.get(ChapterOcr, victim_ids["ocr_id"])
        assert ocr is not None, "a shared OCR row was deleted with the account"
        assert ocr.contributed_by_user_id is None
        assert (
            s.get(ChapterOcr, owner_ids["ocr_id"]).contributed_by_user_id
            == owner_id
        )

    assert (
        _anon(client).get("/auth/me", headers=_bearer(victim["token"])).status_code
        == 401
    )


def test_account_management_is_admin_only(client, session_factory):
    _register(client, "owner")
    reader_client = TestClient(client.app)
    reader_client.cookies.clear()
    reader = _register(reader_client, "reader")
    reader_id = reader["user"]["id"]

    calls = (
        ("get", "/auth/users", None),
        ("patch", f"/auth/users/{reader_id}", {"is_active": False}),
        ("delete", f"/auth/users/{reader_id}", None),
    )
    for method, path, body in calls:
        kwargs = {"headers": _bearer(reader["token"])}
        if body is not None:
            kwargs["json"] = body
        resp = getattr(reader_client, method)(path, **kwargs)
        assert resp.status_code == 403, f"{method} {path} -> {resp.status_code}"
    with session_factory() as s:
        assert s.get(User, reader_id) is not None
        assert bool(s.get(User, reader_id).is_active) is True


def test_admin_cannot_lock_itself_out(client):
    owner = _register(client, "owner")
    owner_id = owner["user"]["id"]

    disable = _set_active(client, owner["token"], owner_id, False)
    assert disable.status_code == 400, disable.text
    assert disable.json()["code"] == "cannot_manage_self"

    delete = client.delete(
        f"/auth/users/{owner_id}", headers=_bearer(owner["token"])
    )
    assert delete.status_code == 400, delete.text
    assert delete.json()["code"] == "cannot_manage_self"

    assert client.get("/auth/me", headers=_bearer(owner["token"])).status_code == 200


def test_managing_an_unknown_account_is_404(client):
    owner = _register(client, "owner")
    assert _set_active(client, owner["token"], 999999, False).status_code == 404
    assert (
        client.delete("/auth/users/999999", headers=_bearer(owner["token"])).status_code
        == 404
    )


def test_admin_user_list_shape(client):
    owner = _register(client, "owner")
    reader_client = TestClient(client.app)
    reader_client.cookies.clear()
    reader = _register(reader_client, "reader")
    # A second device for the reader, so the count is not trivially 1.
    reader_client.cookies.clear()
    assert (
        reader_client.post(
            "/auth/login", json={"username": "reader", "password": PASSWORD}
        ).status_code
        == 200
    )

    resp = client.get("/auth/users", headers=_bearer(owner["token"]))
    assert resp.status_code == 200, resp.text
    rows = {row["username"]: row for row in resp.json()}
    assert set(rows) == {"owner", "reader"}
    for row in rows.values():
        assert set(row) == ACCOUNT_FIELDS, f"unexpected account shape: {sorted(row)}"
    assert rows["owner"]["is_admin"] is True
    assert rows["reader"]["is_admin"] is False
    assert all(row["is_active"] is True for row in rows.values())
    assert rows["reader"]["id"] == reader["user"]["id"]
    assert rows["reader"]["session_count"] == 2
    # Registering is a sign-in: an account that never re-logs in (it stays on
    # its registration session) must not read as "never signed in".
    assert rows["owner"]["last_login_at"] is not None


def test_registering_records_a_login(client):
    """Only /auth/login used to stamp last_login_at, so members who signed up
    and stayed on that 90-day session showed as "never signed in · 1 session"
    on the owner's Members screen."""
    owner = _register(client, "owner")
    assert owner["user"]["last_login_at"] is not None
    me = client.get("/auth/me", headers=_bearer(owner["token"]))
    assert me.status_code == 200
    assert me.json()["last_login_at"] is not None
