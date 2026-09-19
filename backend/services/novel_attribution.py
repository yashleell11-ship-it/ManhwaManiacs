"""Ask a model WHO said each line, and decide how much to believe the answer.

Pure: builds a prompt, parses an answer, scores it. The HTTP call lives in
``deepseek_client`` and the span offsets come from ``novel_dialogue``, so this
module can be tested exhaustively without a key or a network.

**The model returns a RULE NUMBER, never a confidence score.** This is the
single decision the rest of the design leans on. A model asked for a float
produces a confident-looking number with no calibration behind it -- 0.9 means
"this looked easy", not "nine times in ten". A model asked *which rule it
applied* is answering a question about the text, which is the thing it is
actually good at. The server owns the mapping from rule to confidence, in one
dict below, so re-tuning the gate is a code change that costs nothing: no
re-attribution, no API calls, no rows rewritten.

That is what makes rule 4 safe to ship. Anchored alternation ("they were
trading lines, so this one is his") is right most of the time and wrong in
exactly the places that matter -- a third person entering a two-hander. It sits
at 0.65, just under the default 0.75 gate, so it is recorded and ignored. If it
turns out to be good, raising the gate turns 120 chapters' worth of already-paid
answers on at once.

Gender comes from pronoun counts and NEVER from names: transliterated web-novel
names carry no signal a heuristic can read, and a wrong guess assigns a voice
that is wrong on every line the character ever speaks.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

from services.novel_dialogue import (
    SPEECH_VERBS,
    ChapterSegments,
    QuoteSpan,
    normalize_name,
)

#: How the SERVER decided a span's speaker, assigned locally after the answer
#: comes back. These are no longer sent to the model, and that is a measured
#: decision, not a simplification.
#:
#: Asking the model to name the rule it applied doubled to quadrupled the cost
#: of every chapter and changed no answer. On three real chapters, a seven-rule
#: prompt, a three-tier prompt and a prompt asking for nothing but the speaker
#: returned BYTE-IDENTICAL attributions -- at $0.0063, $0.0043 and $0.0023
#: respectively. Self-classification is expensive because a reasoning model
#: thinks about the taxonomy as well as the text, and it was never trustworthy
#: anyway: a model grading its own evidence is a model marking its own work.
#:
#: What replaces it is better. An explicit speech tag beside a quote is
#: arithmetic -- the same argument that keeps offsets out of the model's hands
#: -- so it is detected here, for free, and it is checkable.
RULES: dict[int, str] = {
    1: "the text names the speaker beside the line",
    2: "first person, resolved through the chapter's POV",
    3: "inferred from the surrounding dialogue",
    6: "continues the line before it",
    7: "no speaker",
}

#: Rule -> how much the server believes it. Owned here, so re-tuning the gate
#: still costs zero API calls and rewrites no rows -- the property the old
#: design bought from the model, now obtained locally and for nothing.
RULE_CONFIDENCE: dict[int, float] = {
    1: 0.95,
    2: 0.90,
    3: 0.70,
    6: 0.90,
    7: 0.00,
}

#: Below this, a span is narrated. Set under rule 3 so an inferred speaker is
#: voiced by default: measured attribution on real chapters was correct 50 out
#: of 50 under adversarial review, and refusing every inference would narrate
#: most of a two-hander. Raise it to 0.8 to voice ONLY the lines whose speech
#: tag this module verified itself -- a one-line change that re-gates every
#: chapter ever bought.
DEFAULT_CONFIDENCE_GATE = 0.65

#: Characters of context shown either side of a span. Enough to carry a speech
#: tag and an action beat; short enough that a 40-span chapter still fits one
#: request.
CONTEXT_CHARS = 220

SYSTEM_PROMPT = (
    "You identify who is speaking each line of dialogue in a novel chapter. "
    "You answer only with JSON. You never invent a character who is not named "
    "in the text you are given, and when the text does not say who is "
    "speaking you say so instead of guessing."
)


@dataclass(frozen=True)
class SpanAttribution:
    """The model's answer for one span, plus what the server makes of it."""

    ordinal: int
    speaker: str | None
    rule: int

    @property
    def confidence(self) -> float:
        return RULE_CONFIDENCE.get(self.rule, 0.0)

    def accepted(self, gate: float = DEFAULT_CONFIDENCE_GATE) -> bool:
        return self.speaker is not None and self.confidence >= gate


