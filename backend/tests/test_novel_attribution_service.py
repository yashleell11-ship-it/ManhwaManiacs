"""Attributing a chapter: what it stores, and what it refuses to pay for.

This is the only module in the project that spends money, so most of these
tests are about NOT calling the API. The model is injected, so nothing here
needs a key or a network.
"""

from __future__ import annotations

import json

import pytest
from database.models import NovelSeriesAlias, NovelSeriesCast
from services import deepseek_client
from services import novel_attribution_service as svc

SOURCE, SERIES, CHAPTER = "novelarchive", "tbate", "ch-463"

QUOTED = [
    "ARTHUR LEYWIN",
    "The grass bent under my steps.",
    "“If only our responsibilities were proportional to our size?” I said aloud.",
    "“My dear Arthur,” said Tessia, “you never could.”",
]

NARRATION = ["He walked into the room.", "The sky was grey.", "Nothing moved."]

EMDASH = [
    "—I told you already.",
    "—And I told you I did not care.",
    "—Then we are finished.",
]


class _Spy:
    """A stand-in model that records whether it was asked anything."""

    def __init__(self, content='{"lines": []}', raises=None):
        self.content = content
        self.raises = raises
        self.calls: list[str] = []

    def __call__(self, prompt, **kwargs):
        self.calls.append(prompt)
        if self.raises:
            raise self.raises
        return deepseek_client.Completion(
            content=self.content, prompt_tokens=6400, completion_tokens=900
        )


def _answer(*pairs):
    return json.dumps(
        {"lines": [{"i": i, "speaker": s, "rule": r} for i, (s, r) in enumerate(pairs)]}
    )


class TestSpendingNothing:
    def test_a_chapter_with_no_dialogue_is_never_sent(self, db_session):
        # Most of a slow arc. Sending it buys a list of zero answers.
        spy = _Spy()

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, NARRATION, complete=spy
        )

        assert spy.calls == []
        assert row.status == svc.STATUS_NO_DIALOGUE

    def test_an_emdash_chapter_is_recorded_not_retried(self, db_session):
        # The end of an em-dash line is a judgement call, not arithmetic.
        # Recording it means the next pass skips it instead of rediscovering
        # the same thing at a cost.
        spy = _Spy()

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, EMDASH, complete=spy
        )

        assert spy.calls == []
        assert row.status == svc.STATUS_UNATTRIBUTABLE

    def test_an_answer_we_already_own_is_not_re_bought(self, db_session):
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))
        svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )
        db_session.flush()
        assert len(spy.calls) == 1

        svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        assert len(spy.calls) == 1, "re-bought an answer we already owned"

    def test_changed_text_IS_re_bought(self, db_session):
        # The chapter cache is a 7-day LRU that refetches; when the text really
        # changes, the old offsets describe nothing.
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))
        svc.attribute_chapter(db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy)
        db_session.flush()

        changed = list(QUOTED) + ["“One more thing,” said Tessia."]
        svc.attribute_chapter(db_session, SOURCE, SERIES, CHAPTER, changed, complete=spy)

        assert len(spy.calls) == 2

    def test_the_fingerprint_distinguishes_a_split_paragraph(self):
        # Without a separator, ["ab"] and ["a","b"] hash identically -- and
        # they have completely different offsets.
        assert svc.chapter_fingerprint(["ab"]) != svc.chapter_fingerprint(["a", "b"])


