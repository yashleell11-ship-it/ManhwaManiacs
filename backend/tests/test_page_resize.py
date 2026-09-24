"""Server-side page downscaling: ``GET /sources/.../pages/.../image?w=``.

WHAT THIS IS, AND WHAT IT IS NOT. It is the cover proxy's ``?w=`` contract
extended to reader pages so clients learn one rule. It is NOT a fix for the
reader feeling like 30 Hz: measured over 24 real page images from eight live
sources, webtoon strips publish 720-800 px wide, at or below what a DPR-3
phone already asks for, so on a phone this changes nothing for exactly the
images that cost the most to decode. ``image_resize``'s page section carries
the numbers; these tests pin the behaviour they argued for.

Covered here:
  * the snap ladder, and the one place it deliberately diverges from covers —
    a request ABOVE the top rung yields the ORIGINAL rather than clamping down
    to 1600, because answering a request for detail by removing detail is the
    one thing this must never do
  * no upscaling, and no near-pointless downscaling either: the source has to
    be meaningfully wider before any CPU is spent
  * the megapixel ceiling, which is the whole reason this is safe to put in
    front of the hot route — a 12 MP webtoon strip is passed through, not
    rendered, and the refusal is decided from the header
  * WebP negotiation and that ``Vary: Accept`` rides along even when the
    original was served
  * ``X-Page-Width`` is EXACT when present and ABSENT when the original was
    served, so a client can always tell what it got
  * every hostile/broken input: junk, HTML error pages, a pixel bomb, an
    animated image, a truncated file — all serve the original, never a 500
  * NOTHING IS EVER STORED. The no-chapter-images rule is the architectural
    constraint this feature lives under.
"""

from __future__ import annotations

import io
import os
from unittest.mock import patch

import pytest

from services import image_resize
from services.image_resize import (
    PAGE_WIDTHS,
    negotiate_image_format,
    resize_page,
    snap_page_width,
)

SRC = "asurascans"
PAGE = "chapter-1:1"


# ---------------------------------------------------------------------------
# fixtures: real image bytes
# ---------------------------------------------------------------------------


def _noise_jpeg(width: int = 1600, height: int = 2400, quality: int = 92) -> bytes:
    """An incompressible JPEG standing in for a full-resolution scan.

    Noise on purpose: a flat colour compresses to nothing, which would make
    "the resize saved bytes" pass for the wrong reason.
    """
    from PIL import Image

    image = Image.frombytes("RGB", (width, height), os.urandom(width * height * 3))
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=quality)
    return buffer.getvalue()


def _strip_jpeg(width: int = 800, height: int = 6000) -> bytes:
    """A webtoon strip: narrow, very tall, and past the megapixel ceiling.

    Drawn rather than random so it encodes at a plausible size — a 4.8 MP
    field of noise is a 9 MB JPEG, which is not what a strip looks like.
    """
    from PIL import Image, ImageDraw

    image = Image.new("RGB", (width, height), (250, 250, 248))
    draw = ImageDraw.Draw(image)
    for y in range(0, height, 90):
        draw.rectangle((40, y + 8, width - 40, y + 74), outline=(20, 20, 20), width=3)
        draw.ellipse((90, y + 20, 250, y + 66), fill=(180, 180, 190))
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=88)
    return buffer.getvalue()


def _png(width: int = 1600, height: int = 1200, *, alpha: bool = False) -> bytes:
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
        Image.new("RGB", (1600, 1200), (index * 40, 10, 10)) for index in range(frames)
    ]
    buffer = io.BytesIO()
    images[0].save(buffer, "WEBP", save_all=True, append_images=images[1:], duration=80)
    return buffer.getvalue()


def _dimensions(data: bytes) -> tuple[int, int]:
    from PIL import Image

    with Image.open(io.BytesIO(data)) as image:
        return image.size


# ---------------------------------------------------------------------------
# the width ladder
# ---------------------------------------------------------------------------


def test_no_width_means_the_original():
    assert snap_page_width(None) is None


