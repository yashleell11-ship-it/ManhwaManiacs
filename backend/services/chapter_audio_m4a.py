"""A rendered chapter's audio as AAC in MP4, for the players that cannot read Ogg.

iOS AVPlayer — which ``just_audio`` sits on — cannot open the Ogg container at
all, so every narrated chapter was silent on an iPhone. The stored ``.opus``
stays the one rendition of record; this makes an ``.m4a`` from it the first
time one is asked for, writes it beside the opus, and serves it from disk after
that.

PyAV, not the ffmpeg CLI. The production image is ``python:3.13-slim`` with no
apt packages at all, and ``apt-get install ffmpeg`` pulls in Debian's whole
tree of video codec libraries to encode one audio format. PyAV's abi3 wheel
(~100 MB installed) bundles its own libav*, installs the same way on 3.13 (the
image), 3.14 (CI and the dev venv) and every manylinux box, and keeps the
Dockerfile free of system packages.

**Timing is the property that matters.** The follow-along highlight is driven
by a timing map measured against the opus, so the m4a must start and end on
the same sample. The AAC encoder prepends 1024 samples of priming; the MP4
muxer records them in an edit list, which AVPlayer honours, so playback time 0
is the first real sample and the map needs no correction. The opus's own
pre-skip is dropped by the decoder for the same reason. The tests check the
onset of a tone and the container duration against the source, not just that
bytes came out.

**Freshness is the opus's mtime, copied onto the m4a.** A re-render replaces
the opus in place, and an m4a made from the old one must never be served for
the new one. Comparing "newer than" is not enough — a transcode of the old
opus can finish after the new one lands — so the m4a is stamped with the
mtime of the exact opus it was made from, and is current only while the two
are equal. Anything else is rebuilt.
"""

from __future__ import annotations

import hashlib
import logging
import os
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger("manhwamaniacs.novels.audio")

#: Mono speech. 48 kbps AAC-LC is transparent enough for one narrator's voice
#: and keeps a nine-minute chapter around 3 MB — close to the opus it came
#: from, so a phone saving narration offline pays roughly the same either way.
BITRATE = 48_000

#: The opus decoder always yields 48 kHz, so encoding at it needs no
#: resampling step that could itself shift the timing.
SAMPLE_RATE = 48_000

#: Encoding runs far faster than real time — seconds for a nine-minute
#: chapter. This is for a stuck or pathological file, so a request gives up
#: rather than holding a worker thread indefinitely.
TIMEOUT_SECONDS = 120.0

#: A temp file older than this was left by a process that died mid-transcode.
#: Live ones finish in seconds, so an hour cannot catch one in flight.
STALE_TEMP_SECONDS = 3600

_TEMP_SUFFIX = ".m4a.tmp"


class TranscodeTimeout(Exception):
    """The m4a could not be made within the time allowed."""


class TranscodeFailed(Exception):
    """The opus could not be read or the m4a could not be written."""


# One process can serve several requests for the same chapter at once — an
# iPhone opening a chapter asks for the head and then a Range almost
# immediately. A lock per path makes the second one wait for the first and
# then serve its file, instead of transcoding the same chapter twice. Striped
# rather than one per path so the table cannot grow without bound, and
# because a 2-core box gains nothing from more transcodes at once than this.
# Across processes the temp file + os.replace below is what keeps the final
# file whole; the lock only saves the duplicated work.
_STRIPES = tuple(threading.Lock() for _ in range(4))


def _stripe(path: Path) -> threading.Lock:
    digest = hashlib.sha256(str(path).encode("utf-8")).digest()
    return _STRIPES[digest[0] % len(_STRIPES)]


def m4a_path(opus: Path) -> Path:
    """Where the m4a made from [opus] lives: beside it, same name."""
    return opus.with_suffix(".m4a")


def is_current(opus: Path, m4a: Path) -> bool:
    """Whether [m4a] was made from the opus that is on disk now."""
    try:
        return m4a.stat().st_mtime_ns == opus.stat().st_mtime_ns
    except OSError:
        return False


def ensure_m4a(opus: Path, *, timeout: float = TIMEOUT_SECONDS) -> Path:
    """The m4a for [opus], making it first if there is none or it is stale.

    BLOCKING — call it from a worker thread, never on the event loop.

    Raises ``FileNotFoundError`` when there is no opus, ``TranscodeTimeout``
    when the file could not be made in [timeout] seconds (including time spent
    waiting for another request making it), and ``TranscodeFailed`` when the
    opus could not be converted.
    """
    deadline = time.monotonic() + timeout
    target = m4a_path(opus)
    if not opus.is_file():
        raise FileNotFoundError(opus)
    if is_current(opus, target):
        return target

    lock = _stripe(target)
    if not lock.acquire(timeout=max(0.0, deadline - time.monotonic())):
        raise TranscodeTimeout(str(opus))
    try:
        # Whoever held the lock may have just made it.
        if is_current(opus, target):
            return target
        try:
            _build(opus, target, deadline)
        except TranscodeFailed as exc:
            logger.warning("novels: could not make m4a for %s (%s)", opus, exc)
            raise
        return target
    finally:
        lock.release()


