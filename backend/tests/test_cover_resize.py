"""Server-side cover downscaling: ``GET /sources/.../cover?w=``.

THE FAILURE THIS FIXES. Covers were proxied at source resolution into
thumbnail boxes. Driven in a real browser at a 375 px viewport, 13 of the 24
covers on one ``/sources/mangadex`` page transferred 20.79 MB — mean 1.64 MB,
max 6.27 MB — into a 153x230 CSS px slot; a full grid is ~39 MB against
~25-40 KB for a right-sized cover. ``next/image`` could not fix it (its
optimizer sends no cookies, the route needs ``mm_session``), so the shrinking
had to happen here.

Covered here:
  * the width allowlist — arbitrary integers SNAP onto a closed set, which is
    what stops a thousand ``?w=`` values buying a thousand renders on 2 vCPU
  * format negotiation, and that ``Vary: Accept`` rides along (without it a
    shared cache hands a WebP to a client that asked for JPEG)
  * the resize actually shrinks things, and NEVER returns more bytes than it
    was given
  * every fallback: junk bytes, HTML, an animated cover, an unknown format,
    Pillow missing — all serve the ORIGINAL, never an error
  * the cache: miss renders + stores, hit skips the connector entirely,
    connector-down serves a stale row, the byte budget evicts LRU-first
  * ISOLATION — the one way this could leak. Rendered covers are GLOBAL rows
    with no user_id/profile_id in the key, so the per-(user, profile) 18+ gate
    has to be applied on every read before the cache is consulted. A mature
    source's cached cover must never reach a profile whose gate is closed,
    and switching profiles on one user must flip the answer.
  * without ``?w=`` nothing changes at all, and nothing is written to disk
"""

from __future__ import annotations

import io
import os
from datetime import timedelta
from unittest.mock import patch

import pytest

from core.config import get_settings
from core.errors import AppError
from core.time_utils import utcnow
from database.models import SourceCoverCache
from services import image_resize
from services.image_resize import (
    COVER_WIDTHS,
    negotiate_cover_format,
    resize_cover,
    snap_cover_width,
)
from services.source_cache_service import SourceCacheService

SRC = "asurascans"
KEY = "solo-leveling"


# ---------------------------------------------------------------------------
# fixtures: real image bytes
# ---------------------------------------------------------------------------


def _noise_jpeg(width: int = 800, height: int = 1200, quality: int = 92) -> bytes:
    """A big, incompressible JPEG — a stand-in for a full-resolution cover.

    Noise on purpose: a flat colour compresses to a few hundred bytes, which
    would make "the resize saved bytes" pass for the wrong reason.
    """
    from PIL import Image

    image = Image.frombytes("RGB", (width, height), os.urandom(width * height * 3))
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=quality)
    return buffer.getvalue()


def _png(width: int = 600, height: int = 900, *, alpha: bool = False) -> bytes:
    from PIL import Image

    mode = "RGBA" if alpha else "RGB"
    channels = 4 if alpha else 3
    image = Image.frombytes(
        mode, (width, height), os.urandom(width * height * channels)
    )
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


def _animated_webp(frames: int = 3) -> bytes:
    from PIL import Image

    images = [
        Image.new("RGB", (400, 600), (index * 40, 10, 10)) for index in range(frames)
    ]
    buffer = io.BytesIO()
    images[0].save(buffer, "WEBP", save_all=True, append_images=images[1:], duration=80)
    return buffer.getvalue()


def _dimensions(data: bytes) -> tuple[int, int]:
    from PIL import Image

    with Image.open(io.BytesIO(data)) as image:
        return image.size


# ---------------------------------------------------------------------------
# the width allowlist
# ---------------------------------------------------------------------------


def test_no_width_means_the_original():
    assert snap_cover_width(None) is None


