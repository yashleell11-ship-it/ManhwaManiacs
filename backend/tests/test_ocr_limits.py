"""POST /ocr/chapter payload bounds (audit finding 13).

The upload used to accept an unbounded body — any number of pages, unbounded
per-page text, and free-form ``list[Any]`` boxes — written into one global
``chapter_ocr`` row plus an FTS reindex. Pages, text, and boxes are now typed
and capped, with a whole-payload text ceiling.
"""

from __future__ import annotations

import json

import pytest

from routes.ocr import (
    OCR_MAX_BOXES_PER_PAGE,
    OCR_MAX_PAGE_TEXT_CHARS,
    OCR_MAX_PAGES,
    OCR_MAX_TOTAL_TEXT_CHARS,
)

SRC = "mangadex"
SERIES = "bounded-series"
# Uploads are only taken for a chapter the server has seen for the series.
KNOWN = json.dumps([{"key": k} for k in ("c1", "c2", "c3")])


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("ocr-limits")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


@pytest.fixture
def h(as_user, acct):
    uid, pid = acct
    return as_user(uid, pid)


@pytest.fixture
def follows(seed_follow, acct):
    """The caller's library. Uploading is follow-scoped too now, so any test
    whose upload is meant to be ACCEPTED needs this; the rejection tests below
    are refused by the payload validator before the service is ever reached."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES, known_chapters=KNOWN)


def _upload(client, h, pages):
    return client.post(
        "/ocr/chapter",
        json={
            "source_id": SRC,
            "series_key": SERIES,
            "chapter_key": "c1",
            "engine": "mlkit",
            "pages": pages,
        },
        headers=h,
    )


def test_too_many_pages_rejected(client, h):
    pages = [{"page": n + 1, "text": "x"} for n in range(OCR_MAX_PAGES + 1)]
    assert _upload(client, h, pages).status_code == 422


def test_oversized_page_text_rejected(client, h):
    pages = [{"page": 1, "text": "x" * (OCR_MAX_PAGE_TEXT_CHARS + 1)}]
    assert _upload(client, h, pages).status_code == 422


def test_too_many_boxes_rejected(client, h):
    boxes = [{"text": "hi"}] * (OCR_MAX_BOXES_PER_PAGE + 1)
    pages = [{"page": 1, "text": "x", "boxes": boxes}]
    assert _upload(client, h, pages).status_code == 422


def test_total_text_ceiling_rejected(client, h):
    # Each page individually under the per-page cap, but the sum is over the
    # whole-payload ceiling.
    per_page = OCR_MAX_PAGE_TEXT_CHARS
    n_pages = OCR_MAX_TOTAL_TEXT_CHARS // per_page + 1
    assert n_pages <= OCR_MAX_PAGES
    pages = [{"page": n + 1, "text": "x" * per_page} for n in range(n_pages)]
    assert _upload(client, h, pages).status_code == 422


def test_free_form_box_junk_is_dropped_not_stored(client, h, follows):
    """Boxes are a typed shape now: unknown keys and nested JSON are discarded
    before the row is written."""
    pages = [
        {
            "page": 1,
            "text": "the hero spoke",
            "boxes": [
                {
                    "text": "the hero spoke",
                    "x": 1.0,
                    "y": 2.0,
                    "width": 100.0,
                    "height": 20.0,
                    "deeply": {"nested": {"junk": ["x"] * 50}},
                    "huge_extra": "y" * 500,
                }
            ],
        }
    ]
    up = _upload(client, h, pages)
    assert up.status_code == 200, up.text

    got = client.get(
        "/ocr/chapter",
        params={"source": SRC, "series": SERIES, "chapter": "c1"},
        headers=h,
    ).json()
    box = got["page_texts"][0]["boxes"][0]
    assert box["text"] == "the hero spoke"
    assert "deeply" not in box
    assert "huge_extra" not in box


def test_normal_upload_still_works(client, h, follows):
    pages = [
        {"page": 1, "text": "line one", "boxes": [{"text": "line one", "x": 0.0}]},
        {"page": 2, "text": "line two"},
    ]
    up = _upload(client, h, pages)
    assert up.status_code == 200, up.text
    assert up.json()["word_count"] == 4


# --- the row count, not just the payload size -----------------------------


@pytest.fixture
def tiny_chapter_cap(monkeypatch):
    """Two chapters per series, so the ceiling is reachable in a test."""
    from core.config import get_settings

    monkeypatch.setenv("MM_MAX_OCR_CHAPTERS_PER_SERIES", "2")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def _upload_chapter(client, h, chapter_key):
    return client.post(
        "/ocr/chapter",
        json={
            "source_id": SRC,
            "series_key": SERIES,
            "chapter_key": chapter_key,
            "engine": "mlkit",
            "pages": [{"page": 1, "text": "dialogue"}],
        },
        headers=h,
    )


def test_chapter_rows_per_series_are_capped(client, h, follows, tiny_chapter_cap):
    """``chapter_key`` is an opaque connector string nothing validates against
    the source, so the follow gate alone still leaves one axis unbounded: a
    contributor may mint rows under invented chapter keys forever, each worth
    up to the whole-payload ceiling."""
    assert _upload_chapter(client, h, "c1").status_code == 200
    assert _upload_chapter(client, h, "c2").status_code == 200

    over = _upload_chapter(client, h, "c3")
    assert over.status_code == 400, over.text
    assert over.json()["code"] == "ocr_chapter_limit_reached"
    assert over.json()["details"]["max_chapters"] == 2


def test_replacing_an_existing_transcript_still_works_at_the_cap(
    client, h, follows, tiny_chapter_cap
):
    """Only creates are charged. A re-scan of a chapter that already has a row
    adds nothing to the count and must keep working, or the cap would freeze
    every transcript in a full series."""
    assert _upload_chapter(client, h, "c1").status_code == 200
    assert _upload_chapter(client, h, "c2").status_code == 200

    again = client.post(
        "/ocr/chapter",
        json={
            "source_id": SRC,
            "series_key": SERIES,
            "chapter_key": "c1",
            "engine": "apple-vision",
            "pages": [{"page": 1, "text": "a better scan of the same page"}],
        },
        headers=h,
    )
    assert again.status_code == 200, again.text
    assert again.json()["engine"] == "apple-vision"


# --- what is STORED, in bytes, not just the text characters ---------------


def _geometry_page(n, text=""):
    """One page of the most geometry a box carries in the reported payload."""
    tiny = -1.2345678901234567e-300
    box = {
        "text": "",
        "x": tiny,
        "y": tiny,
        "width": tiny,
        "height": tiny,
        "left": tiny,
        "top": tiny,
        "confidence": tiny,
    }
    return {"page": n, "text": text, "boxes": [box] * OCR_MAX_BOXES_PER_PAGE}


def _stored_rows(db_session, chapter_key):
    from database.models import ChapterOcr

    return (
        db_session.query(ChapterOcr)
        .filter_by(source_id=SRC, series_key=SERIES, chapter_key=chapter_key)
        .count()
    )


def test_a_geometry_only_upload_never_creates_a_row(client, h, follows, db_session):
    """The text cap counts characters of text; box geometry is not text. With
    every page's text empty the upload passed the cap and still minted a row
    holding nothing but floats -- the cheapest way to fill the disk."""
    up = _upload(client, h, [_geometry_page(1), _geometry_page(2)])
    assert up.status_code == 400, up.text
    assert up.json()["code"] == "ocr_transcript_empty"
    assert _stored_rows(db_session, "c1") == 0


@pytest.fixture
def small_geometry_cap(monkeypatch):
    from core.config import get_settings

    monkeypatch.setenv("MM_MAX_OCR_GEOMETRY_BYTES", "50000")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_geometry_has_a_stored_ceiling_of_its_own(
    client, h, follows, db_session, small_geometry_cap
):
    """One word of text is enough to get past the empty-transcript refusal, so
    the ceiling that matters is on the geometry the row would hold."""
    up = _upload(client, h, [_geometry_page(1, text="hi"), _geometry_page(2)])
    assert up.status_code == 413, up.text
    assert up.json()["code"] == "ocr_payload_too_large"
    assert up.json()["details"]["max_geometry_bytes"] == 50000
    assert _stored_rows(db_session, "c1") == 0

    # A real chapter under the same ceiling is still taken, however much text
    # it carries: the text has its own cap and is not what is measured here.
    ok = _upload(
        client,
        h,
        [
            {
                "page": 1,
                "text": "x" * OCR_MAX_PAGE_TEXT_CHARS,
                "boxes": [{"text": "the hero spoke", "x": 0.1, "y": 0.2}],
            }
        ],
    )
    assert ok.status_code == 200, ok.text


def test_the_default_geometry_ceiling_refuses_the_reported_payload():
    """The reported request -- 500 pages of empty text, 300 seven-float boxes
    each -- serializes to ~36 MiB. The default ceiling must sit far below it
    and far above a real chapter's boxes (a few hundred KB)."""
    from core.config import get_settings
    from routes.ocr import OcrChapterUpload
    from services.ocr_ingest_service import OcrIngestService

    get_settings.cache_clear()
    body = OcrChapterUpload(
        source_id=SRC,
        series_key=SERIES,
        chapter_key="c1",
        pages=[_geometry_page(n + 1) for n in range(OCR_MAX_PAGES)],
    )
    pages = [p.model_dump(exclude_none=True) for p in body.pages]
    for p in pages:
        p.setdefault("boxes", None)
    geometry = OcrIngestService._geometry_bytes(pages)
    ceiling = get_settings().max_ocr_geometry_bytes
    assert geometry > 30_000_000
    assert 0 < ceiling < geometry // 10
    assert ceiling >= 1_000_000


