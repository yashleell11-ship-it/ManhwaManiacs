"""Inbound rate limiting (slowapi).

The abusable endpoints reject request floods with a 429 rendered in the standard
``{code, message, details}`` envelope, keyed per client IP (X-Forwarded-For
aware). The limiter is off for the rest of the suite (see the ``rate_limit_
toggle`` fixture in conftest); these tests opt in with ``@pytest.mark.rate_limit``.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from core.config import get_settings
from database.session import get_db
from main import create_app


@pytest.fixture
def client(db_engine, monkeypatch):
    monkeypatch.setenv("MM_COOKIE_SECURE", "false")
    monkeypatch.setenv("MM_RATE_LIMIT_AUTH", "3/minute")  # tiny bucket for the test
    get_settings.cache_clear()

    session_factory = sessionmaker(bind=db_engine, autoflush=False, autocommit=False)

    def override_get_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    app = create_app(run_migrations=False, run_workers=False)
    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as test_client:
        yield test_client
    get_settings.cache_clear()


def _login(client: TestClient, ip: str):
    return client.post(
        "/auth/login",
        json={"username": "ghost", "password": "whatever"},
        headers={"X-Forwarded-For": ip},
    )


@pytest.mark.rate_limit
def test_login_flood_is_rejected_with_429_envelope(client):
    # 3/minute: the first three requests get normal handling (401, no such user),
    # the fourth trips the limit.
    codes = [_login(client, "203.0.113.5").status_code for _ in range(3)]
    assert codes == [401, 401, 401]

    limited = _login(client, "203.0.113.5")
    assert limited.status_code == 429
    body = limited.json()
    assert body["code"] == "rate_limited"
    assert "message" in body
    # slowapi advertises when the caller may retry
    assert "retry-after" in {k.lower() for k in limited.headers}


@pytest.mark.rate_limit
def test_rate_limit_is_keyed_per_client_ip(client):
    for _ in range(4):
        _login(client, "198.51.100.7")  # exhaust this client's budget
    # a different forwarded client IP still has its full budget
    other = _login(client, "198.51.100.8")
    assert other.status_code == 401


def test_rate_limiting_is_off_for_unmarked_tests(client):
    # Not marked @pytest.mark.rate_limit → the limiter is disabled, so a flood
    # that would blow the 3/minute bucket sails through as ordinary 401s.
    codes = [_login(client, "203.0.113.9").status_code for _ in range(6)]
    assert 429 not in codes
    assert set(codes) == {401}


@pytest.mark.rate_limit
def test_sources_browse_with_rate_limit_enabled(client):
    """Rate-limited source browse must not 500 when slowapi injects headers."""
    from unittest.mock import patch

    from connectors.asurascans.connector import AsuraScansConnector
    from tests.test_asurascans_connector import _load as _load_asura

    listing_payload = _load_asura("series_list.json")
    connector = AsuraScansConnector()
    try:
        with patch.object(connector._http, "get_json", return_value=listing_payload):
            with patch("services.browse_service.create_connector", return_value=connector):
                response = client.get(
                    "/sources/asurascans/series",
                    headers={"X-Forwarded-For": "203.0.113.50"},
                )
    finally:
        connector._http.close()

    assert response.status_code == 200
    assert response.json()["total"] == 333


# --- the limit key: which header is actually trustworthy -------------------


@pytest.mark.rate_limit
def test_login_flood_is_not_bypassable_by_forging_x_forwarded_for(client):
    """Caddy and Cloudflare *append* to X-Forwarded-For rather than replacing
    it, so its first hop is whatever the client sent — keying on it let a
    brute-forcer mint a fresh bucket per request. CF-Connecting-IP is written by
    the edge on every request and wins."""
    codes = [
        client.post(
            "/auth/login",
            json={"username": "ghost", "password": "whatever"},
            headers={
                "CF-Connecting-IP": "203.0.113.77",
                "X-Forwarded-For": f"10.0.0.{n}, 203.0.113.77",  # forged first hop
            },
        ).status_code
        for n in range(5)
    ]
    assert codes[:3] == [401, 401, 401]
    assert 429 in codes[3:]


@pytest.mark.rate_limit
def test_cf_connecting_ip_still_separates_genuinely_different_clients(client):
    for _ in range(4):
        client.post(
            "/auth/login",
            json={"username": "ghost", "password": "whatever"},
            headers={"CF-Connecting-IP": "203.0.113.90"},
        )
    other = client.post(
        "/auth/login",
        json={"username": "ghost", "password": "whatever"},
        headers={"CF-Connecting-IP": "203.0.113.91"},
    )
    assert other.status_code == 401


@pytest.mark.rate_limit
def test_x_forwarded_for_is_the_key_when_no_trusted_header_is_configured(
    client, monkeypatch
):
    """A deployment with no CDN in front sets MM_TRUSTED_CLIENT_IP_HEADER="" and
    gets the previous behaviour back."""
    monkeypatch.setenv("MM_TRUSTED_CLIENT_IP_HEADER", "")
    get_settings.cache_clear()
    codes = [_login(client, "198.51.100.30").status_code for _ in range(5)]
    assert codes[:3] == [401, 401, 401]
    assert 429 in codes[3:]
    get_settings.cache_clear()


# --- the byte-proxying source routes carry a bucket ------------------------


class _StubBrowse:
    """Just enough BrowseService for the rate-limited source routes."""

    def _gate_open(self) -> bool:
        return False

    async def federated_search(self, *a, **kw):  # noqa: ANN002, ANN003, ARG002
        return {"items": [], "total": 0}

    def resolve_series_cover(self, *a, **kw):  # noqa: ANN002, ANN003, ARG002
        return "image/png", b"cover-bytes"

    def resolve_page_image(self, *a, **kw):  # noqa: ANN002, ANN003, ARG002
        return "image/png", b"page-bytes"

    def get_series(self, *a, **kw):  # noqa: ANN002, ANN003, ARG002
        return {"id": "solo", "title": "Solo"}

    def get_chapters(self, *a, **kw):  # noqa: ANN002, ANN003, ARG002
        return []

    def get_chapter_pages(self, *a, **kw):  # noqa: ANN002, ANN003, ARG002
        return []


class _StubReader:
    def resolve_source_chapter(self, *a, **kw):  # noqa: ANN002, ANN003, ARG002
        return {"pages": []}


@pytest.fixture
def sources_client(client, monkeypatch):
    from services.browse_service import get_browse_service
    from services.reader_service import get_reader_service

    monkeypatch.setenv("MM_RATE_LIMIT_SOURCES", "2/minute")
    get_settings.cache_clear()
    client.app.dependency_overrides[get_browse_service] = _StubBrowse
    client.app.dependency_overrides[get_reader_service] = _StubReader
    yield client
    client.app.dependency_overrides.pop(get_browse_service, None)
    client.app.dependency_overrides.pop(get_reader_service, None)
    get_settings.cache_clear()


@pytest.mark.rate_limit
@pytest.mark.parametrize(
    "path",
    [
        "/sources/search?q=solo",  # fans out to every connector at once
        "/sources/mangadex/series/solo-leveling/cover",  # proxies bytes
        "/sources/mangadex/pages/p1/image",  # proxies bytes, the hot one
        "/sources/mangadex/series/solo/chapters/c1/reader",
        # audit finding 9: these three fetch upstream on the sync threadpool
        # and had no limiter, contradicting this file's CONTRACT comment
        "/sources/mangadex/series/solo/chapters",
        "/sources/mangadex/series/solo",
        "/sources/mangadex/chapters/c1/pages",
    ],
)
def test_expensive_source_routes_are_rate_limited(sources_client, path):
    """Also a smoke test for slowapi's header injection: a limited route that
    returns a dict rather than a Response needs ``response: Response`` in its
    signature, or slowapi raises on every request once limits are enabled."""
    headers = {"CF-Connecting-IP": "203.0.113.200"}
    first = [sources_client.get(path, headers=headers).status_code for _ in range(2)]
    assert first == [200, 200], path
    limited = sources_client.get(path, headers=headers)
    assert limited.status_code == 429, path
    assert limited.json()["code"] == "rate_limited"


# --- the OCR upload carries a bucket ---------------------------------------

OCR_SRC = "mangadex"
OCR_SERIES = "rate-limited-series"


@pytest.fixture
def ocr_client(client, monkeypatch, make_user, make_profile, seed_follow, as_user):
    """An account that follows the series, so the upload is authorized and the
    only thing left that can stop it is the limiter."""
    monkeypatch.setenv("MM_RATE_LIMIT_OCR", "2/minute")
    get_settings.cache_clear()
    user = make_user("ocr-flood")
    profile = make_profile(user.id, "Main")
    # Uploads are only taken for chapters the server has seen for the series.
    seed_follow(
        user.id, profile.id, source_id=OCR_SRC, series_key=OCR_SERIES,
        known_chapters='[{"key": "c0"}, {"key": "c1"}, {"key": "c2"}]',
    )
    yield client, as_user(user.id, profile.id)
    get_settings.cache_clear()


@pytest.mark.rate_limit
def test_ocr_upload_is_rate_limited(ocr_client):
    """The one limited route whose cost is DISK, not upstream politeness.

    ``POST /ocr/chapter`` had per-request ceilings but no bucket, so nothing
    bounded the number of requests: 30 max-size uploads from one ordinary
    account were accepted in 0.7 s and grew the SQLite file to 115 MB. SQLite
    is the whole application state on a <=20GB VPS, so filling the volume takes
    every write in the app down with it — progress, bookmarks, logins — and
    recovery is manual surgery, not a restart.
    """
    api, headers = ocr_client
    headers = {**headers, "CF-Connecting-IP": "203.0.113.210"}

    def _upload(chapter_key: str):
        return api.post(
            "/ocr/chapter",
            json={
                "source_id": OCR_SRC,
                "series_key": OCR_SERIES,
                "chapter_key": chapter_key,
                "engine": "mlkit",
                "pages": [{"page": 1, "text": "some dialogue"}],
            },
            headers=headers,
        )

    accepted = [_upload(f"c{n}").status_code for n in range(2)]
    assert accepted == [200, 200]

    limited = _upload("c2")
    assert limited.status_code == 429, limited.text
    assert limited.json()["code"] == "rate_limited"
    assert "retry-after" in {k.lower() for k in limited.headers}


# --- change-password is login by another door --------------------------------


@pytest.fixture
def password_client(client, monkeypatch, make_user, as_user):
    """Two signed-in accounts whose stored hash matches no password, so every
    change-password attempt is a wrong guess (401) until the limiter says 429."""
    monkeypatch.setenv("MM_RATE_LIMIT_CHANGE_PASSWORD", "3/minute")
    get_settings.cache_clear()
    first = make_user("guesser-a")
    second = make_user("guesser-b")
    yield client, as_user(first.id), as_user(second.id)
    get_settings.cache_clear()


def _change_password(client: TestClient, headers: dict, ip: str):
    return client.post(
        "/auth/change-password",
        json={"current_password": "a-guess-123", "new_password": "new-pass-123"},
        headers={**headers, "CF-Connecting-IP": ip},
    )


@pytest.mark.rate_limit
def test_change_password_flood_is_rejected_with_429(password_client):
    """Every attempt is an Argon2 verify of the current password. With no
    bucket, a token holder could guess it without the login limit, and a flood
    of wrong guesses allocated 64 MiB apiece."""
    api, headers, _ = password_client
    codes = [_change_password(api, headers, "203.0.113.120").status_code for _ in range(3)]
    assert codes == [401, 401, 401]

    limited = _change_password(api, headers, "203.0.113.120")
    assert limited.status_code == 429, limited.text
    assert limited.json()["code"] == "rate_limited"


@pytest.mark.rate_limit
def test_change_password_limit_follows_the_session_across_ips(password_client):
    """Rotating the client address must not buy a token holder a new bucket."""
    api, headers, _ = password_client
    codes = [
        _change_password(api, headers, f"203.0.113.{130 + n}").status_code
        for n in range(4)
    ]
    assert codes[:3] == [401, 401, 401]
    assert codes[3] == 429


@pytest.mark.rate_limit
def test_change_password_limit_also_holds_per_ip_across_accounts(password_client):
    """Minting more accounts from one address must not multiply the budget."""
    api, first, second = password_client
    for _ in range(3):
        _change_password(api, first, "203.0.113.150")
    assert _change_password(api, second, "203.0.113.150").status_code == 429
    # ...while that second account, from its own address, is untouched.
    assert _change_password(api, second, "203.0.113.151").status_code == 401