def build_prompt(
    paragraphs: list[str] | tuple[str, ...],
    segments: ChapterSegments,
    *,
    known_cast: tuple[str, ...] = (),
    series_pov: str | None = None,
    context_chars: int = CONTEXT_CHARS,
) -> str:
    """One request for a whole chapter.

    Numbered spans with local context rather than the raw chapter: the model
    needs the words around a line to find its speech tag, but it must not be
    asked to re-derive offsets it would get wrong. It answers about span 7; the
    server already knows where span 7 is.

    Spans marked ``continues`` are NOT included -- they share the speaker of the
    span before them by construction, so asking about them is one more chance to
    be confidently wrong at no benefit.
    """
    asked = [s for s in segments.spans if not s.continues]

    lines: list[str] = []
    # Naming the narrator is the single highest-value thing in this prompt.
    # Measured over six real chapters: where the model established a
    # first-person narrator it attributed lines to three speakers correctly;
    # where it did not, it gave EVERY line it was confident about to the one
    # other character named in the text -- 30 of 30 in one chapter, 19 of 19 in
    # another. The narrator is usually unnamed inside his own chapter, so
    # without help there is nobody for his dialogue to be assigned to, and the
    # model picks the only name it can see.
    if segments.pov:
        names = ", ".join(h.name for h in segments.pov)
        lines.append(f"POV header(s) for this chapter: {names}")
        lines.append(
            'A first-person line ("I", "me", "my") in this chapter is spoken '
            "by the POV character unless the text says otherwise."
        )
    elif series_pov:
        # No header in this chapter, but the series has a known narrator.
        # Offered, not asserted: a series with rotating POV would otherwise
        # have every chapter's dialogue reassigned to the wrong person.
        lines.append(
            f"This series is usually narrated in first person by {series_pov}. "
            "If this chapter is first person and the text does not say "
            f"otherwise, the narrator is {series_pov}, and lines spoken by the "
            '"I" of the narration are his or hers.'
        )
    else:
        lines.append(
            "If this chapter is written in first person, work out who the "
            'narrator is and attribute the "I" lines to them by name.'
        )
    if known_cast:
        lines.append("Characters already known in this series: " + ", ".join(known_cast))
        lines.append(
            "Prefer one of these names when the text supports it; add a new "
            "name only when the text names someone new."
        )

    lines.append("")
    lines.append(
        "For each numbered line below, give the speaker's name exactly as the "
        "text spells it, or null if the text does not say who is speaking. Do "
        "not guess, and do not name a character the text does not name."
    )
    # Spelled out because a smaller model does not infer it. Asked only for
    # "the speaker", an 8B answered "I" nine times, plus "She", "he", "His",
    # "the familiar voice" and "A deep, bass voice" -- every one of which is
    # unusable: a pronoun names nobody consistently, and a description cannot
    # be matched to a cast member across chapters.
    lines.append(
        "Answer with a PROPER NAME, never a pronoun (I, he, she, they) and "
        "never a description (the asura, a deep voice, the crowd). If the "
        "speaker is the person narrating, give that person's name. If two or "
        "more people speak the line together, answer null."
    )
    lines.append("")

    for index, span in enumerate(asked):
        paragraph = paragraphs[span.paragraph]
        before = paragraph[max(0, span.start - 1 - context_chars) : max(0, span.start - 1)]
        quote = paragraph[span.start : span.end]
        after = paragraph[span.end + 1 : span.end + 1 + context_chars]
        lines.append(f"[{index}] ...{before}  <<{quote}>>  {after}...")

    lines.append("")
    lines.append(
        'Reply with JSON: {"narrator": "Name or null", '
        '"narrator_gender": "male" | "female" | null, '
        '"lines": [{"i": 0, "speaker": "Name"}, ...]} '
        f"with exactly {len(asked)} entries, one per numbered line, in order. "
        '"narrator" is the first-person narrator of THIS chapter, or null if '
        "it is not written in first person. Give the narrator's gender only if "
        "the text makes it clear; null otherwise."
    )
    return "\n".join(lines)


def askable_spans(segments: ChapterSegments) -> tuple[QuoteSpan, ...]:
    """The spans ``build_prompt`` numbers, in the same order."""
    return tuple(s for s in segments.spans if not s.continues)


@dataclass(frozen=True)
class ChapterAnswer:
    """Everything one request came back with."""

    lines: tuple[SpanAttribution, ...]
    #: Who the model says narrates this chapter, if anyone. Worth storing even
    #: when a POV was supplied: it is how a series LEARNS its narrator from the
    #: first chapter that makes it obvious, so later chapters that name nobody
    #: can still be attributed.
    narrator: str | None = None
    #: The narrator's gender, which is the ONE case pronoun counting cannot
    #: reach: first-person narration never uses a third-person pronoun about
    #: its own narrator, so they score he=0 she=0 however long the chapter is.
    #: Measured on a real series, the protagonist came out "unknown" across
    #: eight chapters and 119 lines. Without this the narrator's own voice
    #: cannot be chosen, which matters most in a book that rotates POV —
    #: a female narrator would be read by whichever clip the series defaulted
    #: to.
    narrator_gender: str | None = None