@pytest.fixture
def small_account_cap(monkeypatch):
    """Room for two ~9 KB chapters and not a third."""
    from core.config import get_settings

    monkeypatch.setenv("MM_MAX_OCR_BYTES_PER_ACCOUNT", "25000")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def _chapter_of_bytes(client, h, chapter_key, word="dialogue"):
    # ~9 KB stored: 4.5 KB of page text, held twice (page_texts + full_text).
    return client.post(
        "/ocr/chapter",
        json={
            "source_id": SRC,
            "series_key": SERIES,
            "chapter_key": chapter_key,
            "engine": "mlkit",
            "pages": [{"page": 1, "text": " ".join([word] * 500)}],
        },
        headers=h,
    )


def test_one_account_cannot_store_past_its_ceiling(
    client, h, follows, db_session, small_account_cap
):
    """Every upload here is individually legal; the sum is what fills a disk."""
    assert _chapter_of_bytes(client, h, "c1").status_code == 200
    assert _chapter_of_bytes(client, h, "c2").status_code == 200

    over = _chapter_of_bytes(client, h, "c3")
    assert over.status_code == 400, over.text
    assert over.json()["code"] == "ocr_storage_limit_reached"
    assert over.json()["details"]["max_bytes"] == 25000
    assert _stored_rows(db_session, "c3") == 0


