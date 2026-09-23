"""The voices a character can be given, and the clips that demonstrate them.

The pack is DATA, not code: a manifest plus one reference clip per voice,
dropped next to the audio blobs. The renderer conditions on the reference clip
itself, so the sample a listener auditions is the actual voice they will get —
not a rendering of it, and not an approximation.

Only what picks a voice is exposed. ``frontend/AGENTS.md`` records that
character/world extraction was permanently abandoned, and the cast tables are
written to respect it; a voice roster is the same kind of surface and gets the
same restraint. Pitch and length are here because they are how a person
chooses between eighteen strangers reading the same sentence. The transcript is
here because it says what the clip is about to say.

``license`` is non-nullable on purpose. It is the enforcement mechanism for the
rule that no voice in this pack may be a commercial narrator, a voice actor, a
streamer or anyone's family: a clip that cannot state its licence cannot be
served, and the loader drops it rather than guessing.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from core.config import SETTINGS_PATH

_MANIFEST = "manifest.json"

#: Overridable so a worker box and the server can share one pack.
_ENV_DIR = "MM_VOICES_DIR"


def voices_root() -> Path:
    import os

    override = os.getenv(_ENV_DIR)
    return Path(override) if override else SETTINGS_PATH.parent / "voices"


@dataclass(frozen=True, slots=True)
class Voice:
    """One choosable voice."""

    voice_id: str

    #: What the picker calls it. A person cannot choose between "libritts-2803"
    #: and "libritts-251"; they can choose between Atlas and Lucian, and having
    #: heard the voice say its own name is what makes it stick. Falls back to
    #: the id so an unnamed pack is still usable.
    name: str

    #: Two words on how it reads — "deep, steady". Derived from the measured
    #: pitch and spread rather than written by hand, so it cannot drift away
    #: from what the clip actually does.
    character: str
    gender: str
    median_f0_hz: float
    pitch_spread: float
    seconds: float
    license: str
    attribution: str
    transcript: str
    sample: str

    def as_json(self) -> dict:
        return {
            "voice_id": self.voice_id,
            "name": self.name,
            "character": self.character,
            "gender": self.gender,
            # Named for what it tells a listener, not for what it measures: the
            # picker orders by it and says "deeper" next to it.
            "pitch_hz": round(self.median_f0_hz, 1),
            # How much the speaker moves around that pitch. A flat clip reads
            # as narration, an expressive one as a character.
            "expressiveness": round(self.pitch_spread, 3),
            "seconds": round(self.seconds, 1),
            "license": self.license,
            "attribution": self.attribution,
            "transcript": self.transcript,
        }


def _load(root: Path) -> tuple[Voice, ...]:
    manifest = root / _MANIFEST
    if not manifest.is_file():
        return ()
    try:
        raw = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ()
    out: list[Voice] = []
    for clip in raw.get("clips") or []:
        sample = clip.get("sample")
        licence = clip.get("license")
        # No licence, or no clip on disk, means it does not exist as far as
        # this server is concerned. Serving a voice whose provenance cannot be
        # stated is the one failure this pack is built to make impossible.
        if not sample or not licence or not (root / sample).is_file():
            continue
        try:
            out.append(
                Voice(
                    voice_id=str(clip["voice_id"]),
                    name=str(clip.get("name") or clip["voice_id"]),
                    character=str(clip.get("character") or ""),
                    gender=str(clip.get("gender") or "unknown"),
                    median_f0_hz=float(clip.get("median_f0_hz") or 0),
                    pitch_spread=float(clip.get("pitch_spread") or 0),
                    seconds=float(clip.get("seconds") or 0),
                    license=str(licence),
                    attribution=str(clip.get("attribution") or ""),
                    transcript=str(clip.get("transcript") or ""),
                    sample=str(sample),
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    # Deepest first within each gender, which is the axis a person actually
    # chooses on — "I want a deeper narrator" is the request this answers.
    return tuple(sorted(out, key=lambda v: (v.gender, v.median_f0_hz)))


@lru_cache(maxsize=4)
def _cached(root: str, stamp: float) -> tuple[Voice, ...]:
    return _load(Path(root))


def load_voices() -> tuple[Voice, ...]:
    """Every voice this server can offer, deepest first within each gender.

    Cached on the manifest's mtime so adding a voice takes effect without a
    restart, while the ordinary request does not re-read and re-parse a file
    per call.
    """
    root = voices_root()
    manifest = root / _MANIFEST
    try:
        stamp = manifest.stat().st_mtime
    except OSError:
        return ()
    return _cached(str(root), stamp)


def sample_path(voice_id: str) -> Path | None:
    """The clip demonstrating [voice_id], or None.

    Resolved through the manifest rather than by joining the id onto the
    directory: the id arrives off a query string, and a path built from user
    input is one ``../`` away from serving something else entirely.
    """
    for voice in load_voices():
        if voice.voice_id == voice_id:
            candidate = voices_root() / voice.sample
            return candidate if candidate.is_file() else None
    return None


def sample_paths() -> list[Path]:
    """Every sample clip the manifest names that is on disk, resolved.

    For the ops backfill that pre-makes each clip's m4a
    (``python -m services.chapter_audio_m4a``): it works through the same
    manifest the route does, so it touches exactly the files the route could
    serve and nothing else in the directory.
    """
    root = voices_root()
    return [
        root / voice.sample
        for voice in load_voices()
        if (root / voice.sample).is_file()
    ]


def is_known_voice(voice_id: str | None) -> bool:
    """Whether [voice_id] is one this server can offer.

    A server with NO pack installed answers True for anything, and that is
    deliberate. The pack is data on disk, and a deployment can legitimately
    keep it only on the box that renders — in which case this process cannot
    know what is valid, and turning "I cannot check" into "I refuse" would make
    casting impossible on exactly the setups that need it most. An empty roster
    disables the picker in the clients, so nothing offers a choice that is not
    really there; this guard is for a typed or stale id, not for absence.
    """
    if not voice_id:
        return False
    roster = load_voices()
    if not roster:
        return True
    return any(v.voice_id == voice_id for v in roster)
