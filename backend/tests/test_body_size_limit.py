"""The request-body size limit (main.BodySizeLimitMiddleware).

FastAPI reads and json-parses a body before any dependency runs, and the
session gate is a dependency, so an anonymous ~100 MB JSON array used to be
held in memory in full before the 401. The middleware refuses an oversized
body with 413 before anything reads it.

The failure worth fearing most here is the opposite one: a limit that refuses
a legitimate large body. A restore that cannot be uploaded is worse than no
limit at all, so the large routes are tested to still WORK, with outcomes
(a staged restore, stored OCR rows, saved progress), not just status codes.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import httpx
import pytest
from fastapi import FastAPI, Request

import core.backup_restore as backup_restore
import main
import services.backup_service as backup_service
from database.models import ChapterOcr, ChapterProgress
from main import (
    DEFAULT_BODY_LIMIT,
    OCR_UPLOAD_LIMIT,
    RENDER_UPLOAD_LIMIT,
    BodyAllowance,
    BodySizeLimitMiddleware,
)
from services.browse_service import get_browse_service
from tests._fakes import FakeBrowse

SRC = "mangadex"
SERIES = "solo-leveling"

OVER_DEFAULT = DEFAULT_BODY_LIMIT + 512 * 1024


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("bodylimit")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


@pytest.fixture
def h(as_user, acct):
    uid, pid = acct
    return as_user(uid, pid)


@pytest.fixture
def admin_h(as_user, make_user):
    return as_user(make_user("bodylimit-admin", is_admin=True).id)


def _chunks(payload: bytes, size: int = 256 * 1024):
    """A body with no Content-Length: httpx sends a generator chunked."""
    for start in range(0, len(payload), size):
        yield payload[start : start + size]


def _progress(chapter: int, **kw) -> dict:
    item = {
        "source_id": SRC,
        "series_key": SERIES,
        "chapter_key": f"ch-{chapter}",
        "chapter_number": float(chapter),
        "last_page": 3,
        "page_count": 20,
    }
    item.update(kw)
    return item


def _progress_rows(session_factory) -> int:
    with session_factory() as s:
        return s.query(ChapterProgress).count()


# --- the attack: anonymous, oversized, never parsed ------------------------


def test_an_anonymous_oversized_body_is_refused_before_it_is_read(as_user):
    """The refusal comes from the declared length alone: not one chunk of the
    body is pulled, which is the whole point -- nothing gets to parse it."""
    reached: list[str] = []

    async def inner(scope, receive, send):  # pragma: no cover - must not run
        reached.append(scope["path"])

    pulled: list[bytes] = []

    async def receive():
        pulled.append(b"x")
        return {"type": "http.request", "body": b"x" * 1024, "more_body": True}

    sent: list[dict] = []

    async def send(message):
        sent.append(message)

    middleware = BodySizeLimitMiddleware(inner)
    scope = {
        "type": "http",
        "method": "POST",
        "path": "/novels/chapters",
        "headers": [
            (b"content-type", b"application/json"),
            (b"content-length", str(99 * 1024 * 1024).encode()),
        ],
        "query_string": b"",
    }

    import asyncio

    asyncio.run(middleware(scope, receive, send))

    assert reached == []
    assert pulled == []
    assert sent[0]["status"] == 413
    body = json.loads(sent[1]["body"])
    assert body["code"] == "request_too_large"
    assert body["details"]["limit_bytes"] == DEFAULT_BODY_LIMIT


def test_an_oversized_body_gets_413_not_401_even_with_no_session(client, as_user):
    payload = json.dumps(
        {"source_id": "a", "series_key": "b", "chapter_keys": ["0"] * 700_000}
    )
    assert len(payload) > DEFAULT_BODY_LIMIT

    r = client.post(
        "/library/follow",
        content=payload,
        headers={"content-type": "application/json"},
    )

    assert r.status_code == 413
    assert r.json()["code"] == "request_too_large"


def test_a_chunked_body_is_counted_as_it_arrives(client, h, session_factory):
    """No Content-Length to check up front. The body is counted chunk by
    chunk and cut off at the limit; the answer is the 413, not the 400
    FastAPI would give for a body read that failed half-way, and nothing
    from the batch is stored."""
    filler = "x" * 500
    batch = [_progress(n, series_key=SERIES + filler) for n in range(5000)]
    payload = json.dumps(batch).encode()
    assert len(payload) > DEFAULT_BODY_LIMIT

    r = client.post(
        "/reader/progress/batch",
        content=_chunks(payload),
        headers={**h, "content-type": "application/json"},
    )

    assert r.status_code == 413, r.text
    assert r.json()["code"] == "request_too_large"
    assert _progress_rows(session_factory) == 0


def test_a_chunked_body_under_the_limit_still_arrives_whole(
    client, h, session_factory
):
    r = client.post(
        "/reader/progress/batch",
        content=_chunks(json.dumps([_progress(1), _progress(2)]).encode(), 16),
        headers={**h, "content-type": "application/json"},
    )

    assert r.status_code == 200, r.text
    assert r.json()["saved"] == 2
    assert _progress_rows(session_factory) == 2


def test_the_largest_legitimate_sync_batch_fits_the_default(
    client, h, session_factory
):
    """An offline-sync flush at its item cap, every key at its max length, is
    the biggest ordinary JSON body a client sends. It must sail through."""
    from routes.reader import PROGRESS_BATCH_MAX_ITEMS

    long_series = "s" * 512
    batch = [
        _progress(n, series_key=long_series, chapter_key=f"{n:04d}" + "c" * 508)
        for n in range(PROGRESS_BATCH_MAX_ITEMS)
    ]
    payload = json.dumps(batch)
    assert len(payload) < DEFAULT_BODY_LIMIT

    r = client.post(
        "/reader/progress/batch",
        content=payload,
        headers={**h, "content-type": "application/json"},
    )

    assert r.status_code == 200, r.text
    assert r.json()["saved"] == PROGRESS_BATCH_MAX_ITEMS
    assert _progress_rows(session_factory) == PROGRESS_BATCH_MAX_ITEMS


def test_the_413_carries_cors_headers(client, as_user):
    """A 413 without CORS headers reads, in a browser, as a network failure.
    The limit sits inside CORS so the answer is readable."""
    from core.config import get_settings

    origin = get_settings().cors_origins[0]
    r = client.post(
        "/library/follow",
        content=b"[" + b"0," * (DEFAULT_BODY_LIMIT // 2) + b"0]",
        headers={"content-type": "application/json", "origin": origin},
    )

    assert r.status_code == 413
    assert r.headers.get("access-control-allow-origin") == origin


# --- restore still works ----------------------------------------------------


_REQUIRED_TABLES = ("users", "followed_series", "chapter_progress", "alembic_version")


def _make_backup(path: Path, *, padding_bytes: int) -> None:
    connection = sqlite3.connect(str(path))
    try:
        for table in _REQUIRED_TABLES:
            connection.execute(f"CREATE TABLE {table} (id INTEGER PRIMARY KEY)")
        connection.execute("CREATE TABLE padding (blob BLOB)")
        chunk = b"\x00" * (256 * 1024)
        for _ in range(padding_bytes // len(chunk) + 1):
            connection.execute("INSERT INTO padding (blob) VALUES (?)", (chunk,))
        connection.commit()
    finally:
        connection.close()


@pytest.fixture
def live_db(tmp_path: Path, monkeypatch):
    """Point the backup code at a throwaway database; never the real one."""
    from core.config import get_settings

    live = tmp_path / "live" / "app.db"
    live.parent.mkdir()
    _make_backup(live, padding_bytes=0)
    patched = get_settings().model_copy(update={"db_path": str(live)})
    monkeypatch.setattr(backup_service, "get_settings", lambda: patched)
    monkeypatch.setattr(backup_restore, "get_settings", lambda: patched)
    yield live
    Path(f"{live}.pending-restore").unlink(missing_ok=True)


def test_an_admin_can_still_restore_a_database_bigger_than_the_default(
    client, admin_h, live_db, tmp_path
):
    upload = tmp_path / "backup.db"
    _make_backup(upload, padding_bytes=3 * 1024 * 1024)
    assert upload.stat().st_size > DEFAULT_BODY_LIMIT

    with upload.open("rb") as handle:
        r = client.post(
            "/backup/import",
            files={"file": ("backup.db", handle, "application/octet-stream")},
            headers=admin_h,
        )

    assert r.status_code == 200, r.text
    assert r.json()["status"] == "staged"
    staged = Path(f"{live_db}.pending-restore")
    assert staged.exists()
    assert staged.stat().st_size == upload.stat().st_size


@pytest.mark.parametrize("who", ["anonymous", "member"])
def test_only_an_admin_gets_the_restore_allowance(
    client, as_user, make_user, live_db, tmp_path, who
):
    """The restore allowance is gigabytes. Anyone who is not an admin -- the
    only people the route would ever accept -- is held to the default before
    a byte past it is read, so the large limit is not simply the new target."""
    headers = {} if who == "anonymous" else as_user(make_user("plain").id)
    upload = tmp_path / "backup.db"
    _make_backup(upload, padding_bytes=3 * 1024 * 1024)

    with upload.open("rb") as handle:
        r = client.post(
            "/backup/import",
            files={"file": ("backup.db", handle, "application/octet-stream")},
            headers=headers,
        )

    assert r.status_code == 413
    assert r.json()["details"]["limit_bytes"] == DEFAULT_BODY_LIMIT
    assert not Path(f"{live_db}.pending-restore").exists()


def test_the_restore_allowance_can_be_raised_without_a_code_change(monkeypatch):
    monkeypatch.setenv("MM_MAX_RESTORE_BYTES", str(50 * 1024**3))
    routes = main._large_body_routes()
    assert routes[("POST", "/backup/import")].limit == 50 * 1024**3

    monkeypatch.setenv("MM_MAX_RESTORE_BYTES", "nonsense")
    routes = main._large_body_routes()
    assert routes[("POST", "/backup/import")].limit == main.DEFAULT_RESTORE_LIMIT


# --- OCR upload -------------------------------------------------------------


def _ocr_payload(pages: int, chars_per_page: int) -> dict:
    # Three-byte CJK, sent raw (as the app's jsonEncode does), so a payload
    # inside the route's 2M-character bound is still well past 2 MiB. The text
    # rides in the recognized blocks (ten a page), the page text is short:
    # that keeps the row as STORED under the service's per-row byte ceiling,
    # which counts page text twice (``page_texts`` and ``full_text``).
    per_box = chars_per_page // 10
    return {
        "source_id": SRC,
        "series_key": SERIES,
        "chapter_key": "ch-1",
        "chapter_number": 1.0,
        "language": "ja",
        "engine": "mlkit",
        "pages": [
            {
                "page": p + 1,
                "text": "漢字",
                "boxes": [
                    {"text": "漢" * per_box, "x": 0.1, "y": 0.1 * b}
                    for b in range(10)
                ],
            }
            for p in range(pages)
        ],
    }


def test_a_signed_in_ocr_upload_past_the_default_is_stored(
    app, client, h, seed_follow, acct, session_factory
):
    uid, pid = acct
    seed_follow(
        uid, pid, source_id=SRC, series_key=SERIES,
        known_chapters='[{"key": "ch-1"}]',
    )
    app.dependency_overrides[get_browse_service] = lambda: FakeBrowse()
    raw = json.dumps(
        _ocr_payload(pages=100, chars_per_page=10_000), ensure_ascii=False
    ).encode("utf-8")
    assert len(raw) > DEFAULT_BODY_LIMIT

    r = client.post(
        "/ocr/chapter",
        content=raw,
        headers={**h, "content-type": "application/json"},
    )

    assert r.status_code == 200, r.text
    with session_factory() as s:
        row = s.query(ChapterOcr).one()
        assert row.chapter_key == "ch-1"
        assert len(json.loads(row.page_texts)) == 100


def test_an_anonymous_ocr_upload_is_held_to_the_default(client, as_user):
    raw = json.dumps(
        _ocr_payload(pages=100, chars_per_page=10_000), ensure_ascii=False
    ).encode("utf-8")

    r = client.post(
        "/ocr/chapter",
        content=_chunks(raw),
        headers={"content-type": "application/json"},
    )

    assert r.status_code == 413
    assert r.json()["details"]["limit_bytes"] == DEFAULT_BODY_LIMIT


def test_the_ocr_limit_fits_the_largest_upload_the_route_accepts():
    """Built to the route's own bounds, shaped like the mobile client's
    payload (five doubles per box, jsonEncode leaves non-ASCII raw): every
    page and box at its cap, all of the 2M-character text allowance spent on
    three-byte CJK. A body the route would accept must never be refused
    before it gets there."""
    from routes.ocr import (
        OCR_MAX_BOXES_PER_PAGE,
        OCR_MAX_PAGES,
        OCR_MAX_TOTAL_TEXT_CHARS,
    )

    per_page_text = OCR_MAX_TOTAL_TEXT_CHARS // OCR_MAX_PAGES
    box = {
        "text": "",
        "x": 0.12345678901234568,
        "y": 0.12345678901234568,
        "width": 0.12345678901234568,
        "height": 0.12345678901234568,
        "confidence": 0.12345678901234568,
    }
    payload = {
        "source_id": "s" * 64,
        "series_key": "k" * 512,
        "chapter_key": "c" * 512,
        "chapter_number": 1.0,
        "language": "ja",
        "engine": "e" * 64,
        "pages": [
            {
                "page": p + 1,
                "text": "漢" * per_page_text,
                "boxes": [box] * OCR_MAX_BOXES_PER_PAGE,
            }
            for p in range(OCR_MAX_PAGES)
        ],
    }
    size = len(json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    assert size < OCR_UPLOAD_LIMIT


# --- the render box's upload --------------------------------------------------


def test_the_render_limit_covers_both_parts_at_their_own_cap():
    from routes.novel_render import _MAX_UPLOAD

    assert RENDER_UPLOAD_LIMIT > 2 * _MAX_UPLOAD
    routes = main._large_body_routes()
    assert routes[("POST", "/novels/render/complete")] == BodyAllowance(
        RENDER_UPLOAD_LIMIT, "render_token"
    )


def _echo_app(allowance: BodyAllowance) -> FastAPI:
    inner = FastAPI()

    @inner.post("/big")
    async def big(request: Request) -> dict[str, int]:
        return {"bytes": len(await request.body())}

    inner.add_middleware(
        BodySizeLimitMiddleware,
        owner=inner,
        routes={("POST", "/big"): allowance},
    )
    return inner


@pytest.mark.parametrize(
    ("token", "expected"),
    [("the-box-secret", 200), ("wrong", 413), (None, 413)],
)
def test_only_the_render_token_unlocks_the_render_allowance(
    monkeypatch, token, expected
):
    from core.config import get_settings

    patched = get_settings().model_copy(
        update={"render_worker_token": "the-box-secret"}
    )
    monkeypatch.setattr(main, "get_settings", lambda: patched)
    app = _echo_app(BodyAllowance(8 * 1024 * 1024, "render_token"))
    headers = {"x-render-token": token} if token else {}

    transport = httpx.ASGITransport(app=app)

    async def _post():
        async with httpx.AsyncClient(
            transport=transport, base_url="http://t"
        ) as ac:
            return await ac.post(
                "/big", content=b"a" * OVER_DEFAULT, headers=headers
            )

    import asyncio

    r = asyncio.run(_post())

    assert r.status_code == expected
    if expected == 200:
        assert r.json() == {"bytes": OVER_DEFAULT}


def test_even_an_admitted_caller_stops_at_the_routes_own_limit(admin_h):
    """The allowance is a ceiling, not a pass: an admin streaming past the
    route's own limit is cut off there."""
    app = _echo_app(BodyAllowance(3 * 1024 * 1024, "admin"))
    from fastapi.testclient import TestClient

    with TestClient(app) as tc:
        ok = tc.post("/big", content=_chunks(b"a" * OVER_DEFAULT), headers=admin_h)
        over = tc.post(
            "/big", content=_chunks(b"a" * (4 * 1024 * 1024)), headers=admin_h
        )

    assert ok.status_code == 200
    assert ok.json() == {"bytes": OVER_DEFAULT}
    assert over.status_code == 413
    assert over.json()["details"]["limit_bytes"] == 3 * 1024 * 1024
