"""Who said the line, and how much to believe it.

The load-bearing idea under test: the model returns a RULE NUMBER, and the
SERVER owns what that rule is worth. A model asked for a confidence float
produces a confident-looking number with no calibration behind it; a model asked
which rule it applied is answering a question about the text. Because the
mapping lives here, re-tuning the gate costs no API calls and rewrites no rows.
"""

from __future__ import annotations

import json

from services.novel_attribution import (
    DEFAULT_CONFIDENCE_GATE,
    RULE_CONFIDENCE,
    RULES,
    CastCandidate,
    SpanAttribution,
    askable_spans,
    build_prompt,
    infer_gender,
    parse_response,
    pronoun_counts,
    select_mains,
)
from services.novel_dialogue import segment

CHAPTER = [
    "Chapter 463",
    "ARTHUR LEYWIN",
    "Thick blades of deep green grass bent under my steps as I walked.",
    "“If only our responsibilities were proportional to our size, then I "
    "could leave all this to you, couldn’t I?” I said aloud.",
    "“My dear Arthur,” said Tessia, “you never could.”",
]


class TestRuleScale:
    def test_the_server_owns_the_confidence_not_the_model(self):
        # Every rule the model may return has a server-side number. If the
        # model could return a float, this table would not exist and re-tuning
        # would mean re-attributing every chapter ever bought.
        assert set(RULE_CONFIDENCE) == set(RULES)

    def test_confidence_never_rises_as_evidence_weakens(self):
        scores = [RULE_CONFIDENCE[r] for r in sorted(RULES)]
        assert scores == sorted(scores, reverse=True)

    def test_alternation_ships_recorded_but_ignored(self):
        # Rule 4 is right most of the time and wrong exactly where it matters:
        # a third person entering a two-hander. Below the gate, so it is bought
        # and stored; raising the gate later turns it on with no new spend.
        assert RULE_CONFIDENCE[4] < DEFAULT_CONFIDENCE_GATE
        assert SpanAttribution(0, "Arthur", 4).accepted() is False

    def test_a_tag_and_a_pov_line_are_accepted(self):
        assert SpanAttribution(0, "Tessia", 1).accepted() is True
        assert SpanAttribution(0, "Arthur", 2).accepted() is True

    def test_no_evidence_is_worth_nothing(self):
        assert SpanAttribution(0, None, 7).confidence == 0.0
        assert SpanAttribution(0, None, 7).accepted() is False

    def test_the_gate_is_switchable_without_touching_stored_answers(self):
        stored = SpanAttribution(0, "Arthur", 4)

        assert stored.accepted(gate=0.75) is False
        assert stored.accepted(gate=0.60) is True


class TestPrompt:
    def test_continuation_spans_are_never_asked_about(self):
        # A split quote's tail shares its speaker by construction. Asking is one
        # more chance to be confidently wrong, for nothing.
        segs = segment(CHAPTER)
        assert any(s.continues for s in segs.spans)

        asked = askable_spans(segs)
        assert all(not s.continues for s in asked)
        assert len(asked) < len(segs.spans)

    def test_the_pov_header_is_handed_over(self):
        # 119 of 120 sampled chapters have one, which is what makes
        # first-person dialogue resolvable without guessing.
        prompt = build_prompt(CHAPTER, segment(CHAPTER))

        assert "Arthur Leywin" in prompt
        assert "first-person" in prompt.lower() or "first person" in prompt.lower()

    def test_every_asked_span_is_numbered_in_order(self):
        segs = segment(CHAPTER)
        prompt = build_prompt(CHAPTER, segs)

        for index in range(len(askable_spans(segs))):
            assert f"[{index}]" in prompt

    def test_the_quoted_line_is_delimited_inside_its_context(self):
        prompt = build_prompt(CHAPTER, segment(CHAPTER))

        assert "<<If only our responsibilities" in prompt
        # and the speech tag that identifies it survives in the context window
        assert "said Tessia" in prompt

    def test_the_known_cast_is_offered_but_not_forced(self):
        prompt = build_prompt(CHAPTER, segment(CHAPTER), known_cast=("Sylvie",))

        assert "Sylvie" in prompt
        assert "add a new name" in prompt

    def test_it_asks_for_exactly_as_many_answers_as_it_asked_questions(self):
        segs = segment(CHAPTER)
        prompt = build_prompt(CHAPTER, segs)

        assert f"exactly {len(askable_spans(segs))} entries" in prompt