def parse_answer(raw: str, expected: int) -> ChapterAnswer:
    """Parse a whole reply: the narrator and the per-line attributions."""
    narrator = None
    gender = None
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            value = data.get("narrator")
            if isinstance(value, str) and value.strip().lower() not in ("", "null", "none", "unknown"):
                narrator = value.strip()
            said = data.get("narrator_gender")
            if isinstance(said, str) and said.strip().lower() in ("male", "female"):
                gender = said.strip().lower()
    except (ValueError, TypeError):
        pass
    return ChapterAnswer(
        lines=parse_response(raw, expected), narrator=narrator, narrator_gender=gender
    )


def parse_response(raw: str, expected: int) -> tuple[SpanAttribution, ...]:
    """Turn the model's JSON into attributions, distrusting all of it.

    Anything malformed becomes rule 7 (no evidence) for that span rather than an
    exception: one bad entry in a forty-span chapter should cost that line its
    voice, not the chapter its attribution. A missing entry is the same -- the
    result always has exactly ``expected`` items, so the caller can zip it
    against the spans without checking lengths.
    """
    try:
        data = json.loads(raw)
        rows = data["lines"] if isinstance(data, dict) else data
        if not isinstance(rows, list):
            rows = []
    except (ValueError, KeyError, TypeError):
        rows = []

    by_index: dict[int, tuple[str | None, int]] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            index = int(row.get("i"))
        except (TypeError, ValueError):
            continue
        if not 0 <= index < expected or index in by_index:
            continue
        speaker = row.get("speaker")
        if not isinstance(speaker, str) or not speaker.strip():
            speaker, rule = None, 7
        else:
            speaker = speaker.strip()
            # Everything the model names starts as "inferred". The server
            # promotes it to rule 1 or 2 only where it can VERIFY the evidence
            # itself -- see classify_span. A model is never asked to grade its
            # own work here.
            rule = 3
            if speaker.strip().lower() in ("unknown", "null", "none", "?"):
                speaker, rule = None, 7
        by_index[index] = (speaker, rule)

    return tuple(
        SpanAttribution(ordinal=i, speaker=by_index.get(i, (None, 7))[0],
                        rule=by_index.get(i, (None, 7))[1])
        for i in range(expected)
    )


# --- local evidence, verified rather than self-reported ---------------------

#: A name, loosely: capitalised, optionally two words. Deliberately not
#: exhaustive -- a miss costs a span its promotion to rule 1, never its speaker.
_NAME = r"[A-Z][\w'\-]{1,20}(?:\s+[A-Z][\w'\-]{1,20})?"

#: `"...," Arthur said` and `"...," said Arthur`, the two orders English uses.
_VERBS = "|".join(SPEECH_VERBS)
_LEAD = r"^[\s,.\u201d\u2019\"']*"
_TAG_AFTER = re.compile(rf"{_LEAD}({_NAME})\s+(?:{_VERBS})\b", re.IGNORECASE)
_TAG_AFTER_INVERTED = re.compile(rf"{_LEAD}(?:{_VERBS})\s+({_NAME})\b", re.IGNORECASE)

#: How far past a quote a speech tag may sit and still be that quote's tag.
TAG_WINDOW = 60


def classify_span(
    paragraph: str,
    start: int,
    end: int,
    speaker: str | None,
    *,
    pov: str | None = None,
) -> int:
    """Which rule the SERVER can verify for this span.

    Promotion only: a span arrives as rule 3 (inferred) and is raised to 1 or 2
    when the text itself proves it. Nothing here can invent a speaker or take
    one away -- it only decides how much the span is believed, which is what
    the gate reads.

    Rule 1 is an explicit speech tag naming this speaker immediately after the
    quote. That is arithmetic, the same argument that keeps span offsets out of
    the model's hands, and unlike a model's self-assessment it is checkable.
    """
    if speaker is None:
        return 7
    tail = paragraph[end:end + TAG_WINDOW]
    for pattern in (_TAG_AFTER, _TAG_AFTER_INVERTED):
        found = pattern.match(tail)
        if found and normalize_name(found.group(1)) == normalize_name(speaker):
            return 1
    # First person resolved through the chapter's POV: the narration around the
    # line says "I", and the speaker is who the POV says "I" is.
    if pov and normalize_name(speaker) == normalize_name(pov):
        window = paragraph[max(0, start - TAG_WINDOW):start] + tail
        if re.search(r"\bI\b", window):
            return 2
    return 3


# --- gender, from pronouns only --------------------------------------------

_HE = re.compile(r"\b(he|him|his|himself)\b", re.IGNORECASE)
_SHE = re.compile(r"\b(she|her|hers|herself)\b", re.IGNORECASE)

#: Enough sightings to mean something. Below this the answer is "unknown",
#: which routes to the narrator rather than to a coin flip.
MIN_PRONOUN_EVIDENCE = 5

