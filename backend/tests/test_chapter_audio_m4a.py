"""A chapter's narration as AAC/M4A, for iOS.

AVPlayer cannot open Ogg at all, so every narrated chapter was silent on an
iPhone. The properties worth pinning are not "bytes came out":

* TIMING. The follow-along highlight is a map measured against the opus. The
  AAC encoder prepends priming samples; if the file does not tell the player to
  skip them, every highlight lands late by the same amount on every line. The
  tests find the onset of a tone and compare durations, sample-accurately.
* STALENESS. A re-render replaces the opus in place. An m4a made from the old
  one must never be served for the new one.
* CONCURRENCY. An iPhone asks for a file and a Range of it almost at once. Two
  requests must not both transcode, and neither may see a half-written file.

These tests really transcode. They do not skip when PyAV is missing: it is in
requirements.txt, CI installs it, and a skipped transcode test is not a test.
"""

from __future__ import annotations

import array
import math
import os
import struct
import threading
import time
from pathlib import Path

import av
import pytest

from services import chapter_audio_m4a
from services.chapter_audio_m4a import (
    TranscodeFailed,
    TranscodeTimeout,
    backfill,
    backfill_samples,
    ensure_m4a,
    is_current,
    m4a_path,
)

RATE = 48_000
TONE_START = 0.5
TONE_END = 1.0


def make_opus(
    path: Path,
    *,
    seconds: float = 1.5,
    tone: tuple[float, float] = (TONE_START, TONE_END),
    freq: float = 440.0,
    layout: str = "mono",
) -> Path:
    """A real Ogg Opus file: silence, then a tone at a known time, then silence.

    A tone rather than noise so the onset is unambiguous after a lossy codec.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    channels = 2 if layout == "stereo" else 1
    count = int(seconds * RATE)
    samples = array.array("f")
    for i in range(count):
        t = i / RATE
        value = 0.5 * math.sin(2 * math.pi * freq * t) if tone[0] <= t < tone[1] else 0.0
        samples.extend([value] * channels)
    with av.open(str(path), "w", format="ogg") as out:
        stream = out.add_stream("libopus", rate=RATE, layout=layout)
        stream.bit_rate = 32_000
        frame = av.AudioFrame(format="flt", layout=layout, samples=count)
        frame.planes[0].update(samples.tobytes())
        frame.sample_rate = RATE
        frame.pts = 0
        for packet in stream.encode(frame):
            out.mux(packet)
        for packet in stream.encode(None):
            out.mux(packet)
    return path


def decode(path: Path) -> dict:
    """What a player would get: duration, first audible sample, and format."""
    with av.open(str(path)) as container:
        stream = container.streams.audio[0]
        onset = None
        decoded = 0
        for frame in container.decode(stream):
            plane = array.array("f", bytes(frame.planes[0]))[: frame.samples]
            if onset is None:
                for i, value in enumerate(plane):
                    if abs(value) > 0.1:
                        onset = (decoded + i) / frame.sample_rate
                        break
            decoded += frame.samples
        return {
            # The container's own duration: for MP4, what the edit list says
            # is playable, which is what AVPlayer reports and plays.
            "duration": container.duration / av.time_base,
            "decoded": decoded / stream.rate,
            "onset": onset,
            "codec": stream.codec_context.name,
            "profile": stream.codec_context.profile,
            "channels": stream.codec_context.channels,
        }


def top_level_boxes(path: Path) -> list[str]:
    """The MP4's top-level box types, in file order."""
    data = path.read_bytes()
    boxes, offset = [], 0
    while offset + 8 <= len(data):
        size, kind = struct.unpack(">I4s", data[offset : offset + 8])
        if size == 1:
            size = struct.unpack(">Q", data[offset + 8 : offset + 16])[0]
        boxes.append(kind.decode("latin-1"))
        if size < 8:
            break
        offset += size
    return boxes


@pytest.fixture
def opus(tmp_path):
    return make_opus(tmp_path / "ab" / "abcdef.opus")