@pytest.mark.parametrize(
    "requested, expected",
    [
        (1, 96),
        (96, 96),
        (97, 160),
        (153, 160),
        (200, 240),
        (306, 360),
        (360, 360),
        (459, 480),
        (660, 720),
        (720, 720),
    ],
)
def test_arbitrary_widths_snap_up_to_the_allowlist(requested, expected):
    assert snap_cover_width(requested) == expected


def test_absurd_widths_snap_down_to_the_largest_allowed():
    """The DoS/cache-explosion guard: no caller can name a width we do not
    already render. Anyone who genuinely wants more asks for the original by
    leaving ``?w=`` off."""
    assert snap_cover_width(4000) == COVER_WIDTHS[-1]
    assert snap_cover_width(10_000) == COVER_WIDTHS[-1]


def test_every_snapped_width_is_on_the_allowlist():
    assert {snap_cover_width(n) for n in range(1, 1200)} <= set(COVER_WIDTHS)


# ---------------------------------------------------------------------------
# format negotiation
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "accept, expected",
    [
        ("image/avif,image/webp,image/apng,*/*", "webp"),
        ("image/webp", "webp"),
        ("image/webp;q=0.8", "webp"),
        ("image/jpeg,image/png", "jpeg"),
        # A bare wildcard is what a dumb HTTP client sends; guessing WebP from
        # it shows a broken image, and guessing JPEG only costs some bytes.
        ("*/*", "jpeg"),
        ("image/*", "jpeg"),
        ("", "jpeg"),
        (None, "jpeg"),
    ],
)
def test_webp_only_when_the_client_says_so(accept, expected):
    assert negotiate_cover_format(accept) == expected


# ---------------------------------------------------------------------------
# the resize itself
# ---------------------------------------------------------------------------


def test_resize_shrinks_a_full_resolution_cover_by_an_order_of_magnitude():
    original = _noise_jpeg()
    media_type, data = resize_cover(original, width=360, fmt="jpeg")

    assert media_type == "image/jpeg"
    assert _dimensions(data)[0] == 360
    assert len(data) < len(original) / 10


def test_both_formats_produce_a_valid_much_smaller_image():
    """Which of the two wins on bytes depends on the artwork (synthetic noise
    is the one case where JPEG wins), so the real WebP-vs-JPEG comparison is a
    measurement against real covers, not an assertion here. What must hold for
    both is: decodable, right width, and an order of magnitude smaller."""
    original = _noise_jpeg()
    for fmt, expected_type in (("jpeg", "image/jpeg"), ("webp", "image/webp")):
        media_type, data = resize_cover(original, width=360, fmt=fmt)
        assert media_type == expected_type
        assert _dimensions(data) == (360, 540)
        assert len(data) < len(original) / 10


def test_aspect_ratio_is_preserved():
    original = _noise_jpeg(width=800, height=1200)
    _, data = resize_cover(original, width=240, fmt="webp")

    width, height = _dimensions(data)
    assert width == 240
    assert height == 360  # 800x1200 is 2:3


def test_a_png_cover_with_alpha_becomes_a_flat_jpeg():
    _, data = resize_cover(_png(alpha=True), width=240, fmt="jpeg")

    from PIL import Image

    with Image.open(io.BytesIO(data)) as image:
        assert image.mode == "RGB"


def test_never_returns_more_bytes_than_it_was_given():
    """The invariant that makes this safe to apply unconditionally: whatever
    the source, the client never receives MORE than it would have before."""
    tiny = _noise_jpeg(width=64, height=96, quality=40)
    assert resize_cover(tiny, width=720, fmt="jpeg") is None


def test_a_small_cover_is_not_upscaled():
    small = _png(width=120, height=180)
    result = resize_cover(small, width=720, fmt="webp")
    if result is not None:  # re-encoding a small PNG to WebP can still win
        assert _dimensions(result[1])[0] <= 120


# --- fallbacks: every one of these means "serve the original" ---------------


def test_junk_bytes_fall_back_to_the_original():
    assert resize_cover(b"\x00\x01\x02not an image at all", width=360, fmt="jpeg") is None


