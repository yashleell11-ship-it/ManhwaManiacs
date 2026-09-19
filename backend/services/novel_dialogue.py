"""Split a novel chapter's paragraphs into narration and quoted speech.

Pure and dependency-free, deliberately: it is the shape of
``connectors/novel_text.py`` (which it must NOT live beside -- that directory is
owned elsewhere), and it is the piece a language model must never be asked to
do. The model answers *who* said a line; the offsets and the numbering are
arithmetic, and arithmetic is not something to buy from an LLM that cannot count
characters.

Everything downstream keys on ``(paragraph_index, start, end)`` into the exact
strings ``novel_chapter_cache.paragraphs`` holds, so this module defines the
coordinate system the audio timing map and the reader highlight both use.

Measured on 120 of the owner's real chapters: 4,626 quoted spans, of which only
19% carry a speech verb in the same paragraph. The other 80% is what the
attribution pass exists for -- but it can only run on spans this module found,
so a span missed here is a line read by the narrator forever.

The bias throughout is toward MISSING a span rather than inventing one. A missed
line is narrated, which is the product's own baseline; an invented span gets a
character voice attached to something that was never speech.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

#: Quote pairs seen across the eight live novel sources. Straight quotes are
#: last because they are ambiguous -- the same character opens and closes -- and
#: the paired forms should win when a paragraph mixes them.
_QUOTE_PAIRS: tuple[tuple[str, str], ...] = (
    ("“", "”"),  # curly, the web-novel default
    ("«", "»"),  # guillemets, translations
    ("「", "」"),  # corner brackets, JP/KR sources
    ("『", "』"),  # white corner brackets, quote-within-quote
    ('"', '"'),  # straight, ambiguous
)

_OPENERS = {pair[0] for pair in _QUOTE_PAIRS}
_CLOSER_FOR = {pair[0]: pair[1] for pair in _QUOTE_PAIRS}

#: Verbs that mark an attribution clause. Only used to protect a short quote
#: from the scare-quote filter -- attribution itself is the model's job.
#: Shared with ``novel_attribution``, which builds its own speech-tag patterns
#: from the same list -- two copies of this would drift, and a verb present in
#: one and missing from the other silently changes which spans get believed.
SPEECH_VERBS: tuple[str, ...] = (
    "said", "says", "asked", "asks", "replied", "replies", "answered",
    "shouted", "yelled", "whispered", "murmured", "muttered", "growled",
    "snapped", "sighed", "laughed", "called", "continued", "added",
    "repeated", "began", "interrupted", "cried", "breathed", "demanded",
    "offered", "observed", "remarked", "told", "spoke",
)

_SPEECH_VERB_RE = re.compile(
    r"\b(" + "|".join(SPEECH_VERBS) + r")\b", re.IGNORECASE
)

#: A quoted fragment this short, with no terminal punctuation and no speech verb
#: nearby, is almost always emphasis rather than speech. A Christmas Carol has
#: `They often "came down" handsomely` in the same paragraph as real dialogue,
#: so this is not hypothetical.
_SCARE_QUOTE_MAX_WORDS = 3

_TERMINAL_PUNCT = frozenset(".!?…。！？")

#: Punctuation that genuinely argues a short quote is SPEECH. A full stop is
#: deliberately absent: English convention puts the sentence's period inside
#: the closing quote even when the quoted words are not speech at all, so
#: `us "lesser races."` ends in terminal punctuation while being pure
#: narration. Treating a period as proof of speech let exactly that phrase
#: through as a spoken line in a real chapter -- and a scare-quoted phrase
#: echoing another character is how the narrator's voice switches mid-sentence
#: in the middle of an audiobook. A question or exclamation mark carries no
#: such convention: nothing puts those inside quotes by typographic habit.
_SPEECH_PUNCT = frozenset("!?…。！？")

#: A POV header names whose "I" the following narration is. 119 of the owner's
#: 120 sampled chapters have exactly one, which makes first-person dialogue --
#: a large share of web fiction -- resolvable for free.
_POV_MAX_WORDS = 5


@dataclass(frozen=True)
class QuoteSpan:
    """One stretch of quoted speech, located in the paragraph array."""

    paragraph: int
    ordinal: int
    start: int
    end: int
    head: str
    #: True when this span is the tail of a quote split by an attribution
    #: clause (`"Yes," he said, "go on."`). It shares its speaker with the span
    #: before it, so the model is never asked about it.
    continues: bool = False

    @property
    def text(self) -> str:  # pragma: no cover - convenience for callers
        raise NotImplementedError("callers slice the paragraph themselves")


@dataclass(frozen=True)
class PovHeader:
    """A paragraph that names the point-of-view character for what follows."""

    paragraph: int
    name: str


@dataclass(frozen=True)
class ChapterSegments:
    style: str
    spans: tuple[QuoteSpan, ...]
    pov: tuple[PovHeader, ...]


#: How many characters of a span to record so a client can prove the audio and
#: the text still line up. Long enough to be distinctive, short enough that a
#: thousand of them stay small.
HEAD_CHARS = 14


def detect_style(paragraphs: list[str] | tuple[str, ...]) -> str:
    """``"quoted"``, ``"emdash"`` or ``"none"`` -- how this source marks speech.

    Counted as evidence rather than decided on the first match: a chapter can
    contain a stray em-dash in quoted prose and a stray quote in em-dash prose.

    ``"emdash"`` is detected so it can be *skipped*, not handled. Em-dash
    dialogue has no closing delimiter, so the end of a line is a judgement call
    rather than arithmetic -- exactly the thing this module refuses to guess at.
    Those chapters serve as narrator until someone decides the feature is worth
    the ambiguity.
    """
    quoted = 0
    emdash = 0
    for paragraph in paragraphs:
        stripped = paragraph.lstrip()
        if any(stripped.startswith(opener) for opener in _OPENERS):
            quoted += 1
        elif stripped.startswith(("—", "–", "--")):
            emdash += 1
        else:
            for opener in _OPENERS:
                if opener in paragraph:
                    quoted += 1
                    break
    # ONE paired quote is enough. The threshold belongs on em-dash detection,
    # where a stray dash in ordinary prose is a false positive -- a paired
    # opening quote is not ambiguous that way. An earlier version wanted three
    # quoted paragraphs and therefore returned "none" for a short chapter, or
    # one with only a line or two of dialogue, silently yielding no spans at
    # all. The scare-quote filter is what protects narration that merely
    # contains an emphasised phrase; style detection is the wrong place for it.
    if quoted and quoted >= emdash:
        return "quoted"
    if emdash >= 3:
        return "emdash"
    return "none"


def find_pov_headers(paragraphs: list[str] | tuple[str, ...]) -> tuple[PovHeader, ...]:
    """Paragraphs that are a bare name in capitals, naming the POV character.

    Deliberately strict. A shouted line ("NO!") is short and uppercase too, so a
    header must also carry no terminal punctuation and at least one letter --
    and a chapter heading like "CHAPTER 12" is rejected because it has no
    alphabetic word that is not a numeral.
    """
    headers: list[PovHeader] = []
    for index, paragraph in enumerate(paragraphs):
        text = paragraph.strip()
        if not text or len(text) > 48:
            continue
        if text[-1] in _TERMINAL_PUNCT:
            continue
        words = text.split()
        if not (1 <= len(words) <= _POV_MAX_WORDS):
            continue
        letters = [ch for ch in text if ch.isalpha()]
        if not letters or any(ch.islower() for ch in letters):
            continue
        # "CHAPTER 12" / "PART ONE" are structure, not a speaker.
        if re.fullmatch(r"(CHAPTER|PART|BOOK|VOLUME|ARC|EPILOGUE|PROLOGUE)\b.*", text):
            continue
        headers.append(PovHeader(paragraph=index, name=text.title()))
    return tuple(headers)


def _is_scare_quote(inner: str, paragraph: str, start: int, end: int) -> bool:
    """Whether a quoted fragment is emphasis rather than speech."""
    words = inner.split()
    if len(words) > _SCARE_QUOTE_MAX_WORDS:
        return False
    if inner and inner.rstrip()[-1:] in _SPEECH_PUNCT:
        return False
    # An attribution clause immediately around it makes even a two-word quote
    # real speech ("Go," he said).
    window = paragraph[max(0, start - 40) : min(len(paragraph), end + 40)]
    if _SPEECH_VERB_RE.search(window):
        return False
    # Mid-sentence with a lowercase letter right before it reads as emphasis.
    # `start` points INSIDE the quotation, so the opening mark itself sits at
    # the end of this slice and has to come off -- otherwise the last character
    # examined is always the quote, never a letter, and this test can only ever
    # answer False.
    before = paragraph[:start].rstrip()
    while before and before[-1] in _OPENERS:
        before = before[:-1].rstrip()
    return bool(before) and before[-1].isalpha() and before[-1].islower()


def segment(paragraphs: list[str] | tuple[str, ...]) -> ChapterSegments:
    """Locate every quoted span in a chapter.

    Open-quote state is carried ACROSS paragraphs, which is the difference
    between working on classic prose and producing garbage on it: Standard
    Ebooks and Gutenberg routinely open a quotation in one paragraph and leave
    it open for two more, because a continuing speech gets an opening mark per
    paragraph and a closing mark only at the very end. A per-paragraph regex
    silently pairs the wrong delimiters there.
    """
    style = detect_style(paragraphs)
    pov = find_pov_headers(paragraphs)
    if style != "quoted":
        return ChapterSegments(style=style, spans=(), pov=pov)

    spans: list[QuoteSpan] = []
    # The opener we are inside of, if a paragraph ended mid-quotation.
    pending: str | None = None

    for index, paragraph in enumerate(paragraphs):
        ordinal = 0
        cursor = 0
        # A paragraph that continues an unclosed quotation starts inside it.
        opener = pending
        carried = pending is not None
        open_at = None
        if opener is not None:
            # ...but the convention re-opens the quotation at the head of every
            # continuing paragraph and closes it only at the very end. That
            # repeated mark is punctuation, not speech: step past it, or every
            # continuation span carries a stray quote at offset 0. Starting the
            # cursor there matters for straight quotes especially, where the
            # opener and the closer are the same character and re-reading it
            # would close the quotation immediately.
            lead = len(paragraph) - len(paragraph.lstrip())
            open_at = lead + 1 if paragraph[lead : lead + 1] == opener else 0
            cursor = open_at
        pending = None

        while cursor < len(paragraph):
            char = paragraph[cursor]
            if opener is None:
                if char in _OPENERS:
                    opener = char
                    open_at = cursor + 1
                cursor += 1
                continue

            if char == _CLOSER_FOR[opener]:
                inner = paragraph[open_at:cursor]
                if inner.strip() and not _is_scare_quote(
                    inner, paragraph, open_at, cursor
                ):
                    spans.append(
                        QuoteSpan(
                            paragraph=index,
                            ordinal=ordinal,
                            start=open_at,
                            end=cursor,
                            head=inner[:HEAD_CHARS],
                            # A second span in one paragraph (after an
                            # attribution clause) shares the first one's
                            # speaker, and so does the first span of a
                            # paragraph that continues an open quotation.
                            continues=ordinal > 0 or carried,
                        )
                    )
                    ordinal += 1
                opener = None
                open_at = None
            cursor += 1

        if opener is not None:
            # Unclosed at the paragraph end. Emit what we have and stay inside
            # the quotation for the next paragraph.
            inner = paragraph[open_at:]
            if inner.strip():
                spans.append(
                    QuoteSpan(
                        paragraph=index,
                        ordinal=ordinal,
                        start=open_at,
                        end=len(paragraph),
                        head=inner[:HEAD_CHARS],
                        continues=ordinal > 0 or carried,
                    )
                )
            pending = opener

    return ChapterSegments(style=style, spans=tuple(spans), pov=pov)


# --- name normalisation, shared by both sides of alias resolution -----------

_HONORIFICS = frozenset(
    {
        "mr", "mrs", "miss", "ms", "dr", "sir", "lady", "lord", "king", "queen",
        "prince", "princess", "master", "elder", "senior", "captain", "general",
        "professor", "father", "mother", "uncle", "aunt", "saint", "st",
        # Familial address and in-world ranks, both observed on real chapters
        # as the difference between two models naming the SAME character:
        # "Virion" vs "Grandpa Virion", "Mica" vs "Lance Mica". Without these
        # the alias table would hold two rows for one person, and the twelve
        # voice slots would be spent twice on them.
        "grandpa", "grandfather", "grandma", "grandmother", "granddad",
        "lance", "scythe", "sovereign", "highlord", "commander", "councilor",
        "councillor", "director", "headmaster", "instructor", "duke",
        "duchess", "earl", "count", "countess", "baron", "baroness",
    }
)

_SUFFIXES = ("-sama", "-san", "-kun", "-chan", "-nim", "-ssi", "-dono", "-senpai")


def normalize_name(raw: str) -> str:
    """Canonical form of a character name, for alias matching.

    One function so the two places that compare names -- the cast digest sent to
    the model, and the merge of a name it proposes -- can never disagree about
    what counts as the same name.
    """
    text = unicodedata.normalize("NFKC", raw).strip()
    text = re.sub(r"[’']s\b", "", text)  # possessive
    for suffix in _SUFFIXES:
        if text.lower().endswith(suffix):
            text = text[: -len(suffix)]
    text = re.sub(r"^(the)\s+", "", text, flags=re.IGNORECASE)
    words = [w for w in re.split(r"\s+", text) if w]
    # Never strip a name away entirely. "The Lance" IS what a character is
    # called; stripping its only word leaves an empty key that every other
    # title-only name would collide with, merging unrelated characters into
    # one voice.
    while len(words) > 1 and words[0].strip(".").lower() in _HONORIFICS:
        words.pop(0)
    return " ".join(words).casefold().strip()
