"""Attribute one chapter: segment it, ask the model, store the answer.

The orchestration layer between ``novel_dialogue`` (where the spans are),
``novel_attribution`` (what the rules mean) and the four tables. Everything
expensive is guarded here, because this is the only place that spends money.

Three things never reach the API:

* a chapter whose stored attribution already matches the text's fingerprint --
  re-buying an answer we own is the single easiest way to turn a nine-cent
  feature into a bill;
* a chapter with no quoted speech at all, which is most of a slow arc;
* an em-dash chapter, where the end of a spoken line is a judgement call rather
  than arithmetic. Those are recorded as ``unattributable`` so the next pass
  skips them instead of rediscovering the same thing at a cost.

The model is injected rather than imported so every test runs without a key.
"""

from __future__ import annotations

import hashlib
import json
import logging
from typing import Callable, Sequence

from sqlalchemy import select
from sqlalchemy.orm import Session

from core.time_utils import utcnow
from database.models import (
    NovelChapterAttribution,
    NovelSeriesAlias,
    NovelSeriesCast,
    NovelSeriesCastState,
)
from services import deepseek_client
from services.novel_attribution import (
    DEFAULT_CONFIDENCE_GATE,
    SYSTEM_PROMPT,
    askable_spans,
    build_prompt,
    infer_gender,
    parse_answer,
    pronoun_counts,
)
from services.novel_dialogue import normalize_name, segment

logger = logging.getLogger(__name__)

#: Output budget, and it has to cover REASONING, which this model bills as
#: output and spends far more of than it spends on the answer.
#:
#: Measured on real chapters: an 8-span slice needed ~11k reasoning tokens and
#: a 26-span chapter ~20.5k, i.e. roughly 10k fixed plus ~0.4k per span. The
#: busiest chapter in the sample has 58 asked spans, which projects to ~33k.
#:
#: That fixed ~10k is also the argument against splitting a chapter into
#: batches: the overhead is per REQUEST, so two half-chapters cost more than
#: one whole one. Ask once, and budget for thinking.
MAX_OUTPUT_TOKENS = 48000

#: Status values. ``ok`` means the model answered; the rest are reasons nothing
#: was asked, each recorded so the next pass does not re-discover it.
STATUS_OK = "ok"
STATUS_NO_DIALOGUE = "no_dialogue"
STATUS_UNATTRIBUTABLE = "unattributable"
STATUS_FAILED = "failed"

Completer = Callable[..., deepseek_client.Completion]


def chapter_fingerprint(paragraphs: Sequence[str]) -> str:
    """Identity of the exact text the offsets were computed against.

    ``novel_chapter_cache`` is a 7-day LRU that REFETCHES, so this text will be
    replaced eventually and may come back a character different. Everything
    downstream compares this before trusting an offset.
    """
    digest = hashlib.sha256()
    for paragraph in paragraphs:
        digest.update(paragraph.encode("utf-8"))
        digest.update(b"\x00")  # so ["ab"] and ["a","b"] differ
    return digest.hexdigest()


def _resolve_speakers(segments, attributions, gate: float) -> list[dict]:
    """Attach a speaker label to every span, including the ones never asked about.

    A ``continues`` span is the tail of a quote split by an attribution clause;
    it shares the speaker of the span before it by construction, which is why it
    was never sent to the model. Inheriting here is what makes that saving free
    rather than a hole.
    """
    asked = askable_spans(segments)
    answer_for = {id(span): attributions[i] for i, span in enumerate(asked)}

    rows: list[dict] = []
    last_speaker: str | None = None
    last_rule = 7
    for span in segments.spans:
        answer = answer_for.get(id(span))
        if answer is not None:
            speaker = answer.speaker if answer.accepted(gate) else None
            rule = answer.rule
            last_speaker, last_rule = speaker, rule
        else:
            # Carried from the span it continues -- including its RULE, not a
            # fixed one. A continuation is exactly as certain as the line it
            # continues: `"Yes," he said, "go on."` is one speaker identified
            # once by an explicit tag. Stamping these with a weaker rule would
            # mean a later re-gate silently dropped the tail of every split
            # quote while keeping its head, which is worse than either
            # outcome on its own -- and re-gating without re-spending is the
            # whole reason the model returns a rule instead of a score.
            speaker, rule = last_speaker, last_rule
        rows.append(
            {
                "p": span.paragraph,
                "s": span.start,
                "e": span.end,
                "ord": span.ordinal,
                "head": span.head,
                "cont": span.continues,
                "speaker": speaker,
                "rule": rule,
            }
        )
    return rows


