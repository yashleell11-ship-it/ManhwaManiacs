"""Everything the renderer will say for one chapter, and in whose voice.

This is the planning that used to live inside ``tools/tts/attribute_and_plan.py``
and ran only when a human invoked it. It moves here because there must be
exactly one planner: the plan decides which voice reads which sentence, and a
server that plans differently from the script would produce audio that
disagrees with the cast list the reader is looking at.

The plan is FROZEN at claim time and handed to the worker whole. The worker
holds no database and makes no casting decisions — it renders exactly the
segments it was given. That is what makes a render reproducible, and what lets
the server notice that a chapter's text changed underneath a render in flight.
"""

from __future__ import annotations

import json
from typing import Any

from sqlalchemy.orm import Session

from services.novel_attribution_service import (
    build_series_cast,
    narrator_voice,
    read_attribution,
    series_pov,
)
from services.novel_audio_plan import SpeechSpan, assign_voices, plan_chapter
from services.novel_dialogue import normalize_name
from services.voice_pack import load_voices

#: The most character voices one book gets. Beyond this a listener stops
#: telling them apart, and the pack runs out anyway.
VOICE_CEILING = 12


def _flattest(gender: str) -> str | None:
    """The clip that reads most like narration, for this gender.

    Flatness rather than pitch: IndexTTS disentangles emotion from identity,
    so an expressive reference bleeds a permanent colour into every line it
    ever reads. That is right for narration and only for narration — it is
    also why the owner can override this, since the rule systematically
    avoids the deepest voices in the pack.
    """
    pool = [v for v in load_voices() if v.gender == gender]
    if not pool:
        pool = list(load_voices())
    if not pool:
        return None
    return min(pool, key=lambda v: v.pitch_spread).voice_id


def build_chapter_plan(
    db: Session,
    source_id: str,
    series_key: str,
    chapter_key: str,
    paragraphs: list[str],
) -> dict[str, Any] | None:
    """The segments to render, or None when the chapter is not attributed yet.

    Returns None rather than raising: an unattributed chapter is the ordinary
    state for almost the whole library, and the caller answers "nothing to do"
    rather than walking an error path.
    """
    record = read_attribution(db, source_id, series_key, chapter_key)
    if not record.get("attributed"):
        return None

    cast = build_series_cast(db, source_id, series_key)
    pov = series_pov(db, source_id, series_key)

    gender_of = {member.normalized_name: member.gender for member in cast}

    def narrator_clip(who: str | None) -> str | None:
        """The voice reading narration in a chapter narrated by [who].

        PER CHAPTER, not per series. A book that rotates POV has a different
        narrator in different chapters, and reading a woman's chapter in the
        series' default male voice is wrong in a way no amount of correct
        character casting makes up for.
        """
        gender = gender_of.get(normalize_name(who or ""), "unknown")
        if gender not in ("male", "female"):
            gender = "male"
        return _flattest(gender)

    chapter_narrator = record.get("narrator") or pov

    # The owner's choice wins over the derivation, which is the entire point
    # of letting them pick one.
    chosen = narrator_voice(db, source_id, series_key)
    narration_voice = chosen or narrator_clip(chapter_narrator)
    if narration_voice is None:
        return None

    # Every clip a narrator could use is reserved, so no character is handed a
    # voice that reads as narration somewhere else in the book.
    reserved = {narration_voice}
    if not chosen:
        reserved.add(narrator_clip(pov))

    # A character who narrates EVERY attributed chapter never speaks in
    # anyone else's, so they need no voice of their own. One who narrates
    # some chapters does — see the regression this replaced, where the
    # series' busiest speaker held no voice at all.
    sole = pov if _narrates_everything(db, source_id, series_key, pov) else None

    locked = {
        member.normalized_name: member.voice_id
        for member in cast
        if member.locked and member.voice_id
    }
    voices = assign_voices(
        [(member.display_name, member.gender) for member in cast],
        [
            (voice.voice_id, voice.gender)
            for voice in load_voices()
            if voice.voice_id not in reserved
            and voice.voice_id not in locked.values()
        ],
        pov=sole,
        ceiling=VOICE_CEILING,
    )
    # An owner's pinned voice is not a suggestion. It overwrites whatever the
    # automatic pass produced for that character.
    voices.update(locked)

    # This chapter's narrator reads their own dialogue — they are the same
    # person — so they get no second voice here. Any OTHER chapter's narrator
    # is an ordinary character in this one.
    narrator_key = normalize_name(chapter_narrator or "")
    chapter_voices = {k: v for k, v in voices.items() if k != narrator_key}

    spans = [
        SpeechSpan(s["p"], s["s"], s["e"], s["speaker"])
        for s in record.get("spans") or []
    ]
    segments = plan_chapter(paragraphs, spans, chapter_voices)
    if not segments:
        return None

    used = sorted({narration_voice} | set(chapter_voices.values()))
    return {
        # The identity triple travels WITH the plan. Without it a plan file is
        # a list of sentences with no way to prove which chapter it belongs
        # to, which is how a render ends up written under the wrong key.
        "source_id": source_id,
        "series_key": series_key,
        "chapter_key": chapter_key,
        "narrator": chapter_narrator,
        "narrator_voice": narration_voice,
        "voices": used,
        "segments": [
            {
                "i": index,
                "text": segment.text,
                "voice": segment.voice_id or narration_voice,
                "speaker": segment.speaker,
                "p": segment.paragraph,
                "s": segment.start,
                "e": segment.end,
                "speech": segment.is_speech,
            }
            for index, segment in enumerate(segments)
        ],
    }


def _narrates_everything(
    db: Session, source_id: str, series_key: str, pov: str | None
) -> bool:
    if not pov:
        return False
    from sqlalchemy import select

    from database.models import NovelChapterAttribution

    told = [
        json.loads(row)[0]
        for row in db.execute(
            select(NovelChapterAttribution.pov).where(
                NovelChapterAttribution.source_id == source_id,
                NovelChapterAttribution.series_key == series_key,
                NovelChapterAttribution.pov.is_not(None),
            )
        ).scalars()
        if row and json.loads(row)
    ]
    if not told:
        return False
    return all(normalize_name(n) == normalize_name(pov) for n in told)


def plan_digest(plan: dict[str, Any]) -> str:
    """A stable hash of a plan, so a late upload can be recognised as stale.

    Sorted keys and no whitespace, because this has to match across a Windows
    box and a Linux server and two Python versions.
    """
    import hashlib

    payload = json.dumps(plan, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()
