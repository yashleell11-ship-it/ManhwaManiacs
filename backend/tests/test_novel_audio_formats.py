"""``GET /novels/audio/file?format=`` and ``highlight_safe`` on ``GET /novels/audio``.

iOS AVPlayer cannot open Ogg at all, so every narrated chapter was unplayable
on an iPhone. ``format=m4a`` serves AAC in MP4, made from the stored opus on
the first request. What has to hold at the HTTP layer:

* Range. iOS refuses to play a progressive MP4 from a server that does not
  answer ``Range`` with 206, so this is not an optimisation for m4a — it is
  whether it plays at all.
* Nothing else changes: the default is still the opus, byte for byte, and a
  chapter with no audio is still the same plain 404.

``highlight_safe`` is the other half of the same release. The chapter cache
refetches, and text that comes back a character different moves every offset
in the timing map; a client highlighting against moved offsets lights up the
wrong words, which is worse than lighting up none.
"""

from __future__ import annotations

import json

from database.models import NovelChapterCache
from services.chapter_audio_store import chapter_paths, rendered_chapters
from services.novel_attribution_service import chapter_fingerprint

from tests.test_chapter_audio_m4a import make_opus
from tests.test_novels_flag import (  # noqa: F401
    SERIES,
    STUB_SOURCE,
    novels_off,
    novels_on,
    stub_registered,
)

CHAPTER = "ch-1"
PARAGRAPHS = ["The first line.", "“Then we go,” he said."]


def render(tmp_path, monkeypatch, *, fingerprint=None, timing=True, segments=None):
    """A real opus on disk, the way /render/complete leaves it."""
    monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
    audio, timing_path = chapter_paths(STUB_SOURCE, SERIES, CHAPTER)
    make_opus(audio)
    if timing:
        record = {"total_ms": 1500, "segments": segments or [
            {"i": 0, "start_ms": 0, "end_ms": 1500, "p": 0, "s": 0, "e": 15,
             "voice": "v1", "speech": True},
        ]}
        if fingerprint is not None:
            record["text_fingerprint"] = fingerprint
        timing_path.write_text(json.dumps(record), encoding="utf-8")
    return audio


def _voicing(paragraphs):
    """A timing map voicing every paragraph the way the render cuts them: the
    closing quote of a line of dialogue is left out of the spoken segment."""
    segments = []
    for p, text in enumerate(paragraphs):
        end = len(text) - 1 if text.endswith("\u201d") else len(text)
        segments.append({"i": p, "start_ms": p * 700, "end_ms": p * 700 + 700,
                         "p": p, "s": 0, "e": end, "voice": "v1", "speech": True})
    return segments


def cache(db, paragraphs=PARAGRAPHS, *, chapter=CHAPTER):
    db.add(NovelChapterCache(
        source_id=STUB_SOURCE, series_key=SERIES, chapter_key=chapter,
        title="Chapter 1", chapter_number=1.0,
        paragraphs=json.dumps(paragraphs), word_count=8,
    ))
    db.commit()


def file(client, fmt=None, headers=None):
    params = {"source": STUB_SOURCE, "series": SERIES, "chapter": CHAPTER}
    if fmt is not None:
        params["format"] = fmt
    return client.get("/novels/audio/file", params=params, headers=headers or {})


def meta(client):
    return client.get("/novels/audio", params={
        "source": STUB_SOURCE, "series": SERIES, "chapter": CHAPTER}).json()


