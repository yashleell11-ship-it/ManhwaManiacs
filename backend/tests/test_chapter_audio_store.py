"""Where a rendered chapter's audio lives.

The property worth pinning hardest is path safety. Connector keys are opaque
strings that routinely contain slashes, dots and percent-encoding, and the
user-supplied half arrives straight off a query string — so any scheme that
puts one in a path is a `../` away from writing outside the directory.
"""

from __future__ import annotations

import json

import pytest
from services.chapter_audio_store import (
    audio_root,
    chapter_key_hash,
    chapter_paths,
    read_chapter_audio,
)

TRIPLE = ("novelarchive", "tbate", "ch-121")


@pytest.fixture(autouse=True)
def _root(tmp_path, monkeypatch):
    monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
    return tmp_path


class TestPathSafety:
    def test_a_traversing_key_cannot_escape_the_directory(self, _root):
        audio, timing = chapter_paths("src", "../../../etc", "../../passwd")

        assert _root in audio.parents and _root in timing.parents

    def test_a_key_full_of_slashes_is_still_one_file(self, _root):
        audio, _ = chapter_paths("src", "a/b/c", "d/e/f")

        assert audio.name.endswith(".opus") and "/" not in audio.name

    def test_the_same_chapter_always_resolves_to_the_same_file(self):
        assert chapter_paths(*TRIPLE)[0] == chapter_paths(*TRIPLE)[0]

    def test_different_chapters_do_not_collide(self):
        assert chapter_key_hash("s", "a", "b") != chapter_key_hash("s", "b", "a")

    def test_the_separator_cannot_be_forged_from_key_content(self):
        # A slash or colon separator would let these two different chapters
        # hash to one name, and one would silently serve the other's audio.
        assert chapter_key_hash("s", "a/b", "c") != chapter_key_hash("s", "a", "b/c")
        assert chapter_key_hash("s", "a:b", "c") != chapter_key_hash("s", "a", "b:c")

    def test_it_shards_rather_than_flattening(self, _root):
        # A flat directory of thousands of files makes every listing and stat
        # slower on the box that can least afford it.
        audio, _ = chapter_paths(*TRIPLE)

        assert audio.parent != _root and len(audio.parent.name) == 2


class TestReading:
    def _write(self, timing=True, total_ms=61000):
        audio, timing_path = chapter_paths(*TRIPLE)
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"OggS" + b"\0" * 4096)
        if timing:
            timing_path.write_text(json.dumps({
                "total_ms": total_ms,
                "segments": [{"i": 0, "start_ms": 0, "end_ms": 1200, "p": 1,
                              "s": 0, "e": 9, "voice": "v1", "speech": True}],
            }), encoding="utf-8")

    def test_a_missing_chapter_is_not_an_error(self):
        # Almost the whole library. A client asking about every chapter must
        # not be walking error paths for the normal case.
        found = read_chapter_audio(*TRIPLE)

        assert found.available is False and found.segments == ()

    def test_a_rendered_chapter_reports_its_timings(self):
        self._write()

        found = read_chapter_audio(*TRIPLE)

        assert found.available is True
        assert found.total_ms == 61000
        assert found.segments[0]["end_ms"] == 1200
        assert found.bytes > 4000

    def test_audio_without_a_timing_map_still_plays(self):
        # It just cannot highlight — strictly better than refusing to serve it.
        self._write(timing=False)

        found = read_chapter_audio(*TRIPLE)

        assert found.available is True and found.segments == ()

    def test_a_corrupt_timing_map_does_not_take_the_audio_down(self):
        self._write()
        _audio, timing_path = chapter_paths(*TRIPLE)
        timing_path.write_text("{not json", encoding="utf-8")

        found = read_chapter_audio(*TRIPLE)

        assert found.available is True and found.total_ms == 0

    def test_the_directory_is_overridable(self, _root):
        # So a render worker and the server can share a mount.
        assert audio_root() == _root