@pytest.mark.parametrize(
    "requested, expected",
    [
        (1, 480),
        (480, 480),
        (481, 720),
        (768, 800),  # the web reader's 768 px column at DPR 1
        (800, 800),
        (1040, 1080),  # a 400 px column on a 2.6x Android phone
        (1200, 1200),  # the same column at DPR 3
        (1536, 1600),  # a 768 px column at DPR 2
        (1600, 1600),
    ],
)
def test_arbitrary_widths_snap_up_to_the_ladder(requested, expected):
    """Up, never down: snapping down would hand back a SOFTER image than the
    client asked for, and sharpness is the product."""
    assert snap_page_width(requested) == expected


def test_a_request_above_the_ladder_gets_the_original_not_a_clamp():
    """THE DIVERGENCE FROM COVERS. ``snap_cover_width`` clamps an absurd width
    down to its largest rung, because a 4000 px cover request is nonsense. A
    2400 px page request from a large tablet is not nonsense, and answering it
    by rendering 1600 px would remove the detail it asked for."""
    assert snap_page_width(1601) is None
    assert snap_page_width(2400) is None
    assert snap_page_width(10_000) is None


def test_every_snapped_width_is_on_the_ladder_or_none():
    assert {snap_page_width(n) for n in range(1, 2000)} <= set(PAGE_WIDTHS) | {None}


# ---------------------------------------------------------------------------
# format negotiation — shared with covers on purpose
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "accept, expected",
    [
        ("image/avif,image/webp,image/apng,*/*", "webp"),
        ("image/webp", "webp"),
        ("image/webp;q=0.8", "webp"),
        ("image/jpeg,image/png", "jpeg"),
        ("*/*", "jpeg"),
        ("image/*", "jpeg"),
        (None, "jpeg"),
    ],
)
def test_webp_only_when_the_client_says_so(accept, expected):
    assert negotiate_image_format(accept) == expected


# ---------------------------------------------------------------------------
# the resize itself
# ---------------------------------------------------------------------------


def test_resize_shrinks_a_full_resolution_scan():
    original = _noise_jpeg()
    media_type, data = resize_page(original, width=800, fmt="jpeg")

    assert media_type == "image/jpeg"
    assert _dimensions(data)[0] == 800
    assert len(data) < len(original) / 2


def test_both_formats_produce_a_valid_smaller_image_at_the_right_size():
    original = _noise_jpeg(width=1600, height=2400)
    for fmt, expected_type in (("jpeg", "image/jpeg"), ("webp", "image/webp")):
        media_type, data = resize_page(original, width=800, fmt=fmt)
        assert media_type == expected_type
        assert _dimensions(data) == (800, 1200)
        assert len(data) < len(original)


def test_height_is_never_clamped_only_width_binds():
    """For a tall strip WIDTH is the only sensible axis. Binding the height
    would silently narrow the page and break the aspect ratio the reader lays
    out against."""
    original = _noise_jpeg(width=1600, height=6000)  # 9.6 MP, so lift the ceiling
    with patch.object(image_resize, "_MAX_PAGE_SOURCE_PIXELS", 20_000_000):
        _, data = resize_page(original, width=800, fmt="webp")

    assert _dimensions(data) == (800, 3000)


def test_a_png_page_with_alpha_becomes_a_flat_jpeg():
    _, data = resize_page(_png(alpha=True), width=800, fmt="jpeg")

    from PIL import Image

    with Image.open(io.BytesIO(data)) as image:
        assert image.mode == "RGB"


def test_never_returns_more_bytes_than_it_was_given():
    """The invariant that makes this safe to apply unconditionally: whatever
    the source, the client never receives MORE than it would have before."""
    tiny = _noise_jpeg(width=900, height=1200, quality=30)
    result = resize_page(tiny, width=720, fmt="jpeg")
    if result is not None:
        assert len(result[1]) < len(tiny)


# --- no upscaling, and no pointless downscaling ----------------------------