class TestTheFileItMakes:
    def test_it_is_aac_lc_mono_in_mp4(self, opus):
        m4a = ensure_m4a(opus)

        info = decode(m4a)
        assert m4a.suffix == ".m4a" and m4a.parent == opus.parent
        assert info["codec"] == "aac"
        assert info["profile"] == "LC"
        assert info["channels"] == 1
        assert top_level_boxes(m4a)[0] == "ftyp"

    def test_the_index_comes_before_the_audio(self, opus):
        # faststart: a player streaming it can begin before the last byte
        # arrives instead of seeking to the end of the file for the index.
        boxes = top_level_boxes(ensure_m4a(opus))

        assert boxes.index("moov") < boxes.index("mdat")

    def test_the_tone_starts_when_it_starts_in_the_opus(self, opus):
        # The encoder's 1024 priming samples are ~21 ms. Unskipped, every
        # highlight would lag the voice by that; the edit list must hide them.
        source = decode(opus)
        converted = decode(ensure_m4a(opus))

        assert source["onset"] == pytest.approx(TONE_START, abs=0.005)
        assert converted["onset"] == pytest.approx(source["onset"], abs=0.005)

    def test_it_lasts_as_long_as_the_opus(self, tmp_path):
        # A nine-second chapter, so rounding to AAC's 1024-sample frames would
        # show up if the tail padding were counted as playable.
        opus = make_opus(tmp_path / "ab" / "long.opus", seconds=9.0, tone=(4.0, 6.0))

        source = decode(opus)
        converted = decode(ensure_m4a(opus))

        assert converted["duration"] == pytest.approx(source["decoded"], abs=0.03)
        assert converted["onset"] == pytest.approx(4.0, abs=0.005)

    def test_a_stereo_render_is_folded_to_mono(self, tmp_path):
        opus = make_opus(tmp_path / "ab" / "stereo.opus", layout="stereo")

        info = decode(ensure_m4a(opus))

        assert info["channels"] == 1
        assert info["onset"] == pytest.approx(TONE_START, abs=0.005)

    def test_speech_rate_audio_stays_small(self, tmp_path):
        # ~48 kbps mono: a minute is ~360 KB. A tone is harder to code than
        # silence, so this is a ceiling on the real thing, not a best case.
        opus = make_opus(tmp_path / "ab" / "minute.opus", seconds=60.0, tone=(0.0, 60.0))

        size = ensure_m4a(opus).stat().st_size

        assert size < 60 * 56_000 / 8