def series_pov(db: Session, source_id: str, series_key: str) -> str | None:
    """The series' established first-person narrator, if one is known.

    This is the highest-value thing the prompt can carry. A first-person
    narrator is usually never named inside his own chapter, so when the model
    cannot work out who he is there is nobody for his dialogue to belong to --
    and it assigns every confident line to the one other character the text
    does name. Measured on real chapters: 30 of 30 spans to the wrong speaker
    in one, 19 of 19 in another, while the chapters that did establish a
    narrator split correctly across three.
    """
    row = db.execute(
        select(NovelSeriesCast.display_name)
        .where(
            NovelSeriesCast.source_id == source_id,
            NovelSeriesCast.series_key == series_key,
            NovelSeriesCast.is_pov.is_(True),
        )
        .order_by(NovelSeriesCast.line_count.desc())
        .limit(1)
    ).scalar_one_or_none()
    return row


def record_narrator(
    db: Session, source_id: str, series_key: str, name: str
) -> NovelSeriesCast:
    """Remember who narrates this series, learned from a chapter that showed it.

    This is how the series bootstraps: the first chapter where the narrator is
    identifiable teaches every later chapter that names nobody. A locked row is
    never overwritten -- an owner correction outranks anything a model infers.
    """
    normalized = normalize_name(name)
    row = db.execute(
        select(NovelSeriesCast).where(
            NovelSeriesCast.source_id == source_id,
            NovelSeriesCast.series_key == series_key,
            NovelSeriesCast.normalized_name == normalized,
        )
    ).scalar_one_or_none()
    if row is None:
        row = NovelSeriesCast(
            source_id=source_id, series_key=series_key,
            display_name=name, normalized_name=normalized,
        )
        db.add(row)
        db.flush()
    if not row.locked:
        row.is_pov = True
        row.updated_at = utcnow()
        # Flushed because the very next thing that happens is a SELECT for the
        # series POV, and this factory does not autoflush -- an unflushed
        # is_pov reads back as "no narrator known", which is the exact state
        # this function exists to leave behind.
        db.flush()
    return row


def _known_cast(db: Session, source_id: str, series_key: str) -> tuple[str, ...]:
    rows = db.execute(
        select(NovelSeriesCast.display_name)
        .where(
            NovelSeriesCast.source_id == source_id,
            NovelSeriesCast.series_key == series_key,
        )
        .order_by(NovelSeriesCast.line_count.desc())
        .limit(30)
    ).scalars().all()
    return tuple(rows)


def _store(
    db: Session,
    *,
    source_id: str,
    series_key: str,
    chapter_key: str,
    fingerprint: str,
    paragraphs: Sequence[str],
    segments,
    spans: list[dict],
    status: str,
    served_model: str | None = None,
    pronouns: dict | None = None,
    prompt_tokens: int = 0,
    completion_tokens: int = 0,
) -> NovelChapterAttribution:
    row = db.get(
        NovelChapterAttribution, (source_id, series_key, chapter_key)
    ) or NovelChapterAttribution(
        source_id=source_id, series_key=series_key, chapter_key=chapter_key
    )
    row.text_fingerprint = fingerprint
    row.paragraph_count = len(paragraphs)
    row.style = segments.style
    row.spans = json.dumps(spans, separators=(",", ":"))
    row.pov = json.dumps([h.name for h in segments.pov]) if segments.pov else None
    row.pronoun_counts = json.dumps(pronouns) if pronouns else None
    row.status = status
    # What served it, not what was requested: the two differ whenever an id is
    # an alias, and an attribution is only auditable if it names the model that
    # actually ran.
    row.model = served_model if status == STATUS_OK else None
    row.prompt_tokens = prompt_tokens
    row.completion_tokens = completion_tokens
    row.attributed_at = utcnow()
    db.add(row)
    return row


