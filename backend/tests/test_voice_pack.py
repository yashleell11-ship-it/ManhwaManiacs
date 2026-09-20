"""The roster a listener picks from, and the one thing it refuses to serve.

A voice whose licence cannot be stated must not be offered, because the rule
this pack exists to enforce — no commercial narrator, no voice actor, no
streamer, nobody's family — is unenforceable if provenance is optional.
"""

from __future__ import annotations

import json

import pytest

from services import voice_pack


@pytest.fixture
def pack(tmp_path, monkeypatch):
    monkeypatch.setenv("MM_VOICES_DIR", str(tmp_path))
    voice_pack._cached.cache_clear()

    def write(clips, files=("a.opus", "b.opus", "c.opus")):
        for name in files:
            (tmp_path / name).write_bytes(b"OggS-not-really")
        (tmp_path / "manifest.json").write_text(
            json.dumps({"version": "test", "clips": clips}), encoding="utf-8"
        )
        voice_pack._cached.cache_clear()
        return tmp_path

    return write


def _clip(voice_id, gender="male", f0=120.0, sample="a.opus", **over):
    base = {
        "voice_id": voice_id,
        "gender": gender,
        "median_f0_hz": f0,
        "pitch_spread": 0.2,
        "seconds": 6.0,
        "license": "CC BY 4.0",
        "attribution": "LibriTTS-R",
        "transcript": "A line of speech.",
        "sample": sample,
    }
    base.update(over)
    return base


class TestLoading:
    def test_an_absent_pack_is_empty_not_an_error(self, tmp_path, monkeypatch):
        # The server runs fine with no voices installed; novels simply cannot
        # be given character voices until a pack is dropped in.
        monkeypatch.setenv("MM_VOICES_DIR", str(tmp_path / "nothing"))
        voice_pack._cached.cache_clear()

        assert voice_pack.load_voices() == ()

    def test_a_corrupt_manifest_is_empty_not_a_crash(self, tmp_path, monkeypatch):
        monkeypatch.setenv("MM_VOICES_DIR", str(tmp_path))
        (tmp_path / "manifest.json").write_text("{not json", encoding="utf-8")
        voice_pack._cached.cache_clear()

        assert voice_pack.load_voices() == ()

    def test_voices_are_deepest_first_within_each_gender(self, pack):
        # The axis people choose on. "I want a deeper narrator" has to be
        # answerable by reading down the list.
        pack([
            _clip("m-high", "male", 150.0, "a.opus"),
            _clip("f-high", "female", 220.0, "b.opus"),
            _clip("m-low", "male", 103.0, "c.opus"),
        ])

        got = [v.voice_id for v in voice_pack.load_voices()]

        assert got == ["f-high", "m-low", "m-high"]


class TestLicenceIsTheGate:
    def test_a_clip_with_no_licence_is_not_offered(self, pack):
        pack([
            _clip("named", sample="a.opus"),
            _clip("unlicensed", sample="b.opus", license=None),
        ])

        assert [v.voice_id for v in voice_pack.load_voices()] == ["named"]

    def test_a_clip_with_no_file_on_disk_is_not_offered(self, pack):
        # The picker plays every entry it is given, so an entry that cannot be
        # played is a broken control rather than a missing feature.
        pack([_clip("real", sample="a.opus"), _clip("phantom", sample="gone.opus")])

        assert [v.voice_id for v in voice_pack.load_voices()] == ["real"]


class TestSampleResolution:
    def test_a_sample_resolves_through_the_manifest(self, pack):
        root = pack([_clip("v1", sample="a.opus")])

        assert voice_pack.sample_path("v1") == root / "a.opus"

    def test_an_unknown_voice_has_no_sample(self, pack):
        pack([_clip("v1")])

        assert voice_pack.sample_path("nope") is None

    def test_a_traversal_id_cannot_escape_the_pack(self, pack):
        # The id arrives off a query string. Resolution goes through the
        # manifest precisely so a path is never built from user input.
        pack([_clip("v1")])

        for attempt in ("../../etc/passwd", "..%2f..%2fsettings.json", "/etc/passwd"):
            assert voice_pack.sample_path(attempt) is None


class TestKnownVoice:
    def test_a_voice_in_the_pack_is_known(self, pack):
        pack([_clip("v1")])

        assert voice_pack.is_known_voice("v1") is True

    def test_anything_else_is_not(self, pack):
        pack([_clip("v1")])

        assert voice_pack.is_known_voice("v2") is False
        assert voice_pack.is_known_voice(None) is False
        assert voice_pack.is_known_voice("") is False

    def test_with_no_pack_at_all_it_cannot_refuse(self, tmp_path, monkeypatch):
        # "I cannot check" must not become "I refuse": a deployment may keep
        # the pack only on the box that renders, and refusing every voice there
        # would make casting impossible. The clients hide the picker when the
        # roster is empty, so nothing offers a choice that is not really there.
        monkeypatch.setenv("MM_VOICES_DIR", str(tmp_path / "absent"))
        voice_pack._cached.cache_clear()

        assert voice_pack.is_known_voice("libritts-251") is True
        assert voice_pack.is_known_voice(None) is False


class TestServedShape:
    def test_the_json_says_what_a_listener_needs_to_choose(self, pack):
        pack([_clip("v1", "male", 117.1)])

        got = voice_pack.load_voices()[0].as_json()

        assert got["voice_id"] == "v1"
        assert got["gender"] == "male"
        assert got["pitch_hz"] == 117.1
        assert got["license"] == "CC BY 4.0"
        assert got["transcript"] == "A line of speech."
        # The on-disk filename is deliberately NOT served: the client asks for
        # a sample by voice id and never builds a path.
        assert "sample" not in got
        assert "file" not in got