def test_html_from_a_broken_source_falls_back_to_the_original():
    """Sources answer with an HTML error page more often than anyone would
    like; that must be a heavy cover, never a 500."""
    assert resize_cover(b"<html><body>404</body></html>", width=360, fmt="jpeg") is None


def test_empty_body_falls_back_to_the_original():
    assert resize_cover(b"", width=360, fmt="jpeg") is None


def test_an_animated_cover_is_left_alone():
    """A static resize of an animated cover is a behaviour change, not an
    optimisation."""
    assert resize_cover(_animated_webp(), width=240, fmt="webp") is None


def test_an_unknown_target_format_is_refused():
    assert resize_cover(_noise_jpeg(), width=360, fmt="gif") is None


def test_a_pixel_bomb_is_refused_before_it_is_decoded(monkeypatch):
    monkeypatch.setattr(image_resize, "_MAX_SOURCE_PIXELS", 1000)
    assert resize_cover(_noise_jpeg(), width=360, fmt="jpeg") is None


def test_missing_pillow_degrades_to_the_original(monkeypatch):
    """The dependency is new; the app must still serve covers without it."""
    import builtins

    original = _noise_jpeg()  # built BEFORE PIL is taken away
    real_import = builtins.__import__

    def _no_pil(name, *args, **kwargs):
        if name == "PIL" or name.startswith("PIL."):
            raise ImportError("no PIL here")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", _no_pil)
    assert resize_cover(original, width=360, fmt="jpeg") is None


# ---------------------------------------------------------------------------
# the cache
# ---------------------------------------------------------------------------


class _CoverBrowse:
    """A ``BrowseService`` stand-in for the cover path only."""

    def __init__(self, data: bytes, media_type: str = "image/jpeg") -> None:
        self.data = data
        self.media_type = media_type
        self.calls = 0
        self.down = False
        self.mature_sources: set[str] = set()
        self.gate_open = True

    def _gate_open(self) -> bool:
        return self.gate_open

    def ensure_visible(self, source_id: str) -> None:
        if source_id in self.mature_sources and not self.gate_open:
            raise AppError(
                "Source not found.", code="source_not_found", status_code=404
            )

    def resolve_series_cover(self, source_id: str, series_id: str):
        self.calls += 1
        if self.down:
            raise RuntimeError("connector down")
        return self.media_type, self.data


def _svc(db, browse=None, data: bytes | None = None):
    browse = browse or _CoverBrowse(data if data is not None else _noise_jpeg())
    return SourceCacheService(db, browse), browse


def test_miss_renders_stores_and_serves(db_session):
    svc, browse = _svc(db_session)

    media_type, data, served = svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert media_type == "image/webp"
    assert served == 360
    assert browse.calls == 1
    row = db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp"))
    assert row is not None
    assert row.byte_size == len(data)
    assert bytes(row.data) == data


def test_hit_never_touches_the_connector(db_session):
    svc, browse = _svc(db_session)
    _, first, _ = svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    _, second, served = svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert browse.calls == 1  # the whole point: one render, one upstream fetch
    assert second == first
    assert served == 360


def test_each_width_and_format_is_its_own_row(db_session):
    svc, browse = _svc(db_session)

    svc.get_series_cover(SRC, KEY, width=240, fmt="webp")
    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")
    svc.get_series_cover(SRC, KEY, width=360, fmt="jpeg")

    assert db_session.get(SourceCoverCache, (SRC, KEY, 240, "webp")) is not None
    assert db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp")) is not None
    assert db_session.get(SourceCoverCache, (SRC, KEY, 360, "jpeg")) is not None


def test_an_expired_row_is_re_rendered(db_session):
    svc, browse = _svc(db_session)
    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")
    row = db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp"))
    row.fetched_at = utcnow() - timedelta(
        minutes=get_settings().cover_cache_ttl_minutes + 1
    )
    db_session.commit()

    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert browse.calls == 2


