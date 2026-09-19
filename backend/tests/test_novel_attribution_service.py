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

    def __init__(self, content='{"lines": []}', raises=None, model="deepseek-flash"):
        self.content = content
        self.raises = raises
        self.model = model
        self.calls: list[str] = []

    def __call__(self, prompt, **kwargs):
        self.calls.append(prompt)
        if self.raises:
            raise self.raises
        return deepseek_client.Completion(
            content=self.content, prompt_tokens=6400, completion_tokens=900,
            model=self.model,
        )


def _answer(*pairs):
    # The model is no longer asked for a rule; the second element is ignored
    # and kept only so existing cases read the same.
    return json.dumps(
        {"lines": [{"i": i, "speaker": s} for i, (s, _r) in enumerate(pairs)]}
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

    def test_a_continuation_inherits_its_parents_certainty_too(self, db_session):
        # `"Yes," he said, "go on."` is ONE speaker, identified once by an
        # explicit tag. If the tail were stamped with a weaker rule, a later
        # re-gate would keep the head and drop the tail of every split quote --
        # and re-gating without re-spending is the whole point of returning a
        # rule rather than a score.
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        spans = json.loads(row.spans)
        tail = [s for s in spans if s["cont"]]
        assert tail, "fixture no longer contains a split quote"
        head = [s for s in spans if not s["cont"] and s["speaker"] == tail[0]["speaker"]]
        assert head and tail[0]["rule"] == head[-1]["rule"]

    def test_a_strict_gate_keeps_only_what_the_server_verified(self, db_session):
        # At 0.8, an inferred speaker is narrated and only a locally-verified
        # speech tag is voiced. Nothing is re-bought to change this.
        spy = _Spy(_answer(("Arthur", 0), ("Tessia", 0)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy, gate=0.8
        )

        spans = json.loads(row.spans)
        voiced = [s for s in spans if s["speaker"]]
        # "said Tessia" is in the fixture, so that one survives; the
        # first-person line has no tag naming Arthur.
        assert all(s["rule"] in (1, 2, 6) for s in voiced)

    def test_the_pov_header_is_stored(self, db_session):
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)))

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        assert json.loads(row.pov) == ["Arthur Leywin"]

    def test_the_model_that_actually_ran_is_recorded(self, db_session):
        # Not the one that was requested: the ids are aliased, so storing the
        # request would name a model that never touched the chapter.
        spy = _Spy(_answer(("Arthur", 2), ("Tessia", 1)), model="deepseek-v4-pro")

        row = svc.attribute_chapter(
            db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy
        )

        assert row.model == "deepseek-v4-pro"

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


class TestNarratorLearning:
    """How a series works out who narrates it, and why that matters most.

    A first-person narrator is almost never named inside his own chapter. With
    no POV established the model has nobody to assign his dialogue to, so it
    gives every confident line to the one other character the text does name.
    Measured on real chapters: 30 of 30 spans to the wrong speaker in one, 19
    of 19 in another, while chapters that did establish a narrator split
    correctly across three speakers.
    """

    def test_a_reported_narrator_becomes_the_series_pov(self, db_session):
        spy = _Spy(json.dumps({
            "narrator": "Arthur Leywin",
            "lines": [{"i": 0, "speaker": "Tessia", "rule": 1},
                      {"i": 1, "speaker": "Tessia", "rule": 1}],
        }))

        svc.attribute_chapter(db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy)

        assert svc.series_pov(db_session, SOURCE, SERIES) == "Arthur Leywin"

    def test_a_learned_pov_is_handed_to_the_next_chapter(self, db_session):
        # The whole point: chapter N teaches chapter N+1, which names nobody.
        svc.record_narrator(db_session, SOURCE, SERIES, "Arthur Leywin")
        db_session.flush()
        spy = _Spy(_answer(("Tessia", 1)))

        svc.attribute_chapter(db_session, SOURCE, SERIES, "ch-999", QUOTED, complete=spy)

        assert "Arthur Leywin" in spy.calls[0]

    def test_no_narrator_reported_leaves_the_series_unchanged(self, db_session):
        spy = _Spy(json.dumps({"narrator": None, "lines": []}))

        svc.attribute_chapter(db_session, SOURCE, SERIES, CHAPTER, QUOTED, complete=spy)

        assert svc.series_pov(db_session, SOURCE, SERIES) is None

    def test_an_owner_correction_outranks_what_the_model_infers(self, db_session):
        from database.models import NovelSeriesCast

        locked = NovelSeriesCast(
            source_id=SOURCE, series_key=SERIES, display_name="Grey",
            normalized_name="grey", is_pov=True, locked=True,
        )
        db_session.add(locked)
        db_session.flush()

        svc.record_narrator(db_session, SOURCE, SERIES, "Grey")

        # Still POV, and the locked row was not rewritten by an inference.
        assert locked.is_pov is True and locked.locked is True

    def test_learning_the_narrator_twice_does_not_split_the_cast(self, db_session):
        from sqlalchemy import select
        from database.models import NovelSeriesCast

        svc.record_narrator(db_session, SOURCE, SERIES, "Arthur Leywin")
        svc.record_narrator(db_session, SOURCE, SERIES, "ARTHUR LEYWIN")
        db_session.flush()

        rows = db_session.execute(
            select(NovelSeriesCast).where(NovelSeriesCast.series_key == SERIES)
        ).scalars().all()
        assert len(rows) == 1