def test_a_rescan_at_the_account_ceiling_is_charged_only_its_growth(
    client, h, follows, small_account_cap
):
    """Replacing a row frees the old one, so a redo of a chapter must keep
    working for an account that is at its ceiling."""
    assert _chapter_of_bytes(client, h, "c1").status_code == 200
    assert _chapter_of_bytes(client, h, "c2").status_code == 200

    again = _chapter_of_bytes(client, h, "c1", word="dialogs!")
    assert again.status_code == 200, again.text


def test_the_owner_is_not_held_to_the_account_ceiling(
    client, make_user, make_profile, as_user, seed_follow, small_account_cap
):
    owner = make_user("ocr-owner", is_admin=True)
    profile = make_profile(owner.id, "Main")
    seed_follow(
        owner.id, profile.id, source_id=SRC, series_key=SERIES, known_chapters=KNOWN
    )
    owner_h = as_user(owner.id, profile.id)

    for key in ("c1", "c2", "c3"):
        assert _chapter_of_bytes(client, owner_h, key).status_code == 200


# --- the row as STORED, whatever script the text is in ---------------------


def _row_bytes(db_session, chapter_key):
    from database.models import ChapterOcr

    db_session.expire_all()
    row = (
        db_session.query(ChapterOcr)
        .filter_by(source_id=SRC, series_key=SERIES, chapter_key=chapter_key)
        .one()
    )
    return len(row.page_texts.encode("utf-8")) + len(row.full_text.encode("utf-8"))