class TestFormats:
    def test_the_default_is_still_the_stored_opus(self, novels_on, tmp_path, monkeypatch):
        audio = render(tmp_path, monkeypatch)

        response = file(novels_on)

        assert response.status_code == 200
        assert response.headers["content-type"] == "audio/ogg"
        assert response.content == audio.read_bytes()

    def test_ogg_asked_for_by_name_is_the_same_file(self, novels_on, tmp_path, monkeypatch):
        audio = render(tmp_path, monkeypatch)

        response = file(novels_on, "ogg")

        assert response.headers["content-type"] == "audio/ogg"
        assert response.content == audio.read_bytes()

    def test_m4a_is_aac_in_mp4(self, novels_on, tmp_path, monkeypatch):
        render(tmp_path, monkeypatch)

        response = file(novels_on, "m4a")

        assert response.status_code == 200
        assert response.headers["content-type"] == "audio/mp4"
        # An MP4 opens with its ftyp box; an Ogg page would start "OggS".
        assert response.content[4:8] == b"ftyp"

    def test_m4a_is_made_once_and_kept_beside_the_opus(self, novels_on, tmp_path, monkeypatch):
        audio = render(tmp_path, monkeypatch)

        first = file(novels_on, "m4a").content
        stored = audio.with_suffix(".m4a")
        inode = stored.stat().st_ino
        second = file(novels_on, "m4a").content

        assert first == second == stored.read_bytes()
        assert stored.stat().st_ino == inode

    def test_any_other_format_is_refused(self, novels_on, tmp_path, monkeypatch):
        render(tmp_path, monkeypatch)

        response = file(novels_on, "flac")

        assert response.status_code == 422
        assert not list(tmp_path.rglob("*.m4a"))

    def test_m4a_for_an_unrendered_chapter_is_the_plain_404(self, novels_on, tmp_path, monkeypatch):
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))

        response = file(novels_on, "m4a")

        assert response.status_code == 404
        # The same body the opus answers with, so a client needs no new case.
        assert response.json() == file(novels_on).json()

    def test_m4a_is_dark_when_novels_are_off(self, novels_off, tmp_path, monkeypatch):
        render(tmp_path, monkeypatch)

        assert file(novels_off, "m4a").status_code == 404
        assert not list(tmp_path.rglob("*.m4a"))

    def test_an_opus_that_will_not_convert_is_an_error_not_a_hang(
        self, novels_on, tmp_path, monkeypatch
    ):
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
        audio, _ = chapter_paths(STUB_SOURCE, SERIES, CHAPTER)
        audio.parent.mkdir(parents=True)
        audio.write_bytes(b"OggS" + b"\0" * 400)

        response = file(novels_on, "m4a")

        assert response.status_code == 500
        assert response.json()["code"] == "audio_convert_failed"
        assert not list(tmp_path.rglob("*.m4a"))


class TestRange:
    """Both formats, because iOS will not play a progressive MP4 without it."""

    def _ranged(self, client, fmt):
        full = file(client, fmt).content
        part = file(client, fmt, {"Range": "bytes=100-299"})
        return full, part

    def test_ogg_answers_a_range_with_206(self, novels_on, tmp_path, monkeypatch):
        render(tmp_path, monkeypatch)

        full, part = self._ranged(novels_on, "ogg")

        assert part.status_code == 206
        assert part.headers["accept-ranges"] == "bytes"
        assert part.headers["content-range"] == f"bytes 100-299/{len(full)}"
        assert part.content == full[100:300]

    def test_m4a_answers_a_range_with_206(self, novels_on, tmp_path, monkeypatch):
        render(tmp_path, monkeypatch)

        full, part = self._ranged(novels_on, "m4a")

        assert part.status_code == 206
        assert part.headers["content-type"] == "audio/mp4"
        assert part.headers["accept-ranges"] == "bytes"
        assert part.headers["content-range"] == f"bytes 100-299/{len(full)}"
        assert part.content == full[100:300]

    def test_a_cold_m4a_answers_its_first_request_with_a_range(
        self, novels_on, tmp_path, monkeypatch
    ):
        # AVPlayer's very first request is often "bytes=0-1", before any full
        # fetch has made the file. The transcode has to happen under a Range.
        render(tmp_path, monkeypatch)

        part = file(novels_on, "m4a", {"Range": "bytes=0-1"})

        assert part.status_code == 206
        assert part.headers["content-range"].startswith("bytes 0-1/")
        assert part.content == b"\0\0"  # the top half of the ftyp box's size

    def test_the_whole_m4a_advertises_ranges(self, novels_on, tmp_path, monkeypatch):
        render(tmp_path, monkeypatch)

        response = file(novels_on, "m4a")

        assert response.headers["accept-ranges"] == "bytes"
        assert int(response.headers["content-length"]) == len(response.content)