def attribute_chapter(
    db: Session,
    source_id: str,
    series_key: str,
    chapter_key: str,
    paragraphs: Sequence[str],
    *,
    complete: Completer | None = None,
    gate: float = DEFAULT_CONFIDENCE_GATE,
    force: bool = False,
) -> NovelChapterAttribution:
    """Attribute one chapter, spending at most one API request.

    Returns the stored row either way. Never raises for a model failure: a
    chapter that cannot be attributed is narrated, which is the product's own
    baseline, and a raised exception here would take down a bulk pass over a
    series because one chapter confused a model.
    """
    fingerprint = chapter_fingerprint(paragraphs)
    existing = db.get(NovelChapterAttribution, (source_id, series_key, chapter_key))
    if existing is not None and existing.text_fingerprint == fingerprint and not force:
        # Already owned. The text has not changed, so neither has the answer.
        return existing

    segments = segment(paragraphs)

    if segments.style == "emdash":
        return _store(
            db, source_id=source_id, series_key=series_key, chapter_key=chapter_key,
            fingerprint=fingerprint, paragraphs=paragraphs, segments=segments,
            spans=[], status=STATUS_UNATTRIBUTABLE,
        )

    asked = askable_spans(segments)
    if not asked:
        return _store(
            db, source_id=source_id, series_key=series_key, chapter_key=chapter_key,
            fingerprint=fingerprint, paragraphs=paragraphs, segments=segments,
            spans=[], status=STATUS_NO_DIALOGUE,
        )

    prompt = build_prompt(
        paragraphs,
        segments,
        known_cast=_known_cast(db, source_id, series_key),
        series_pov=series_pov(db, source_id, series_key),
    )
    caller = complete or deepseek_client.complete_json

    try:
        answer = caller(
            prompt, system=SYSTEM_PROMPT, max_tokens=MAX_OUTPUT_TOKENS
        )
    except deepseek_client.DeepSeekError as exc:
        logger.warning(
            "attribution failed for %s/%s: %s", source_id, chapter_key, exc
        )
        return _store(
            db, source_id=source_id, series_key=series_key, chapter_key=chapter_key,
            fingerprint=fingerprint, paragraphs=paragraphs, segments=segments,
            spans=[], status=STATUS_FAILED,
        )

    parsed = parse_answer(answer.content, expected=len(asked))
    spans = _resolve_speakers(segments, parsed.lines, gate)

    # Learned, not assumed: whatever the model worked out about this chapter's
    # narrator is what lets the NEXT chapter be attributed when it names nobody.
    if parsed.narrator:
        record_narrator(db, source_id, series_key, parsed.narrator)

    # Pronoun evidence is gathered per speaker from the paragraphs they speak
    # in, so gender accumulates across a series rather than being decided by
    # one line. Counted here, judged later, because one chapter is rarely
    # enough evidence on its own.
    pronouns: dict[str, list[int]] = {}
    for row in spans:
        speaker = row["speaker"]
        if not speaker:
            continue
        he, she = pronoun_counts([paragraphs[row["p"]]])
        tally = pronouns.setdefault(normalize_name(speaker), [0, 0])
        tally[0] += he
        tally[1] += she

    return _store(
        db, source_id=source_id, series_key=series_key, chapter_key=chapter_key,
        fingerprint=fingerprint, paragraphs=paragraphs, segments=segments,
        spans=spans, status=STATUS_OK, pronouns=pronouns,
        served_model=answer.model or deepseek_client.MODEL,
        prompt_tokens=answer.prompt_tokens, completion_tokens=answer.completion_tokens,
    )


def resolve_voice_map(
    db: Session, source_id: str, series_key: str
) -> dict[str, str | None]:
    """label -> voice_id, for every name this series knows.

    Built at SERVE time, which is the whole reason spans store a label instead
    of a foreign key: adding "King Grey is Arthur" to the alias table changes
    what nine hundred already-stored chapters resolve to, without rewriting one
    of them.
    """
    cast = db.execute(
        select(NovelSeriesCast).where(
            NovelSeriesCast.source_id == source_id,
            NovelSeriesCast.series_key == series_key,
        )
    ).scalars().all()
    by_id = {row.id: row for row in cast}

    mapping: dict[str, str | None] = {
        row.normalized_name: row.voice_id for row in cast
    }
    aliases = db.execute(
        select(NovelSeriesAlias).where(
            NovelSeriesAlias.source_id == source_id,
            NovelSeriesAlias.series_key == series_key,
        )
    ).scalars().all()
    for alias in aliases:
        target = by_id.get(alias.cast_id)
        if target is not None:
            mapping[alias.alias_normalized] = target.voice_id
    return mapping


def bump_cast_version(db: Session, source_id: str, series_key: str) -> int:
    """Record that the cast changed, so a client can drop a cached voice map."""
    state = db.get(NovelSeriesCastState, (source_id, series_key))
    if state is None:
        state = NovelSeriesCastState(
            source_id=source_id, series_key=series_key, cast_version=0
        )
        db.add(state)
        # Flushed so the identity map holds it: without this a second bump in
        # the same transaction does not find the pending row, creates a second
        # one, and the first increment is silently lost.
        db.flush()
    state.cast_version = (state.cast_version or 0) + 1
    state.updated_at = utcnow()
    return state.cast_version