class TestParsing:
    def test_a_clean_answer_is_read(self):
        raw = json.dumps({"lines": [
            {"i": 0, "speaker": "Arthur", "rule": 2},
            {"i": 1, "speaker": "Tessia", "rule": 1},
        ]})

        out = parse_response(raw, expected=2)

        assert [(a.speaker, a.rule) for a in out] == [("Arthur", 2), ("Tessia", 1)]

    def test_a_bare_list_works_too(self):
        raw = json.dumps([{"i": 0, "speaker": "Arthur", "rule": 1}])

        assert parse_response(raw, expected=1)[0].speaker == "Arthur"

    def test_the_result_always_matches_the_span_count(self):
        # So the caller can zip it against the spans without checking lengths.
        raw = json.dumps({"lines": [{"i": 0, "speaker": "Arthur", "rule": 1}]})

        assert len(parse_response(raw, expected=5)) == 5

    def test_a_missing_entry_loses_that_line_its_voice_not_the_chapter(self):
        raw = json.dumps({"lines": [{"i": 2, "speaker": "Arthur", "rule": 1}]})

        out = parse_response(raw, expected=3)

        assert out[0].rule == 7 and out[0].speaker is None
        assert out[2].speaker == "Arthur"

    def test_unparseable_json_narrates_the_chapter_rather_than_raising(self):
        out = parse_response("not json at all", expected=3)

        assert len(out) == 3
        assert all(a.rule == 7 and a.speaker is None for a in out)

    def test_an_index_outside_the_chapter_is_dropped(self):
        raw = json.dumps({"lines": [
            {"i": 9, "speaker": "Ghost", "rule": 1},
            {"i": 0, "speaker": "Arthur", "rule": 1},
        ]})

        out = parse_response(raw, expected=1)

        assert len(out) == 1 and out[0].speaker == "Arthur"

    def test_a_repeated_index_keeps_the_first_answer(self):
        raw = json.dumps({"lines": [
            {"i": 0, "speaker": "Arthur", "rule": 1},
            {"i": 0, "speaker": "Tessia", "rule": 1},
        ]})

        assert parse_response(raw, expected=1)[0].speaker == "Arthur"

    def test_an_unknown_rule_number_is_treated_as_no_evidence(self):
        raw = json.dumps({"lines": [{"i": 0, "speaker": "Arthur", "rule": 99}]})

        assert parse_response(raw, expected=1)[0].rule == 7

    def test_rule_seven_with_a_name_attached_drops_the_name(self):
        # A model told to answer "no evidence, no speaker" sometimes answers
        # "no evidence, Unknown". The rule is authoritative.
        raw = json.dumps({"lines": [{"i": 0, "speaker": "Unknown", "rule": 7}]})

        assert parse_response(raw, expected=1)[0].speaker is None

    def test_a_blank_speaker_is_no_speaker(self):
        raw = json.dumps({"lines": [{"i": 0, "speaker": "   ", "rule": 1}]})

        out = parse_response(raw, expected=1)
        assert out[0].speaker is None and out[0].rule == 7

    def test_junk_rows_do_not_derail_the_good_ones(self):
        raw = json.dumps({"lines": [
            "nonsense",
            {"i": "x", "speaker": "Arthur", "rule": 1},
            {"i": 1, "speaker": "Tessia", "rule": 1},
        ]})

        out = parse_response(raw, expected=2)

        assert out[0].speaker is None
        assert out[1].speaker == "Tessia"


class TestGender:
    def test_a_clear_male_count(self):
        assert infer_gender(he=20, she=1) == "male"

    def test_a_clear_female_count(self):
        assert infer_gender(he=0, she=12) == "female"

    def test_too_little_evidence_is_unknown_not_a_guess(self):
        # Unknown routes to the narrator. A coin flip would be wrong in the
        # listener's ear on every line that character ever speaks.
        assert infer_gender(he=3, she=0) == "unknown"

    def test_a_mixed_count_is_unknown(self):
        # Usually two characters merged into one, or a narrator talking about
        # someone else in the same sentence.
        assert infer_gender(he=9, she=8) == "unknown"

    def test_pronouns_are_counted_as_whole_words(self):
        # "her" inside "there", "his" inside "this" -- substring counting turns
        # ordinary narration into a gender signal.
        he, she = pronoun_counts(["This is there history, this hero."])
        assert (he, she) == (0, 0)

    def test_possessive_and_reflexive_forms_count(self):
        he, she = pronoun_counts(["He hurt himself.", "His hand.", "Her turn."])
        assert he == 3 and she == 1


class TestMains:
    def test_the_pov_character_is_promoted_on_sight(self):
        # They are the "I" of the chapter and carry the most lines of anyone;
        # waiting for a threshold to notice is pure latency.
        mains = select_mains([CastCandidate("Arthur", lines=2, chapters=1, is_pov=True)])

        assert mains == ("Arthur",)

    def test_lines_alone_does_not_promote_a_single_talkative_scene(self):
        assert select_mains([CastCandidate("Innkeeper", lines=80, chapters=1)]) == ()

    def test_chapters_alone_does_not_promote_a_recurring_doorman(self):
        assert select_mains([CastCandidate("Guard", lines=6, chapters=30)]) == ()

    def test_clearing_both_bars_earns_a_voice(self):
        assert select_mains([CastCandidate("Tessia", lines=30, chapters=9)]) == ("Tessia",)

    def test_the_ceiling_holds(self):
        # Past a dozen, voices stop being distinguishable by ear.
        crowd = [CastCandidate(f"N{i}", lines=100 - i, chapters=10) for i in range(30)]

        assert len(select_mains(crowd)) == 12

    def test_the_busiest_characters_make_the_cut(self):
        crowd = [CastCandidate(f"N{i}", lines=100 - i, chapters=10) for i in range(30)]

        assert select_mains(crowd)[0] == "N0"

    def test_an_alias_does_not_take_two_of_the_twelve_slots(self):
        mains = select_mains([
            CastCandidate("Arthur", lines=90, chapters=20),
            CastCandidate("ARTHUR", lines=40, chapters=20),
        ])

        assert mains == ("Arthur",)

    def test_selection_is_deterministic(self):
        crowd = [CastCandidate(f"N{i}", lines=50, chapters=5) for i in range(20)]

        assert select_mains(crowd) == select_mains(crowd)
