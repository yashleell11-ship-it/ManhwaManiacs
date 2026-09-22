"""``GET /novels/audio/series`` — which chapters of a book are listenable.

One call so a table of contents can mark what can be listened to. The property
worth pinning is that it answers about a BOOK: asking per chapter is several
hundred round trips for a long novel, and all but a handful answer "no".
"""

from __future__ import annotations

import json

from database.models import NovelChapterCache

from tests.test_novels_flag import (  # noqa: F401
    SERIES,
    STUB_SOURCE,
    novels_off,
    novels_on,
    stub_registered,
)


def cache_chapter(db, chapter_key, *, number=1.0):
    db.add(
        NovelChapterCache(
            source_id=STUB_SOURCE,
            series_key=SERIES,
            chapter_key=chapter_key,
            title=f"Chapter {number:g}",
            chapter_number=number,
            paragraphs=json.dumps(["A line of prose."]),
            word_count=4,
        )
    )
    db.commit()


def render(tmp_path, monkeypatch, chapter_key, *, timing=True, size=2048):
    """Put audio on disk for one chapter, the way a render would."""
    from services.chapter_audio_store import chapter_paths

    monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
    audio, timing_path = chapter_paths(STUB_SOURCE, SERIES, chapter_key)
    audio.parent.mkdir(parents=True, exist_ok=True)
    audio.write_bytes(b"O" * size)
    if timing:
        timing_path.write_text(
            json.dumps({"total_ms": 1000, "segments": []}), encoding="utf-8"
        )
    return audio


def fetch(client):
    return client.get(
        "/novels/audio/series", params={"source": STUB_SOURCE, "series": SERIES}
    )


class TestCoverage:
    def test_only_chapters_with_audio_are_listed(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # Absence is the ordinary state for almost the whole library. A row of
        # zeroes per chapter would be most of the payload saying nothing.
        for key in ("ch-1", "ch-2", "ch-3"):
            cache_chapter(db_session, key)
        render(tmp_path, monkeypatch, "ch-2")

        body = fetch(novels_on).json()

        assert [c["chapter_key"] for c in body["chapters"]] == ["ch-2"]
        assert body["chapters"][0]["bytes"] == 2048
        assert body["chapters"][0]["has_timing"] is True

    def test_a_book_with_nothing_rendered_answers_empty_not_404(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        cache_chapter(db_session, "ch-1")
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))

        response = fetch(novels_on)

        assert response.status_code == 200
        assert response.json()["chapters"] == []

    def test_audio_without_a_timing_map_is_still_listed(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # It plays; it just cannot highlight. Hiding it would be worse than
        # offering it without follow-along.
        cache_chapter(db_session, "ch-1")
        render(tmp_path, monkeypatch, "ch-1", timing=False)

        body = fetch(novels_on).json()

        assert body["chapters"][0]["chapter_key"] == "ch-1"
        assert body["chapters"][0]["has_timing"] is False

    def test_another_book_s_audio_is_not_reported_here(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # The store hashes the whole identity triple, so this is really a test
        # that the route passes the series through rather than globbing.
        from services.chapter_audio_store import chapter_paths

        cache_chapter(db_session, "ch-1")
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
        other, _ = chapter_paths(STUB_SOURCE, "some-other-book", "ch-1")
        other.parent.mkdir(parents=True, exist_ok=True)
        other.write_bytes(b"OOOO")

        assert fetch(novels_on).json()["chapters"] == []

    def test_a_chapter_not_in_the_text_cache_is_not_reported(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # Documented edge, asserted so it is a decision rather than a
        # surprise: the answer is derived from the text cache, which is an
        # LRU. Evicted text means the audio stops being ADVERTISED — it is
        # still on disk and still plays.
        render(tmp_path, monkeypatch, "ch-9")

        assert fetch(novels_on).json()["chapters"] == []


class TestCanRender:
    """Whether asking for narration can ever produce audio on this server.

    With no render box configured a queued chapter is never claimed, and a
    client that offers the button anyway shows "in progress" forever. This is
    the flag a client hides that button on.
    """

    def test_no_render_token_means_narration_cannot_be_requested(
        self, novels_on, db_session, monkeypatch
    ):
        from core.config import get_settings

        monkeypatch.delenv("MM_RENDER_WORKER_TOKEN", raising=False)
        get_settings.cache_clear()
        cache_chapter(db_session, "ch-1")

        body = fetch(novels_on).json()

        assert body["can_render"] is False
        # Listening to what already exists is unaffected.
        assert body["narratable"] == ["ch-1"]

    def test_a_blank_token_counts_as_none(
        self, novels_on, db_session, monkeypatch
    ):
        # The same rule that decides whether the worker's routes are mounted.
        from core.config import get_settings

        monkeypatch.setenv("MM_RENDER_WORKER_TOKEN", "   ")
        get_settings.cache_clear()

        assert fetch(novels_on).json()["can_render"] is False

    def test_a_configured_render_box_means_it_can(
        self, novels_on, db_session, monkeypatch
    ):
        from core.config import get_settings

        monkeypatch.setenv("MM_RENDER_WORKER_TOKEN", "a-render-token")
        get_settings.cache_clear()

        assert fetch(novels_on).json()["can_render"] is True


class TestFlagOff:
    def test_it_is_a_stock_404_when_novels_are_off(self, novels_off):
        assert fetch(novels_off).status_code == 404