def _pages_of(char, per_page, n_pages):
    # Space-separated so the upload has words and is not refused as empty.
    unit = (char + " ") * (per_page // 2)
    return [{"page": n + 1, "text": unit} for n in range(n_pages)]


def test_two_million_emoji_are_refused_by_what_they_would_store(
    client, h, follows, db_session
):
    """The reported row: inside the 2M-character cap and with no geometry at
    all, but ``page_texts`` was ``json.dumps`` with ASCII escapes, so each
    emoji stored as a 12-byte surrogate pair -- ~32 MB a row. The per-account
    ceiling admitted eight of them, and it is dodged by registering again."""
    per_page = OCR_MAX_PAGE_TEXT_CHARS
    n_pages = OCR_MAX_TOTAL_TEXT_CHARS // per_page
    up = _upload(client, h, _pages_of("\U0001f600", per_page, n_pages))
    assert up.status_code == 413, up.text
    assert up.json()["code"] == "ocr_payload_too_large"
    assert up.json()["details"]["max_row_bytes"] > 0
    assert _stored_rows(db_session, "c1") == 0


def test_control_characters_are_measured_as_their_escapes(
    client, h, follows, db_session
):
    """JSON escapes a control character as six bytes whatever ``ensure_ascii``
    says, so the bound is measured on the string actually written."""
    per_page = OCR_MAX_PAGE_TEXT_CHARS
    n_pages = OCR_MAX_TOTAL_TEXT_CHARS // per_page
    up = _upload(client, h, _pages_of("\x01", per_page, n_pages))
    assert up.status_code == 413, up.text
    assert up.json()["code"] == "ocr_payload_too_large"
    assert _stored_rows(db_session, "c1") == 0


def test_a_real_chapter_in_any_script_is_stored_at_its_utf8_size(
    client, h, follows, db_session
):
    """A long CJK chapter is stored, and costs its three bytes a character
    (twice: ``page_texts`` and ``full_text``), not six escaped ones."""
    pages = [{"page": n + 1, "text": "漢 " * 1_000} for n in range(60)]
    up = _upload(client, h, pages)
    assert up.status_code == 200, up.text
    cjk_chars = 60 * 1_000
    assert _row_bytes(db_session, "c1") < 2 * 4 * cjk_chars + 10_000
    got = client.get(
        "/ocr/chapter",
        params={"source": SRC, "series": SERIES, "chapter": "c1"},
        headers=h,
    ).json()
    assert got["page_texts"][0]["text"].startswith("漢 漢")


@pytest.fixture
def small_row_cap(monkeypatch):
    from core.config import get_settings

    monkeypatch.setenv("MM_MAX_OCR_ROW_BYTES", "10000")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_the_row_ceiling_binds_the_owner_too(
    client, make_user, make_profile, as_user, seed_follow, small_row_cap
):
    """The per-account ceiling exempts the owner; the per-row one is what
    bounds a single upload, so it holds for everyone."""
    owner = make_user("ocr-row-owner", is_admin=True)
    profile = make_profile(owner.id, "Main")
    seed_follow(
        owner.id, profile.id, source_id=SRC, series_key=SERIES, known_chapters=KNOWN
    )
    owner_h = as_user(owner.id, profile.id)

    # 2,000 emoji: ~10 KB in each of page_texts and full_text as UTF-8.
    over = _upload(client, owner_h, _pages_of("\U0001f600", 4_000, 1))
    assert over.status_code == 413, over.text
    assert over.json()["details"]["max_row_bytes"] == 10000

    ok = _upload(client, owner_h, [{"page": 1, "text": "the hero spoke"}])
    assert ok.status_code == 200, ok.text


def test_a_lone_surrogate_is_refused_not_a_server_error(
    db_session, acct, follows
):
    """Text UTF-8 cannot hold (``"\\ud800"`` is legal JSON) cannot be measured
    as stored bytes either; the service refuses it as a client error rather
    than letting the encode raise."""
    from core.errors import AppError
    from services.ocr_ingest_service import OcrIngestService
    from tests._fakes import FakeBrowse

    uid, pid = acct
    svc = OcrIngestService(db_session, FakeBrowse(), user_id=uid, profile_id=pid)
    with pytest.raises(AppError) as exc:
        svc.ingest_chapter(
            source_id=SRC,
            series_key=SERIES,
            chapter_key="c1",
            pages=[{"page": 1, "text": "hi \ud800 there"}],
        )
    assert exc.value.status_code == 400
    assert exc.value.code == "ocr_text_invalid"
    assert _stored_rows(db_session, "c1") == 0


def test_the_default_row_ceiling_keeps_the_per_upload_budget():
    """``rate_limit_ocr`` is sized around ~3.8 MB stored per upload; the row
    ceiling is what makes that true for any script, and sits far above a real
    chapter (tens of KB)."""
    from core.config import get_settings

    get_settings.cache_clear()
    ceiling = get_settings().max_ocr_row_bytes
    assert 1_000_000 <= ceiling <= 4_000_000