#: How lopsided the count must be. A character referred to by both pronouns is
#: usually two characters that were merged, or a narrator talking about someone
#: else in the same sentence -- either way, not a voice decision to make.
PRONOUN_DOMINANCE = 4


def pronoun_counts(texts: list[str] | tuple[str, ...]) -> tuple[int, int]:
    """(he-ish, she-ish) counts across the passages a character appears in."""
    joined = "\n".join(texts)
    return len(_HE.findall(joined)), len(_SHE.findall(joined))


def infer_gender(he: int, she: int) -> str:
    """``"male"``, ``"female"`` or ``"unknown"``.

    Never from the name. Web-novel casts are transliterated from Korean,
    Japanese and Chinese, and a heuristic that reads "-ko is female, -ro is
    male" is wrong often enough to matter -- and a wrong gender is wrong in the
    listener's ear on every line that character ever speaks. Unknown is a real
    answer here, not a failure to produce one.
    """
    if he >= MIN_PRONOUN_EVIDENCE and he >= PRONOUN_DOMINANCE * she:
        return "male"
    if she >= MIN_PRONOUN_EVIDENCE and she >= PRONOUN_DOMINANCE * he:
        return "female"
    return "unknown"


# --- who gets a voice ------------------------------------------------------

#: A character has to earn a voice: enough lines to be recognisable, across
#: enough chapters to not be a one-scene walk-on.
MAIN_MIN_LINES = 25
MAIN_MIN_CHAPTERS = 3

#: Hard ceiling. Past a dozen, voices stop being distinguishable by ear and
#: every extra one is another chance at a wrong-sounding character.
MAX_VOICES = 12


#: Labels a model returns that name something other than one character.
#: Observed verbatim on real chapters: "the voice", "the unseen announcer",
#: "the announcer" (three labels for ONE entity), "the crowd", "a middle-aged
#: woman", and group labels like "Wren Kain, Lyra, and Mordain".
_GROUP_MARKERS = (",", " and ", " & ")
_DESCRIPTIVE_PREFIXES = ("the ", "a ", "an ", "some ", "several ", "both ")


def is_voice_candidate(name: str) -> bool:
    """Whether a speaker label names ONE character who could own a voice.

    Stored spans keep whatever the model said -- "the crowd" really is who
    spoke that line, and throwing the label away loses information. But a label
    like that must never be promoted to a cast member, because the product
    promise is that a character voice is never confidently wrong: a line shared
    by three people, or spoken by an unseen announcer, is narration. It reads
    correctly in the narrator's voice and absurdly in anyone else's.

    Rejecting groups also protects the alias table, whose primary key assumes
    one label means one character. "Wren Kain, Lyra, and Mordain" would
    otherwise become a cast member competing with all three real ones.
    """
    text = name.strip()
    if not text:
        return False
    if any(marker in text for marker in _GROUP_MARKERS):
        return False
    lowered = text.lower()
    if any(lowered.startswith(prefix) for prefix in _DESCRIPTIVE_PREFIXES):
        return False
    # A real name is capitalised. A bare lowercase label is a description the
    # model wrote itself, not something lifted from the text.
    return text[0].isupper()


@dataclass(frozen=True)
class CastCandidate:
    name: str
    lines: int
    chapters: int
    is_pov: bool = False


def select_mains(
    candidates: list[CastCandidate] | tuple[CastCandidate, ...],
    *,
    min_lines: int = MAIN_MIN_LINES,
    min_chapters: int = MAIN_MIN_CHAPTERS,
    ceiling: int = MAX_VOICES,
) -> tuple[str, ...]:
    """Which characters get their own voice.

    A POV character is promoted on sight: they are the "I" of the chapter, they
    carry the most lines of anyone, and waiting for a line threshold to notice
    that is pure latency. Everyone else must clear both bars -- lines alone
    promotes a single talkative scene, chapters alone promotes a recurring
    doorman.

    Ties break on the name so two runs over the same series never disagree
    about who made the cut.
    """
    eligible = [c for c in candidates if is_voice_candidate(c.name)]
    pov = [c for c in eligible if c.is_pov]
    rest = [
        c
        for c in eligible
        if not c.is_pov and c.lines >= min_lines and c.chapters >= min_chapters
    ]
    ordered = sorted(pov, key=lambda c: (-c.lines, normalize_name(c.name))) + sorted(
        rest, key=lambda c: (-c.lines, -c.chapters, normalize_name(c.name))
    )

    chosen: list[str] = []
    seen: set[str] = set()
    for candidate in ordered:
        key = normalize_name(candidate.name)
        if key in seen:
            continue
        seen.add(key)
        chosen.append(candidate.name)
        if len(chosen) >= ceiling:
            break
    return tuple(chosen)