def test_connector_down_serves_the_stale_row_rather_than_a_hole(db_session):
    svc, browse = _svc(db_session)
    _, rendered, _ = svc.get_series_cover(SRC, KEY, width=360, fmt="webp")
    row = db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp"))
    row.fetched_at = utcnow() - timedelta(days=400)
    db_session.commit()
    browse.down = True

    _, data, served = svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert data == rendered
    assert served == 360


def test_connector_down_with_nothing_cached_still_raises(db_session):
    svc, browse = _svc(db_session)
    browse.down = True

    with pytest.raises(RuntimeError):
        svc.get_series_cover(SRC, KEY, width=360, fmt="webp")


def test_a_cover_that_cannot_be_resized_is_served_and_remembered(db_session):
    """A failure to downscale is a fact worth storing.

    Storing nothing meant every later request re-fetched the same bytes from
    upstream and re-attempted the same decode, forever. The row records the
    refusal instead: the caller still gets the original and still sees
    ``served is None``, but the second reader is answered from the database.
    """
    svc, browse = _svc(db_session, data=b"<html>upstream is broken</html>")

    media_type, data, served = svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert data == b"<html>upstream is broken</html>"
    assert served is None  # the caller can tell it got the original
    row = db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp"))
    assert row is not None
    assert row.resize_failed_at is not None  # the discriminator, not the reason
    assert row.resize_failure == "no_downscale"
    assert row.data == b"<html>upstream is broken</html>"


def test_the_kill_switch_serves_originals_and_stores_nothing(db_session, monkeypatch):
    monkeypatch.setenv("MM_COVER_RESIZE_ENABLED", "false")
    get_settings.cache_clear()
    svc, browse = _svc(db_session)

    _, data, served = svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert served is None
    assert data == browse.data
    assert db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp")) is None


def test_a_row_past_the_per_row_ceiling_is_served_but_not_stored(
    db_session, monkeypatch
):
    monkeypatch.setenv("MM_COVER_CACHE_MAX_ROW_BYTES", "16")
    get_settings.cache_clear()
    svc, browse = _svc(db_session)

    _, data, served = svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert served == 360
    assert len(data) > 16
    assert db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp")) is None