class TestHighlightSafe:
    def test_true_when_the_render_matches_the_text_served_now(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        cache(db_session)
        render(tmp_path, monkeypatch, fingerprint=chapter_fingerprint(PARAGRAPHS))

        body = meta(novels_on)

        assert body["available"] is True
        assert body["highlight_safe"] is True

    def test_false_when_the_text_changed_since_the_render(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # One character different: the audio still plays, but every offset
        # after it points somewhere else.
        cache(db_session, [PARAGRAPHS[0], PARAGRAPHS[1].replace("go", "Go")])
        render(tmp_path, monkeypatch, fingerprint=chapter_fingerprint(PARAGRAPHS))

        body = meta(novels_on)

        assert body["available"] is True
        assert body["highlight_safe"] is False
        assert body["segments"]  # still served; the client just does not follow

    def test_an_old_map_that_still_fits_the_text_keeps_follow_along(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # Every chapter narrated before the fingerprint existed has a map like
        # this. Answering false for all of them switched follow-along off for
        # every chapter anyone had. The map is checked against the text
        # instead: every paragraph voiced, each ending at its paragraph's end
        # but for the closing quote the render leaves unspoken.
        # The last paragraph is a line of dialogue: its closing quote is left
        # unspoken, as it is in 116 of production's 488 narrated paragraphs.
        text = PARAGRAPHS + ["\u201cRun.\u201d"]
        cache(db_session, text)
        render(tmp_path, monkeypatch, fingerprint=None, segments=_voicing(text))

        assert meta(novels_on)["highlight_safe"] is True

    def test_an_old_map_over_edited_text_does_not_follow(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # The same map, but a word was added to the first paragraph since: its
        # last segment no longer reaches the paragraph's end.
        cache(db_session, [PARAGRAPHS[0].replace("first", "very first"), PARAGRAPHS[1]])
        render(tmp_path, monkeypatch, fingerprint=None, segments=_voicing(PARAGRAPHS))

        assert meta(novels_on)["highlight_safe"] is False

    def test_an_old_map_that_skips_a_paragraph_does_not_follow(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # A paragraph the map never voices is text the render never saw.
        cache(db_session)
        render(tmp_path, monkeypatch, fingerprint=None)  # voices paragraph 0 only

        assert meta(novels_on)["highlight_safe"] is False

    def test_false_when_there_is_no_timing_map(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        cache(db_session)
        render(tmp_path, monkeypatch, timing=False)

        body = meta(novels_on)

        assert body["available"] is True and body["highlight_safe"] is False

    def test_false_when_the_text_is_not_cached(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # The next read would fetch it fresh, and nothing says it will match.
        render(tmp_path, monkeypatch, fingerprint=chapter_fingerprint(PARAGRAPHS))

        assert meta(novels_on)["highlight_safe"] is False

    def test_another_chapters_text_does_not_vouch_for_this_one(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        cache(db_session, chapter="ch-2")
        render(tmp_path, monkeypatch, fingerprint=chapter_fingerprint(PARAGRAPHS))

        assert meta(novels_on)["highlight_safe"] is False

    def test_false_when_there_is_no_audio(self, novels_on, db_session, tmp_path, monkeypatch):
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
        cache(db_session)

        body = meta(novels_on)

        assert body["available"] is False and body["highlight_safe"] is False


class TestCounting:
    def test_the_m4a_is_not_counted_as_more_audio(self, novels_on, tmp_path, monkeypatch):
        # It is a copy of the opus for iOS, not a second rendition. A table of
        # contents that summed both would report every chapter at double size.
        audio = render(tmp_path, monkeypatch)
        file(novels_on, "m4a")
        assert audio.with_suffix(".m4a").is_file()

        found = rendered_chapters(STUB_SOURCE, SERIES, [CHAPTER])

        assert found == {CHAPTER: {"bytes": audio.stat().st_size, "has_timing": 1}}
