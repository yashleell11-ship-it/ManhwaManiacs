"""Turn an attributed chapter into an ordered list of things to say.

Pure, and deliberately the whole of the decision-making: by the time the GPU is
involved there is nothing left to decide, only text to render. That matters
because a render is minutes of contended GPU and a plan is microseconds — every
mistake is cheaper to find here.

**Segments are SENTENCES, not paragraphs or spans.** This is what makes
follow-along free. The renderer emits one segment at a time (batch of one,
forced by the VRAM fence), so each segment's duration *is*
``len(samples) / sample_rate`` — no forced aligner, no second model, no drift.
Per-paragraph would highlight twenty seconds at a time and be useless;
per-word needs an aligner that will not fit beside the trainer.

**Everything unattributed is the narrator**, and that is the product's baseline
rather than a failure: a line read by the narrator is how every audiobook
already sounds. The failure this avoids is a character voice confidently
attached to the wrong person, which is wrong in the listener's ear on every
line it touches.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, Sequence

from services.novel_attribution import is_voice_candidate
from services.novel_dialogue import normalize_name

#: Sentence end: terminal punctuation, optional closing quote, then whitespace
#: before something that starts a new sentence. Abbreviations are handled by the
#: guard below rather than by a list, because a web novel's abbreviations are
#: not English's.
_SENTENCE_END = re.compile(r'([.!?…。！？]["\'”’]?)\s+(?=[\"\'“‘(\[]?[A-Z0-9“])')

#: A run shorter than this is merged into its neighbour rather than rendered
#: alone. A half-second clip of "Oh," between two long sentences is a click in
#: the audio and a highlight that flickers past unreadably.
MIN_SEGMENT_CHARS = 12

#: Quote marks sit OUTSIDE a speech span, so they land at the edges of the
#: narration either side of it: a run reads `" I turned my head to see Myre. "`.
#: Nothing reads them aloud, but they are inside the range the playhead
#: highlights, so the follow-along lights up a punctuation mark before it
#: reaches the words.
_EDGE_PUNCT = " \t\u201c\u201d\u2018\u2019\"'\u00ab\u00bb\u300c\u300d\u300e\u300f"

#: Rendering is roughly linear in characters, and a very long sentence is also
#: where a TTS model's prosody drifts. Split on a comma if one is near the
#: middle; otherwise let it run rather than cutting mid-phrase.
MAX_SEGMENT_CHARS = 320


@dataclass(frozen=True)
class Segment:
    """One utterance: what to say, in whose voice, and where it came from."""

    text: str
    #: Voice to render it in. None means the narrator.
    voice_id: str | None
    speaker: str | None
    paragraph: int
    #: Offsets into that paragraph, so a client can highlight exactly this run.
    start: int
    end: int
    is_speech: bool


@dataclass(frozen=True)
class SpeechSpan:
    paragraph: int
    start: int
    end: int
    speaker: str | None


def assign_voices(
    cast: Sequence[tuple[str, str]],
    voices: Sequence[tuple[str, str]],
    *,
    pov: str | None = None,
    narrator_voice: str | None = None,
    ceiling: int = 12,
) -> dict[str, str]:
    """Map character -> voice id, matching gender and never running out.

    ``cast`` is (name, gender) in speaking order; ``voices`` is
    (voice_id, gender) from the pack's manifest.

    A character whose gender is ``unknown`` gets NO voice and reads as the
    narrator. That is the same refusal the attribution gate makes: gender came
    from pronoun counts, "unknown" means the text did not say, and guessing
    assigns a voice that is wrong on every line that character ever speaks.

    Assignment follows speaking order so the busiest characters get voices
    first and, when the pack runs short, the ones who lose out are the ones
    heard least.

    **The POV character is deliberately given no voice of their own.** In a
    first-person book the narrator and the POV character are the same person,
    and every audiobook reads their dialogue in the narrator's voice; giving
    them a second, different voice would have one person answering themselves.

    This also has to be explicit rather than left to the gender heuristic,
    which cannot see them at all: gender comes from third-person pronouns, and
    first-person narration never uses one about its own narrator. Measured on a
    real chapter, the protagonist scored he=0 she=3 and fell to "unknown" --
    the right outcome reached by a broken route, which would stop being right
    the moment the chapter was third person.
    """
    # The narrator's voice is RESERVED. Handing it to a character makes that
    # character indistinguishable from the narration — the one thing the
    # feature exists to avoid — and it is an easy mistake because the narrator
    # is picked from the same pack. Observed on real plans: the flattest male
    # clip was chosen as narrator and then handed to Windsom and to Wren.
    pools: dict[str, list[str]] = {}
    for voice_id, gender in voices:
        if narrator_voice and voice_id == narrator_voice:
            continue
        pools.setdefault(gender, []).append(voice_id)

    pov_key = normalize_name(pov) if pov else None
    assigned: dict[str, str] = {}
    for name, gender in cast:
        if len(assigned) >= ceiling:
            break
        if pov_key and normalize_name(name) == pov_key:
            continue
        if not is_voice_candidate(name) or gender not in pools:
            continue
        pool = pools[gender]
        if not pool:
            # This gender's voices are spent. The character reads as narrator
            # rather than borrowing the other gender's.
            continue
        assigned[normalize_name(name)] = pool.pop(0)
    return assigned


def _split_sentences(text: str) -> list[str]:
    parts = _SENTENCE_END.split(text)
    # re.split with one capture group yields [body, punct, body, punct, ...].
    out: list[str] = []
    buffer = ""
    for index, piece in enumerate(parts):
        if index % 2 == 1:
            buffer += piece
            out.append(buffer)
            buffer = ""
        else:
            buffer = piece
    if buffer.strip():
        out.append(buffer)

    # An over-long sentence splits at a comma near its middle, if there is one.
    final: list[str] = []
    for sentence in out:
        while len(sentence) > MAX_SEGMENT_CHARS:
            window = sentence[MIN_SEGMENT_CHARS:MAX_SEGMENT_CHARS]
            cut = window.rfind(", ")
            if cut < 0:
                break
            cut += MIN_SEGMENT_CHARS + 1
            final.append(sentence[:cut])
            sentence = sentence[cut:].lstrip()
        final.append(sentence)

    merged: list[str] = []
    for sentence in final:
        if merged and len(sentence.strip()) < MIN_SEGMENT_CHARS:
            merged[-1] = merged[-1].rstrip() + " " + sentence.strip()
        else:
            merged.append(sentence)
    return [s for s in merged if s.strip()]


def _runs(paragraph: str, spans: Sequence[SpeechSpan]) -> list[tuple[str, int, int, str | None, bool]]:
    """Narration and speech, in order, with their offsets."""
    ordered = sorted(spans, key=lambda s: s.start)
    out: list[tuple[str, int, int, str | None, bool]] = []
    cursor = 0
    for span in ordered:
        if span.start < cursor or span.end > len(paragraph):
            continue
        if span.start > cursor:
            out.append((paragraph[cursor:span.start], cursor, span.start, None, False))
        out.append((paragraph[span.start:span.end], span.start, span.end, span.speaker, True))
        cursor = span.end
    if cursor < len(paragraph):
        out.append((paragraph[cursor:], cursor, len(paragraph), None, False))
    return out


def plan_chapter(
    paragraphs: Sequence[str],
    spans: Iterable[SpeechSpan],
    voices: dict[str, str],
) -> tuple[Segment, ...]:
    """Everything the renderer will say, in order.

    Offsets are preserved through the split, so every segment still points at
    the exact characters it came from — which is what lets the reader highlight
    the sentence being spoken rather than the paragraph containing it.
    """
    by_paragraph: dict[int, list[SpeechSpan]] = {}
    for span in spans:
        by_paragraph.setdefault(span.paragraph, []).append(span)

    out: list[Segment] = []
    for index, paragraph in enumerate(paragraphs):
        if not paragraph.strip():
            continue
        for text, start, _end, speaker, is_speech in _runs(
            paragraph, by_paragraph.get(index, ())
        ):
            if not text.strip():
                continue
            voice = voices.get(normalize_name(speaker)) if speaker else None
            offset = start
            # A run with nothing to say. Paragraphs routinely leave a bare
            # closing quote or a lone dash between spans, and rendering that
            # is a sub-second clip of silence in the middle of a sentence plus
            # a highlight that flickers over punctuation.
            if not any(ch.isalnum() for ch in text):
                continue
            for sentence in _split_sentences(text):
                # Locate each sentence back in the paragraph rather than
                # assuming the split preserved lengths: a highlight that is off
                # by the whitespace the splitter ate is a highlight on the
                # wrong words.
                # Located AFTER trimming, so start/end still bracket exactly
                # the characters that get spoken — the invariant the highlight
                # depends on.
                found = paragraph.find(sentence.strip(_EDGE_PUNCT), offset)
                if found < 0:
                    found = offset
                stripped = sentence.strip(_EDGE_PUNCT)
                if not any(ch.isalnum() for ch in stripped):
                    offset = found + len(stripped)
                    continue
                out.append(Segment(
                    text=stripped,
                    voice_id=voice,
                    speaker=speaker if voice else None,
                    paragraph=index,
                    start=found,
                    end=found + len(stripped),
                    is_speech=is_speech,
                ))
                offset = found + len(stripped)
    return tuple(out)