def test_the_byte_budget_evicts_least_recently_used_rows(db_session, monkeypatch):
    """The hard disk bound. Rows are dropped oldest-used-first until the table
    fits ``cover_cache_max_bytes`` — so that number is a ceiling, not a hope."""
    svc, browse = _svc(db_session)
    for index, width in enumerate(COVER_WIDTHS):
        svc.get_series_cover(SRC, f"{KEY}-{index}", width=width, fmt="webp")
    stored = db_session.query(SourceCoverCache).all()
    assert len(stored) == len(COVER_WIDTHS)
    total = sum(row.byte_size for row in stored)
    # Age the rows so LRU order is unambiguous: row 0 is the oldest.
    for index, row in enumerate(
        sorted(stored, key=lambda r: r.width)
    ):
        row.last_used_at = utcnow() - timedelta(days=len(COVER_WIDTHS) - index)
    db_session.commit()

    monkeypatch.setenv("MM_COVER_CACHE_MAX_BYTES", str(total // 2))
    get_settings.cache_clear()
    svc.get_series_cover(SRC, "trigger", width=240, fmt="jpeg")

    remaining = db_session.query(SourceCoverCache).all()
    assert sum(row.byte_size for row in remaining) <= total // 2
    # The smallest widths were the least recently used, so they went first.
    assert COVER_WIDTHS[0] not in {row.width for row in remaining}


def test_lru_bump_is_throttled_so_a_grid_does_not_write_24_rows(db_session):
    """A cover grid is a read; it must not turn into 24 UPDATEs against
    SQLite's single writer."""
    svc, browse = _svc(db_session)
    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")
    row = db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp"))
    stamp = row.last_used_at

    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    db_session.refresh(row)
    assert row.last_used_at == stamp


def test_lru_bump_does_happen_once_the_stamp_is_old(db_session):
    svc, browse = _svc(db_session)
    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")
    row = db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp"))
    row.last_used_at = utcnow() - timedelta(days=2)
    db_session.commit()
    stale_stamp = row.last_used_at

    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    db_session.refresh(row)
    assert row.last_used_at > stale_stamp


# ---------------------------------------------------------------------------
# ISOLATION — the 18+ gate and (user, profile) scoping
# ---------------------------------------------------------------------------
#
# Rendered covers are GLOBAL rows keyed by (source, series, width, format) —
# no user_id, no profile_id, no gate. That is correct (a cover is a property
# of the series, not of the reader) and it is exactly the shape that has
# leaked before, so the gate must be evaluated per request, on the request's
# own profile, BEFORE the cache is consulted. These tests pin that.


def test_service_gated_caller_never_sees_a_mature_sources_cached_cover(db_session):
    svc, browse = _svc(db_session)
    browse.mature_sources.add(SRC)
    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")  # cached by an open profile
    assert db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp")) is not None

    browse.gate_open = False
    with pytest.raises(AppError) as exc_info:
        svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert exc_info.value.status_code == 404  # not 403: existence is not disclosed


def test_service_gate_is_checked_before_the_cache_not_after(db_session):
    """Ordering matters: a gate applied after the lookup would still have read
    the bytes."""
    svc, browse = _svc(db_session)
    browse.mature_sources.add(SRC)
    browse.gate_open = False

    with pytest.raises(AppError):
        svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert browse.calls == 0
    assert db_session.query(SourceCoverCache).count() == 0


# --- route level: the real BrowseService / ProfileContext stack -------------

from connectors.models import Series as ConnectorSeries  # noqa: E402
from tests.test_browse_service_ssrf import _FakeConnector  # noqa: E402


def _vary(response) -> set[str]:
    """The ``Vary`` tokens, case-folded. CORS adds ``Origin`` on some Starlette
    versions (1.7.0 on every response when origins are listed), so these tests
    assert what this route owns — ``Accept`` — not the whole header."""
    return {t.strip().lower() for t in response.headers.get("Vary", "").split(",") if t.strip()}


class _CoverConnector(_FakeConnector):
    """Registry-level fake serving one fixed cover for any series id."""

    def __init__(self, data: bytes, *, mature: bool = False) -> None:
        super().__init__(frozenset({"cdn.example.com"}))
        self._data = data
        self._mature = mature
        self.fetches = 0

    @property
    def is_browsable(self) -> bool:
        return True

    @property
    def is_mature(self) -> bool:
        return self._mature

    def get_series(self, series_id: str):
        return ConnectorSeries(
            id=series_id,
            title="Cover Test",
            cover_url="https://cdn.example.com/cover.jpg",
        )

    def fetch_proxied_image(self, url: str):
        self.fetches += 1
        return "image/jpeg", self._data


@pytest.fixture
def cover_connector():
    return _CoverConnector(_noise_jpeg())


def _cover_get(client, connector, path, **kwargs):
    with patch("services.outbound_security.is_public_address", return_value=True):
        with patch(
            "services.browse_service.create_connector", return_value=connector
        ):
            return client.get(path, **kwargs)


def test_route_without_w_is_byte_for_byte_what_it_always_was(
    client, cover_connector, db_session
):
    response = _cover_get(client, cover_connector, f"/sources/{SRC}/series/{KEY}/cover")

    assert response.status_code == 200
    assert response.content == cover_connector._data
    assert response.headers["content-type"].startswith("image/jpeg")
    assert "X-Cover-Width" not in response.headers
    assert "accept" not in _vary(response)
    # The no-``?w=`` path stores nothing: only DERIVED bytes are ever written.
    assert db_session.query(SourceCoverCache).count() == 0


def test_route_with_w_serves_a_fraction_of_the_bytes(client, cover_connector):
    full = _cover_get(client, cover_connector, f"/sources/{SRC}/series/{KEY}/cover")
    small = _cover_get(
        client,
        cover_connector,
        f"/sources/{SRC}/series/{KEY}/cover",
        params={"w": 360},
        headers={"Accept": "image/avif,image/webp,*/*"},
    )

    assert small.status_code == 200
    assert small.headers["content-type"].startswith("image/webp")
    assert small.headers["X-Cover-Width"] == "360"
    assert "accept" in _vary(small)
    assert len(small.content) < len(full.content) / 10


def test_route_snaps_an_odd_width_and_says_so(client, cover_connector):
    response = _cover_get(
        client,
        cover_connector,
        f"/sources/{SRC}/series/{KEY}/cover",
        params={"w": 153},
    )

    assert response.status_code == 200
    assert response.headers["X-Cover-Width"] == "160"


def test_route_rejects_a_nonsense_width_at_validation(client, cover_connector):
    response = _cover_get(
        client,
        cover_connector,
        f"/sources/{SRC}/series/{KEY}/cover",
        params={"w": 0},
    )
    assert response.status_code == 422


def test_route_without_webp_in_accept_gets_jpeg(client, cover_connector):
    response = _cover_get(
        client,
        cover_connector,
        f"/sources/{SRC}/series/{KEY}/cover",
        params={"w": 360},
        headers={"Accept": "image/jpeg,image/png"},
    )

    assert response.headers["content-type"].startswith("image/jpeg")
    assert "accept" in _vary(response)


def test_route_second_request_is_served_from_the_cache(client, cover_connector):
    path = f"/sources/{SRC}/series/{KEY}/cover"
    first = _cover_get(client, cover_connector, path, params={"w": 360})
    fetches_after_first = cover_connector.fetches
    second = _cover_get(client, cover_connector, path, params={"w": 360})

    assert second.content == first.content
    assert cover_connector.fetches == fetches_after_first  # no upstream fetch at all


def test_route_etag_revalidation_still_works_on_a_resized_cover(
    client, cover_connector
):
    path = f"/sources/{SRC}/series/{KEY}/cover"
    first = _cover_get(client, cover_connector, path, params={"w": 360})
    etag = first.headers["ETag"]

    second = _cover_get(
        client,
        cover_connector,
        path,
        params={"w": 360},
        headers={"If-None-Match": etag},
    )

    assert second.status_code == 304
    assert second.headers["ETag"] == etag


def test_route_gated_profile_gets_404_despite_a_cached_mature_cover(
    client, as_user, make_user, make_profile, db_session
):
    """THE LEAK TEST. One profile with the 18+ gate open renders and caches a
    mature source's cover; a different profile with the gate closed must get a
    404 and not one byte of it."""
    connector = _CoverConnector(_noise_jpeg(), mature=True)
    user = make_user("household")
    adult = make_profile(user.id, "NSFW", mature_content_enabled=True)
    child = make_profile(user.id, "SFW", mature_content_enabled=False)
    path = f"/sources/{SRC}/series/{KEY}/cover"

    warm = _cover_get(
        client, connector, path, params={"w": 360}, headers=as_user(user.id, adult.id)
    )
    assert warm.status_code == 200
    # The row really is there and really would answer — otherwise this test
    # would pass for the wrong reason.
    cached = db_session.get(SourceCoverCache, (SRC, KEY, 360, "jpeg"))
    assert cached is not None and bytes(cached.data) == warm.content
    fetches_before = connector.fetches

    blocked = _cover_get(
        client, connector, path, params={"w": 360}, headers=as_user(user.id, child.id)
    )

    assert blocked.status_code == 404  # not 403: existence is not disclosed
    assert warm.content not in blocked.content
    assert connector.fetches == fetches_before  # refused before anything ran


def test_route_open_profile_is_served_the_cached_mature_cover(
    client, as_user, make_user, make_profile
):
    connector = _CoverConnector(_noise_jpeg(), mature=True)
    user = make_user("adult")
    adult = make_profile(user.id, "NSFW", mature_content_enabled=True)
    path = f"/sources/{SRC}/series/{KEY}/cover"

    first = _cover_get(
        client, connector, path, params={"w": 360}, headers=as_user(user.id, adult.id)
    )
    fetches = connector.fetches
    second = _cover_get(
        client, connector, path, params={"w": 360}, headers=as_user(user.id, adult.id)
    )

    assert second.status_code == 200
    assert second.content == first.content
    assert connector.fetches == fetches


def test_route_gate_flips_with_the_profile_on_the_same_user(
    client, as_user, make_user, make_profile
):
    """The scoping is per-(user, profile), not per-user: the same account gets
    different answers from its two profiles."""
    connector = _CoverConnector(_noise_jpeg(), mature=True)
    user = make_user("switcher")
    adult = make_profile(user.id, "NSFW", mature_content_enabled=True)
    child = make_profile(user.id, "SFW", mature_content_enabled=False)
    path = f"/sources/{SRC}/series/{KEY}/cover"

    assert (
        _cover_get(
            client,
            connector,
            path,
            params={"w": 360},
            headers=as_user(user.id, adult.id),
        ).status_code
        == 200
    )
    assert (
        _cover_get(
            client,
            connector,
            path,
            params={"w": 360},
            headers=as_user(user.id, child.id),
        ).status_code
        == 404
    )


def test_route_another_users_gated_profile_cannot_read_the_cached_cover(
    client, as_user, make_user, make_profile
):
    connector = _CoverConnector(_noise_jpeg(), mature=True)
    owner = make_user("owner")
    owner_profile = make_profile(owner.id, "NSFW", mature_content_enabled=True)
    stranger = make_user("stranger")
    stranger_profile = make_profile(stranger.id, "SFW", mature_content_enabled=False)
    path = f"/sources/{SRC}/series/{KEY}/cover"

    _cover_get(
        client,
        connector,
        path,
        params={"w": 360},
        headers=as_user(owner.id, owner_profile.id),
    )
    blocked = _cover_get(
        client,
        connector,
        path,
        params={"w": 360},
        headers=as_user(stranger.id, stranger_profile.id),
    )

    assert blocked.status_code == 404


# --- the DB connection is not held across the network fetch ----------------


class _TransactionWatchingBrowse(_CoverBrowse):
    """Records whether the caller still held a DB transaction mid-fetch."""

    def __init__(self, data: bytes, session):
        super().__init__(data)
        self._session = session
        self.in_transaction_during_fetch: list[bool] = []

    def resolve_series_cover(self, source_id: str, series_id: str):
        self.in_transaction_during_fetch.append(self._session.in_transaction())
        return super().resolve_series_cover(source_id, series_id)


def test_no_db_connection_is_held_across_the_cover_fetch(db_session):
    """Reading the cache row checks a connection out of the pool, and the
    session holds it until the transaction ends. Fetching the cover while that
    transaction is open pins one of the pool's 15 connections for the whole
    upstream request -- so one stalled source painted across a cover grid made
    unrelated requests (the library list, saving progress, the reader
    manifest) queue for ``pool_timeout`` and then fail with a raw QueuePool
    error. An open transaction here is that bug.
    """
    browse = _TransactionWatchingBrowse(_noise_jpeg(), db_session)
    svc = SourceCacheService(db_session, browse)

    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert browse.in_transaction_during_fetch == [False]


def test_no_db_connection_is_held_while_refetching_an_expired_row(db_session):
    """The same, on the path that has a row to fall back on: the stale-serve
    snapshot must be taken and the transaction closed before the fetch, not
    left open so the ORM row stays readable."""
    browse = _TransactionWatchingBrowse(_noise_jpeg(), db_session)
    svc = SourceCacheService(db_session, browse)
    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    row = db_session.get(SourceCoverCache, (SRC, KEY, 360, "webp"))
    row.fetched_at = utcnow() - timedelta(days=400)
    db_session.commit()

    svc.get_series_cover(SRC, KEY, width=360, fmt="webp")

    assert browse.in_transaction_during_fetch == [False, False]