def _build(opus: Path, target: Path, deadline: float) -> None:
    """Transcode into a private temp file, then rename it into place."""
    source_mtime = opus.stat().st_mtime_ns
    # A unique temp name, not a fixed ".tmp": two PROCESSES can both get here
    # for one chapter, and a shared temp path would interleave their writes.
    handle, temp_name = tempfile.mkstemp(
        dir=target.parent, prefix=f"{target.stem}.", suffix=_TEMP_SUFFIX
    )
    os.close(handle)
    # mkstemp makes it 0600; everything else in the audio directory is 0644.
    os.chmod(temp_name, 0o644)
    temp = Path(temp_name)
    try:
        transcode(opus, temp, deadline=deadline)
        if opus.stat().st_mtime_ns != source_mtime:
            # Re-rendered while this ran. What was made is the old chapter;
            # installing it would stamp it as current for nothing.
            raise TranscodeFailed(f"{opus} changed while it was converted")
        # Stamped with the source's mtime so is_current() can tell it was made
        # from exactly this opus. See the module docstring.
        os.utime(temp, ns=(time.time_ns(), source_mtime))
        os.replace(temp, target)
    finally:
        temp.unlink(missing_ok=True)


def transcode(source: Path, dest: Path, *, deadline: float | None = None) -> None:
    """Ogg Opus at [source] to AAC-LC mono in MP4 at [dest].

    ``+faststart`` puts the index at the front, so a player streaming it can
    start before the last byte arrives rather than seeking to the end first.
    """
    import av  # Imported here: nothing else in the app should pay for libav at startup.

    try:
        with av.open(str(source)) as inp, av.open(
            str(dest), "w", format="mp4", options={"movflags": "+faststart"}
        ) as out:
            in_stream = inp.streams.audio[0]
            out_stream = out.add_stream("aac", rate=SAMPLE_RATE, layout="mono")
            out_stream.bit_rate = BITRATE
            # Downmixes a stereo render and converts sample format; the AAC
            # encoder then cuts its own 1024-sample frames.
            resampler = av.AudioResampler(
                format="fltp", layout="mono", rate=SAMPLE_RATE
            )

            def emit(frames) -> None:
                for frame in frames:
                    for packet in out_stream.encode(frame):
                        out.mux(packet)

            for frame in inp.decode(in_stream):
                if deadline is not None and time.monotonic() > deadline:
                    raise TranscodeTimeout(str(source))
                emit(resampler.resample(frame))
            emit(resampler.resample(None))
            for packet in out_stream.encode(None):
                out.mux(packet)
    except TranscodeTimeout:
        raise
    except (av.FFmpegError, OSError, IndexError, ValueError) as exc:
        # IndexError: a file with no audio stream at all.
        raise TranscodeFailed(f"{source}: {exc}") from exc


@dataclass(frozen=True)
class Backfill:
    made: int = 0
    current: int = 0
    failed: int = 0
    orphans_removed: int = 0
    temps_removed: int = 0


def backfill(root: Path, *, timeout: float = TIMEOUT_SECONDS) -> Backfill:
    """Make the m4a for every chapter under [root] that lacks a current one.

    For the chapters narrated before this existed, so the first play on an
    iPhone is not a cold transcode. Also the sweep for what a crash or a
    deletion leaves behind: an m4a whose opus is gone, and a temp file from a
    transcode that died.
    """
    made = current = failed = orphans = temps = 0
    now = time.time()
    for temp in root.glob(f"*/*{_TEMP_SUFFIX}"):
        try:
            if now - temp.stat().st_mtime > STALE_TEMP_SECONDS:
                temp.unlink()
                temps += 1
        except OSError:
            pass
    for m4a in root.glob("*/*.m4a"):
        if not m4a.with_suffix(".opus").exists():
            m4a.unlink(missing_ok=True)
            orphans += 1
    for opus in sorted(root.glob("*/*.opus")):
        if is_current(opus, m4a_path(opus)):
            current += 1
            continue
        try:
            ensure_m4a(opus, timeout=timeout)
            made += 1
        except (TranscodeFailed, TranscodeTimeout, OSError) as exc:
            logger.warning("novels: backfill skipped %s (%s)", opus, exc)
            failed += 1
    return Backfill(made, current, failed, orphans, temps)


def main() -> int:
    """``python -m services.chapter_audio_m4a`` — run once after deploying.

    Inside the backend container, where the audio directory is mounted:
    ``docker exec manhwamaniacs-backend python -m services.chapter_audio_m4a``.
    Safe to repeat: current files are skipped.
    """
    from services.chapter_audio_store import audio_root

    logging.basicConfig(level=logging.INFO)
    root = audio_root()
    result = backfill(root)
    print(
        f"{root}: made {result.made}, already current {result.current}, "
        f"failed {result.failed}, orphans removed {result.orphans_removed}, "
        f"stale temp files removed {result.temps_removed}"
    )
    return 1 if result.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