class TestStoring:
    def test_accepted_answers_become_spans_with_speakers(self, db_session):
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        spans = json.loads(row.spans)
        assert row.status == svc.STATUS_OK
        assert [s["speaker"] for s in spans][:2] == ["Arthur", "Tessia"]

    def test_a_continuation_inherits_rather_than_being_asked(self, db_session):
        # "...," said Tessia, "..." is two spans and one speaker. The tail was
        # never sent, so inheriting here is what makes that saving free.
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        spans = json.loads(row.spans)
        tail = [s for s in spans if s["cont"]]
        assert tail, "fixture no longer contains a split quote"
        assert tail[0]["speaker"] == "Tessia"

    def test_a_below_gate_answer_stores_no_speaker(self, db_session):
        # Rule 4 is alternation: recorded, and ignored until the gate moves.
        spy = _Spy(_answer(("Arthur", 4), ("Tessia", 4)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        spans = json.loads(row.spans)
        assert all(s["speaker"] is None for s in spans)
        # but the rule survives, so lowering the gate later costs nothing
        assert {s["rule"] for s in spans if not s["cont"]} == {4}

    def test_the_pov_header_is_stored(self, db_session):
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        assert json.loads(row.pov) == ["Arthur Leywin"]

    def test_token_usage_is_recorded(self, db_session):
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        assert row.prompt_tokens == 6400 and row.completion_tokens == 900

    def test_pronoun_evidence_is_gathered_per_speaker(self, db_session):
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        # Counted now, judged later: one chapter is rarely enough evidence, so
        # gender accumulates across the series instead.
        assert row.pronoun_counts is not None
        assert "arthur" in json.loads(row.pronoun_counts)


class TestFailure:
    def test_a_model_failure_narrates_the_chapter_instead_of_raising(self, db_session):
        # A raised exception here would take down a bulk pass over a series
        # because one chapter confused a model.
        spy = _Spy(raises=deepseek_client.DeepSeekError("boom"))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        assert row.status == svc.STATUS_FAILED
        assert json.loads(row.spans) == []

    def test_a_budget_refusal_is_not_a_crash(self, db_session):
        spy = _Spy(raises=deepseek_client.DeepSeekBudgetExhausted("ceiling"))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        assert row.status == svc.STATUS_FAILED


class TestServeTimeResolution:
    def _cast(self, db, name, voice, gender="male"):
        row = NovelSeriesCast(
            source_id=SOURCE, series_key=SERIES, display_name=name,
            normalized_name=name.casefold(), gender=gender, voice_id=voice,
        )
        db.add(row)
        db.flush()
        return row

    def test_a_name_resolves_to_its_voice(self, db_session):
        self._cast(db_session, "arthur", "voice-m1")

        assert svc.resolve_voice_map(db_session, SOURCE, SERIES)["arthur"] == "voice-m1"

    def test_an_alias_resolves_to_the_same_voice(self, db_session):
        cast = self._cast(db_session, "arthur", "voice-m1")
        db_session.add(NovelSeriesAlias(
            source_id=SOURCE, series_key=SERIES, alias_normalized="king grey",
            alias_display="King Grey", cast_id=cast.id,
        ))
        db_session.flush()

        mapping = svc.resolve_voice_map(db_session, SOURCE, SERIES)

        # One INSERT corrects every chapter at once, because spans store a
        # label and resolve through here at serve time.
        assert mapping["king grey"] == mapping["arthur"] == "voice-m1"

    def test_the_database_refuses_an_ambiguous_alias(self, db_session):
        from sqlalchemy.exc import IntegrityError

        a = self._cast(db_session, "arthur", "voice-m1")
        b = self._cast(db_session, "nico", "voice-m2")
        db_session.add(NovelSeriesAlias(
            source_id=SOURCE, series_key=SERIES, alias_normalized="grey",
            alias_display="Grey", cast_id=a.id,
        ))
        db_session.flush()

        # The alias is part of the primary key, so a name that would split one
        # character's voice in two is a write-time error, not a silent
        # mis-cast.
        db_session.add(NovelSeriesAlias(
            source_id=SOURCE, series_key=SERIES, alias_normalized="grey",
            alias_display="Grey", cast_id=b.id,
        ))
        with pytest.raises(IntegrityError):
            db_session.flush()

    def test_the_cast_version_bumps(self, db_session):
        first = svc.bump_cast_version(db_session, SOURCE, SERIES)
        second = svc.bump_cast_version(db_session, SOURCE, SERIES)

        assert (first, second) == (1, 2)