class TestSeriesCast:
    """Gender is decided once per SERIES, never per chapter.

    Per chapter it is simply wrong. The evidence threshold exists because a
    handful of pronouns is noise, but one chapter rarely clears it: measured on
    real chapters, a character with she=21 in one came out "unknown" in another
    on she=4 and lost her voice for that chapter alone. A character whose voice
    changes between chapters is a worse artefact than one who never had a
    distinct voice.
    """

    def _chapter(self, db, key, spans, pronouns):
        from database.models import NovelChapterAttribution

        db.add(NovelChapterAttribution(
            source_id=SOURCE, series_key=SERIES, chapter_key=key,
            text_fingerprint=key, paragraph_count=5, style="quoted",
            spans=json.dumps(spans), pronoun_counts=json.dumps(pronouns),
            status=svc.STATUS_OK, model="qwen3:14b",
        ))
        db.flush()

    def _span(self, speaker):
        return {"p": 0, "s": 0, "e": 5, "ord": 0, "head": "x",
                "cont": False, "speaker": speaker, "rule": 1}

    def test_evidence_too_thin_in_one_chapter_adds_up_across_several(self, db_session):
        # she=4 three times is nowhere near the bar alone, and decisive summed.
        for i in range(3):
            self._chapter(db_session, f"c{i}", [self._span("Myre")], {"myre": [0, 4]})

        cast = svc.build_series_cast(db_session, SOURCE, SERIES)

        assert [(c.display_name, c.gender) for c in cast] == [("Myre", "female")]

    def test_genuinely_thin_evidence_still_says_unknown(self, db_session):
        # Summing must not become "eventually guess". Unknown routes to the
        # narrator, which is a real answer.
        self._chapter(db_session, "c0", [self._span("Ghost")], {"ghost": [1, 1]})

        cast = svc.build_series_cast(db_session, SOURCE, SERIES)

        assert cast[0].gender == "unknown"

    def test_lines_and_chapters_accumulate(self, db_session):
        self._chapter(db_session, "c0", [self._span("Myre"), self._span("Myre")], {})
        self._chapter(db_session, "c1", [self._span("Myre")], {})

        cast = svc.build_series_cast(db_session, SOURCE, SERIES)

        assert (cast[0].line_count, cast[0].chapter_count) == (3, 2)

    def test_a_rank_does_not_split_a_character_in_two(self):
        # What normalisation DOES merge: "Lance Mica" and "Mica" are one row,
        # because a rank in front of a name is not a different person.
        from services.novel_dialogue import normalize_name

        assert normalize_name("Lance Mica") == normalize_name("Mica")

    def test_a_bare_first_name_is_NOT_merged_automatically(self, db_session):
        # "Wren" and "Wren Kain" really are one character here, and they still
        # get two rows. That is deliberate. Merging on a shared first name
        # would fuse two characters who happen to share one, and a merged
        # wrong character is confidently wrong on every line it speaks, while
        # a split one is merely bland. The alias table exists to join these on
        # purpose — one INSERT, applied at serve time to every chapter at once.
        self._chapter(db_session, "c0", [self._span("Wren")], {})
        self._chapter(db_session, "c1", [self._span("Wren Kain")], {})

        cast = svc.build_series_cast(db_session, SOURCE, SERIES)

        assert sorted(c.display_name for c in cast) == ["Wren", "Wren Kain"]

    def test_the_fuller_spelling_wins_when_they_DO_normalise_together(self, db_session):
        # "Mica" reads worse in a cast list than "Lance Mica", and both
        # normalise to the same key.
        self._chapter(db_session, "c0", [self._span("Mica")], {})
        self._chapter(db_session, "c1", [self._span("Lance Mica")], {})

        cast = svc.build_series_cast(db_session, SOURCE, SERIES)

        assert len(cast) == 1 and cast[0].display_name == "Lance Mica"

    def test_a_failed_chapter_contributes_nothing(self, db_session):
        from database.models import NovelChapterAttribution

        db_session.add(NovelChapterAttribution(
            source_id=SOURCE, series_key=SERIES, chapter_key="bad",
            text_fingerprint="bad", paragraph_count=1, style="quoted",
            spans=json.dumps([self._span("Phantom")]), status=svc.STATUS_FAILED,
        ))
        db_session.flush()

        assert svc.build_series_cast(db_session, SOURCE, SERIES) == []

    def test_an_owner_correction_is_never_overwritten(self, db_session):
        from database.models import NovelSeriesCast

        locked = NovelSeriesCast(
            source_id=SOURCE, series_key=SERIES, display_name="Myre",
            normalized_name="myre", gender="male", locked=True,
        )
        db_session.add(locked)
        db_session.flush()
        self._chapter(db_session, "c0", [self._span("Myre")], {"myre": [0, 40]})

        cast = svc.build_series_cast(db_session, SOURCE, SERIES)

        # Counts refresh so a recast can still tell who is a main; the human
        # decision stands.
        assert cast[0].gender == "male" and cast[0].line_count == 1

    def test_the_busiest_character_sorts_first(self, db_session):
        self._chapter(db_session, "c0",
                      [self._span("Quiet"), self._span("Busy"), self._span("Busy")], {})

        assert svc.build_series_cast(db_session, SOURCE, SERIES)[0].display_name == "Busy"

    def test_a_corrupt_pronoun_blob_does_not_lose_the_chapter(self, db_session):
        from database.models import NovelChapterAttribution

        db_session.add(NovelChapterAttribution(
            source_id=SOURCE, series_key=SERIES, chapter_key="c0",
            text_fingerprint="c0", paragraph_count=1, style="quoted",
            spans=json.dumps([self._span("Myre")]), pronoun_counts="{not json",
            status=svc.STATUS_OK,
        ))
        db_session.flush()

        cast = svc.build_series_cast(db_session, SOURCE, SERIES)

        assert len(cast) == 1 and cast[0].gender == "unknown"
