"""Where a rendered chapter's audio lives, and how it is found again.

Bytes on the FILESYSTEM, never in SQLite. Putting them in the database repeats
the regression that took the nightly backup from 9 MB to 45 MB, at ten times
the scale: a chapter of audio is ~4 MB against ~15 KB of text, so three
thousand chapters is twelve gigabytes flowing through every dump, every
restore, and every replica.

Paths are derived by HASHING the identity triple rather than by joining it.
Connector keys are opaque strings that routinely contain slashes, percent
encoding and dots, so any scheme that puts them in a path is one `../` away
from writing outside the directory — and the user-supplied half of that triple
arrives straight off a query string. A hash has no structure to exploit, and it
is stable, so the same chapter always resolves to the same file.

Sharded one level, like the phone's blob store: a flat directory of several
thousand files makes every listing and every stat slower on the box that can
least afford it.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path

from core.config import SETTINGS_PATH

#: Overridable so a worker box and the server can share a mount.
_ENV_DIR = "MM_AUDIO_DIR"


def audio_root() -> Path:
    override = os.getenv(_ENV_DIR)
    return Path(override) if override else SETTINGS_PATH.parent / "audio"


def chapter_key_hash(source_id: str, series_key: str, chapter_key: str) -> str:
    """A stable, path-safe name for one chapter's audio.

    The separator is a NUL rather than a slash or a colon, because both of
    those appear inside real connector keys and either would let two different
    chapters hash to the same name.
    """
    digest = hashlib.sha256()
    for part in (source_id, series_key, chapter_key):
        digest.update(part.encode("utf-8"))
        digest.update(b"\x00")
    return digest.hexdigest()


def chapter_paths(source_id: str, series_key: str, chapter_key: str) -> tuple[Path, Path]:
    """(audio, timing) paths for one chapter. Neither is guaranteed to exist."""
    name = chapter_key_hash(source_id, series_key, chapter_key)
    shard = audio_root() / name[:2]
    return shard / f"{name}.opus", shard / f"{name}.timing.json"


@dataclass(frozen=True)
class ChapterAudio:
    available: bool
    bytes: int = 0
    total_ms: int = 0
    segments: tuple[dict, ...] = ()


def read_chapter_audio(
    source_id: str, series_key: str, chapter_key: str
) -> ChapterAudio:
    """What is on disk for this chapter, or an honest nothing.

    Absence is the ordinary state for almost the whole library and is never an
    error: a client asking about every chapter should not be walking error
    paths for the normal case.
    """
    audio, timing = chapter_paths(source_id, series_key, chapter_key)
    if not audio.is_file():
        return ChapterAudio(available=False)

    segments: tuple[dict, ...] = ()
    total_ms = 0
    try:
        data = json.loads(timing.read_text(encoding="utf-8"))
        segments = tuple(data.get("segments") or ())
        total_ms = int(data.get("total_ms") or 0)
    except (OSError, ValueError, TypeError):
        # Audio without a timing map still plays; it just cannot highlight.
        # That is a strictly better outcome than refusing to serve it.
        pass

    return ChapterAudio(
        available=True,
        bytes=audio.stat().st_size,
        total_ms=total_ms,
        segments=segments,
    )