class TestWhenItIsMade:
    def test_the_second_request_serves_the_file_the_first_made(self, opus, monkeypatch):
        calls = []
        real = chapter_audio_m4a.transcode
        monkeypatch.setattr(
            chapter_audio_m4a, "transcode",
            lambda *a, **k: (calls.append(a), real(*a, **k)),
        )

        first = ensure_m4a(opus)
        inode = first.stat().st_ino
        second = ensure_m4a(opus)

        assert len(calls) == 1
        assert second == first and second.stat().st_ino == inode

    def test_a_rerender_is_never_served_the_old_m4a(self, opus, tmp_path):
        old = ensure_m4a(opus)
        old_bytes = old.read_bytes()

        # A re-render lands the way /render/complete lands it: a new file
        # renamed over the old one. The tone moves from 0.5 s to 1.0 s.
        fresh = make_opus(tmp_path / "staging.opus", seconds=1.5, tone=(1.0, 1.4), freq=880.0)
        os.replace(fresh, opus)

        assert not is_current(opus, old)
        again = ensure_m4a(opus)
        assert again.read_bytes() != old_bytes
        assert decode(again)["onset"] == pytest.approx(1.0, abs=0.005)

    def test_it_is_stamped_with_the_opus_it_came_from(self, opus):
        # "Newer than the opus" is not enough: a transcode of the OLD opus can
        # finish after a re-render lands. Equality with the source's mtime is.
        m4a = ensure_m4a(opus)

        assert m4a.stat().st_mtime_ns == opus.stat().st_mtime_ns

    def test_a_rerender_during_the_transcode_is_not_installed(self, opus, tmp_path, monkeypatch):
        real = chapter_audio_m4a.transcode
        replacement = make_opus(tmp_path / "staging.opus", tone=(1.0, 1.4))

        def rerender_midway(source, dest, **kwargs):
            real(source, dest, **kwargs)
            os.replace(replacement, opus)
            os.utime(opus, ns=(time.time_ns(), time.time_ns() + 5_000_000_000))

        monkeypatch.setattr(chapter_audio_m4a, "transcode", rerender_midway)

        with pytest.raises(TranscodeFailed):
            ensure_m4a(opus)
        assert not m4a_path(opus).exists()
        assert list(opus.parent.glob("*.tmp")) == []

    def test_concurrent_first_requests_transcode_once(self, opus, monkeypatch):
        calls = []
        real = chapter_audio_m4a.transcode

        def slow(*args, **kwargs):
            calls.append(args)
            time.sleep(0.2)  # long enough that every thread arrives meanwhile
            real(*args, **kwargs)

        monkeypatch.setattr(chapter_audio_m4a, "transcode", slow)
        results, errors = [], []

        def request():
            try:
                results.append(ensure_m4a(opus))
            except Exception as exc:  # noqa: BLE001 - reported below
                errors.append(exc)

        threads = [threading.Thread(target=request) for _ in range(6)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        assert errors == []
        assert len(calls) == 1
        assert len(set(results)) == 1
        assert decode(results[0])["codec"] == "aac"

    def test_no_temp_file_is_left_behind(self, opus):
        ensure_m4a(opus)

        assert sorted(p.name for p in opus.parent.iterdir()) == [
            "abcdef.m4a", "abcdef.opus",
        ]


class TestWhenItCannotBeMade:
    def test_a_missing_opus_is_file_not_found(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            ensure_m4a(tmp_path / "ab" / "nothing.opus")

    def test_a_corrupt_opus_fails_cleanly(self, tmp_path):
        bad = tmp_path / "ab" / "bad.opus"
        bad.parent.mkdir(parents=True)
        bad.write_bytes(b"OggS" + b"\0" * 400)

        with pytest.raises(TranscodeFailed):
            ensure_m4a(bad)
        assert sorted(p.name for p in bad.parent.iterdir()) == ["bad.opus"]

    def test_it_gives_up_at_the_deadline(self, tmp_path):
        opus = make_opus(tmp_path / "ab" / "long.opus", seconds=20.0)

        with pytest.raises(TranscodeTimeout):
            ensure_m4a(opus, timeout=0.0)
        assert sorted(p.name for p in opus.parent.iterdir()) == ["long.opus"]

    def test_waiting_on_another_request_counts_against_the_deadline(self, opus):
        lock = chapter_audio_m4a._stripe(m4a_path(opus))
        lock.acquire()
        try:
            started = time.monotonic()
            with pytest.raises(TranscodeTimeout):
                ensure_m4a(opus, timeout=0.2)
            assert time.monotonic() - started < 2
        finally:
            lock.release()


class TestBackfill:
    """``python -m services.chapter_audio_m4a``: the chapters narrated before
    this existed, so the first iPhone play is not a cold transcode."""

    def test_every_chapter_gets_one_and_a_rerun_does_nothing(self, tmp_path):
        a = make_opus(tmp_path / "aa" / "a1.opus")
        b = make_opus(tmp_path / "bb" / "b1.opus")

        first = backfill(tmp_path)
        second = backfill(tmp_path)

        assert (first.made, first.current, first.failed) == (2, 0, 0)
        assert (second.made, second.current) == (0, 2)
        assert is_current(a, m4a_path(a)) and is_current(b, m4a_path(b))

    def test_an_m4a_whose_opus_is_gone_is_removed(self, tmp_path):
        orphan = tmp_path / "cc" / "gone.m4a"
        orphan.parent.mkdir(parents=True)
        orphan.write_bytes(b"stale")

        result = backfill(tmp_path)

        assert result.orphans_removed == 1 and not orphan.exists()

    def test_a_dead_transcodes_temp_file_is_swept_and_a_live_one_is_not(self, tmp_path):
        shard = tmp_path / "dd"
        shard.mkdir()
        dead = shard / "x.abc123.m4a.tmp"
        live = shard / "y.def456.m4a.tmp"
        dead.write_bytes(b"half")
        live.write_bytes(b"half")
        old = time.time() - 2 * chapter_audio_m4a.STALE_TEMP_SECONDS
        os.utime(dead, (old, old))

        result = backfill(tmp_path)

        assert result.temps_removed == 1
        assert not dead.exists() and live.exists()

    def test_one_bad_chapter_does_not_stop_the_rest(self, tmp_path):
        bad = tmp_path / "ee" / "bad.opus"
        bad.parent.mkdir(parents=True)
        bad.write_bytes(b"not audio")
        good = make_opus(tmp_path / "ff" / "good.opus")

        result = backfill(tmp_path)

        assert (result.made, result.failed) == (1, 1)
        assert is_current(good, m4a_path(good))


class TestBackfillSamples:
    """The same command, for the voice pack's preview clips: Ogg Opus like
    the chapters, and just as silent on an iPhone."""

    def _pack(self, tmp_path, monkeypatch, names):
        import json

        from services import voice_pack

        clips = []
        for i, name in enumerate(names):
            clips.append({
                "voice_id": f"v{i}", "gender": "male", "median_f0_hz": 100 + i,
                "license": "CC BY 4.0", "sample": name,
            })
        (tmp_path / "manifest.json").write_text(
            json.dumps({"clips": clips}), encoding="utf-8"
        )
        monkeypatch.setenv("MM_VOICES_DIR", str(tmp_path))
        voice_pack._cached.cache_clear()

    def test_every_named_clip_gets_one_and_a_rerun_does_nothing(
        self, tmp_path, monkeypatch
    ):
        from services.voice_pack import sample_paths

        a = make_opus(tmp_path / "a.opus")
        b = make_opus(tmp_path / "clips" / "b.opus")
        # On disk, but not in the manifest: not a sample, so left alone.
        stray = make_opus(tmp_path / "stray.opus")
        self._pack(tmp_path, monkeypatch, ["a.opus", "clips/b.opus"])

        first = backfill_samples(sample_paths())
        second = backfill_samples(sample_paths())

        assert (first.made, first.current, first.failed) == (2, 0, 0)
        assert (second.made, second.current) == (0, 2)
        assert is_current(a, m4a_path(a)) and is_current(b, m4a_path(b))
        assert not m4a_path(stray).exists()

    def test_one_bad_clip_does_not_stop_the_rest(self, tmp_path, monkeypatch):
        from services.voice_pack import sample_paths

        (tmp_path / "bad.opus").write_bytes(b"not audio")
        good = make_opus(tmp_path / "good.opus")
        self._pack(tmp_path, monkeypatch, ["bad.opus", "good.opus"])

        result = backfill_samples(sample_paths())

        assert (result.made, result.failed) == (1, 1)
        assert is_current(good, m4a_path(good))

    def test_the_command_does_chapters_and_then_voices(
        self, tmp_path, monkeypatch, capsys
    ):
        audio = tmp_path / "audio"
        voices = tmp_path / "voices"
        chapter = make_opus(audio / "ab" / "c1.opus")
        clip = make_opus(voices / "v.opus")
        self._pack(voices, monkeypatch, ["v.opus"])
        monkeypatch.setenv("MM_AUDIO_DIR", str(audio))

        assert chapter_audio_m4a.main() == 0

        assert is_current(chapter, m4a_path(chapter))
        assert is_current(clip, m4a_path(clip))
        out = capsys.readouterr().out
        assert f"{voices}: made 1" in out