def test_a_page_narrower_than_the_request_is_never_upscaled():
    """A 400 px column on a 3x phone asks for 1200 and must GET 1200 — which
    for a source that only publishes 800 px means the original, untouched."""
    source = _noise_jpeg(width=800, height=1200)
    assert resize_page(source, width=1200, fmt="webp") is None


def test_a_page_the_same_width_as_the_request_is_left_alone():
    source = _noise_jpeg(width=800, height=1200)
    assert resize_page(source, width=800, fmt="webp") is None


def test_a_barely_wider_page_is_not_worth_the_cpu():
    """1120 -> 1080 is a 4% shave that costs ~150 ms on the VPS, and the bytes
    it saves come from re-encoding sharp line art rather than from the resize.
    Serving the original is cheaper AND sharper, and it can never be wrong:
    the client gets more pixels than it asked for, never fewer."""
    assert resize_page(_noise_jpeg(width=1120, height=1600), width=1080, fmt="webp") is None


def test_a_meaningfully_wider_page_is_rendered():
    """The other side of that line: 1120 -> 800 is 1.4x and is worth it."""
    result = resize_page(_noise_jpeg(width=1120, height=1600), width=800, fmt="webp")
    assert result is not None
    assert _dimensions(result[1]) == (800, 1143)


@pytest.mark.parametrize("source_width, requested, renders", [
    (1000, 800, True),    # exactly the 1.25x threshold
    (999, 800, False),    # just under it
])
def test_the_downscale_threshold_is_where_it_says_it_is(source_width, requested, renders):
    result = resize_page(
        _noise_jpeg(width=source_width, height=1400), width=requested, fmt="webp"
    )
    assert (result is not None) is renders


# --- the megapixel ceiling: the guard that makes this safe on 2 vCPU -------


def test_a_long_webtoon_strip_is_passed_through_not_rendered():
    """THE LOAD-BEARING REFUSAL. A 12 MP strip costs 0.5-1.7 s of VPS CPU to
    render, uncached, on a request the reader is already waiting on, and five
    of them at once took RSS from 576 MB to 1082 MB. Above the ceiling the
    answer is always the original."""
    strip = _strip_jpeg(width=800, height=6000)  # 4.8 MP, past the 4 MP ceiling
    assert resize_page(strip, width=480, fmt="webp") is None


def test_the_same_strip_would_have_rendered_below_the_ceiling():
    """Otherwise the test above could pass for the wrong reason — the strip
    has to be a thing this could have resized."""
    strip = _strip_jpeg(width=800, height=6000)
    with patch.object(image_resize, "_MAX_PAGE_SOURCE_PIXELS", 20_000_000):
        result = resize_page(strip, width=480, fmt="webp")

    assert result is not None
    assert _dimensions(result[1]) == (480, 3600)


@pytest.mark.filterwarnings("ignore::PIL.Image.DecompressionBombWarning")
def test_the_ceiling_is_checked_before_anything_is_decoded():
    """A decompression bomb must be refused from the HEADER. These bytes are
    from untrusted third-party sites: a 100 MP PNG of one flat colour is a few
    KB on the wire and ~300 MB of RGB in this process."""
    from PIL import Image

    buffer = io.BytesIO()
    Image.new("RGB", (10_000, 10_000), (255, 255, 255)).save(buffer, "PNG")
    bomb = buffer.getvalue()
    # 100 MP: ~300 MB of RGB in this process for well under a MB on the wire.
    assert (10_000 * 10_000 * 3) / len(bomb) > 500

    with patch.object(Image.Image, "load", side_effect=AssertionError("decoded!")):
        assert resize_page(bomb, width=800, fmt="webp") is None


def test_pillows_own_bomb_guard_is_not_the_thing_we_rely_on():
    """Pillow's DecompressionBombWarning sits at ~89 MP and only WARNS. The
    page ceiling is 22x tighter and is a hard refusal."""
    from PIL import Image

    assert image_resize._MAX_PAGE_SOURCE_PIXELS < Image.MAX_IMAGE_PIXELS


# --- fallbacks: every one of these means "serve the original" ---------------


def test_junk_bytes_fall_back_to_the_original():
    assert resize_page(b"\x00\x01\x02not an image at all", width=800, fmt="jpeg") is None


def test_html_from_a_broken_source_falls_back_to_the_original():
    """Sources answer with an HTML error page more often than anyone would
    like; that must be a heavy page, never a 500."""
    assert resize_page(b"<html><body>404</body></html>", width=800, fmt="jpeg") is None


def test_empty_body_falls_back_to_the_original():
    assert resize_page(b"", width=800, fmt="jpeg") is None


def test_a_truncated_image_falls_back_to_the_original():
    """A half-delivered body decodes far enough to look valid and then throws
    mid-render. It must not become a 500 either."""
    truncated = _noise_jpeg()[: len(_noise_jpeg()) // 3]
    assert resize_page(truncated, width=800, fmt="jpeg") is None


def test_an_animated_image_is_left_alone():
    assert resize_page(_animated_webp(), width=800, fmt="webp") is None


def test_an_unknown_target_format_is_refused():
    assert resize_page(_noise_jpeg(), width=800, fmt="gif") is None


def test_missing_pillow_degrades_to_the_original(monkeypatch):
    import builtins

    original = _noise_jpeg()  # built BEFORE PIL is taken away
    real_import = builtins.__import__

    def _no_pil(name, *args, **kwargs):
        if name == "PIL" or name.startswith("PIL."):
            raise ImportError("no PIL here")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", _no_pil)
    assert resize_page(original, width=800, fmt="jpeg") is None


# ---------------------------------------------------------------------------
# the route
# ---------------------------------------------------------------------------

from connectors.models import Chapter, Page  # noqa: E402
from tests.test_browse_service_ssrf import _FakeConnector  # noqa: E402


def _vary(response) -> set[str]:
    """The ``Vary`` tokens, case-folded. CORS adds ``Origin`` on some Starlette
    versions (1.7.0 on every response when origins are listed), so these tests
    assert what this route owns — ``Accept`` — not the whole header."""
    return {t.strip().lower() for t in response.headers.get("Vary", "").split(",") if t.strip()}


class _PageConnector(_FakeConnector):
    """Registry-level fake serving one fixed page image for any page id."""

    def __init__(self, data: bytes, media_type: str = "image/jpeg") -> None:
        super().__init__(frozenset({"cdn.example.com"}))
        self._data = data
        self._media_type = media_type
        self.fetches = 0

    @property
    def is_browsable(self) -> bool:
        return True

    def get_chapters(self, series_id: str) -> list[Chapter]:
        return []

    def find_page(self, page_id: str) -> Page | None:
        return Page(
            id=page_id,
            chapter_id="chapter-1",
            number=1,
            remote_url="https://cdn.example.com/page.jpg",
        )

    def fetch_proxied_image(self, url: str):
        self.fetches += 1
        return self._media_type, self._data


def _page_get(client, connector, path, **kwargs):
    with patch("services.outbound_security.is_public_address", return_value=True):
        with patch("services.browse_service.create_connector", return_value=connector):
            return client.get(path, **kwargs)


PATH = f"/sources/{SRC}/pages/{PAGE}/image"


@pytest.fixture
def page_connector():
    return _PageConnector(_noise_jpeg())


def test_route_without_w_is_byte_for_byte_what_it_always_was(client, page_connector):
    response = _page_get(client, page_connector, PATH)

    assert response.status_code == 200
    assert response.content == page_connector._data
    assert response.headers["content-type"].startswith("image/jpeg")
    assert "X-Page-Width" not in response.headers
    assert "accept" not in _vary(response)


def test_route_with_w_serves_fewer_bytes_and_says_what_it_served(
    client, page_connector
):
    full = _page_get(client, page_connector, PATH)
    small = _page_get(
        client,
        page_connector,
        PATH,
        params={"w": 800},
        headers={"Accept": "image/avif,image/webp,*/*"},
    )

    assert small.status_code == 200
    assert small.headers["content-type"].startswith("image/webp")
    assert small.headers["X-Page-Width"] == "800"
    assert "accept" in _vary(small)
    assert len(small.content) < len(full.content)
    assert _dimensions(small.content)[0] == 800


def test_route_snaps_an_odd_width_and_reports_the_snapped_one(client, page_connector):
    response = _page_get(client, page_connector, PATH, params={"w": 768})

    assert response.headers["X-Page-Width"] == "800"
    assert _dimensions(response.content)[0] == 800


def test_route_header_is_absent_when_the_original_was_served(client):
    """The client's only signal that it did NOT get what it asked for. A
    720 px webtoon strip asked for 1200 px comes back untouched."""
    connector = _PageConnector(_noise_jpeg(width=720, height=1080))
    response = _page_get(client, connector, PATH, params={"w": 1200})

    assert response.status_code == 200
    assert response.content == connector._data
    assert "X-Page-Width" not in response.headers
    # Vary still rides along: the answer COULD have depended on Accept.
    assert "accept" in _vary(response)


def test_route_above_the_ladder_serves_the_original(client, page_connector):
    response = _page_get(client, page_connector, PATH, params={"w": 4000})

    assert response.status_code == 200
    assert response.content == page_connector._data
    assert "X-Page-Width" not in response.headers


def test_route_without_webp_in_accept_gets_jpeg(client, page_connector):
    response = _page_get(
        client,
        page_connector,
        PATH,
        params={"w": 800},
        headers={"Accept": "image/jpeg,image/png"},
    )

    assert response.headers["content-type"].startswith("image/jpeg")
    assert "accept" in _vary(response)


def test_route_rejects_a_nonsense_width_at_validation(client, page_connector):
    assert _page_get(client, page_connector, PATH, params={"w": 0}).status_code == 422
    assert (
        _page_get(client, page_connector, PATH, params={"w": 99999}).status_code == 422
    )


def test_route_etag_revalidation_matches_the_bytes_actually_served(
    client, page_connector
):
    """The ETag is over the RENDERED bytes, so a client holding the original
    must not be told its copy is current when it asked for a width."""
    original = _page_get(client, page_connector, PATH)
    resized = _page_get(client, page_connector, PATH, params={"w": 800})
    assert original.headers["ETag"] != resized.headers["ETag"]

    revalidated = _page_get(
        client,
        page_connector,
        PATH,
        params={"w": 800},
        headers={"If-None-Match": resized.headers["ETag"]},
    )
    assert revalidated.status_code == 304


def test_route_keeps_the_hardening_headers_on_a_resized_page(client, page_connector):
    response = _page_get(client, page_connector, PATH, params={"w": 800})

    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Content-Security-Policy"] == "sandbox"
    assert response.headers["Cache-Control"] == "max-age=86400"
    # NOT ``public``: page bytes are the chapter content and stay out of
    # shared edge caches, resized or not.
    assert "public" not in response.headers["Cache-Control"]


def test_route_serves_a_hostile_page_as_the_original_rather_than_erroring(client):
    connector = _PageConnector(b"<html>upstream is broken</html>")
    response = _page_get(client, connector, PATH, params={"w": 800})

    assert response.status_code == 200
    assert response.content == b"<html>upstream is broken</html>"
    assert "X-Page-Width" not in response.headers


def test_route_stores_absolutely_nothing_on_disk(client, page_connector, db_session):
    """THE ARCHITECTURAL RULE. Covers get a byte-bounded disk cache; chapter
    images get nothing, ever. A library is multi-GB against a ~20 GB VPS."""
    from database.models import SourceCoverCache

    for width in (480, 800, 1200):
        _page_get(client, page_connector, PATH, params={"w": width})

    assert db_session.query(SourceCoverCache).count() == 0


def test_route_renders_every_request_because_nothing_is_cached(
    client, page_connector
):
    """The flip side of storing nothing, and the reason for the megapixel
    ceiling: the upstream fetch AND the render are paid on every single
    request. A cover pays once."""
    first = _page_get(client, page_connector, PATH, params={"w": 800})
    second = _page_get(client, page_connector, PATH, params={"w": 800})

    assert second.content == first.content
    assert page_connector.fetches == 2
