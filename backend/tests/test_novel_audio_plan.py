"""What the renderer will say, in whose voice, and where it came from.

Pure, and deliberately the whole of the decision-making: a render is minutes of
contended GPU and a plan is microseconds, so every mistake is cheaper to find
here. Offsets are derived from the text, never hand-counted — a miscounted
fixture tests the fixture, and these are the offsets the segmenter produces.
"""

from __future__ import annotations

from services.novel_audio_plan import (
    MIN_SEGMENT_CHARS,
    Segment,
    SpeechSpan,
    assign_voices,
    plan_chapter,
)
from services.novel_dialogue import segment

CHAPTER = [
    "He paused. “Then we go,” Arthur said. “And we do not stop.” She nodded.",
    "“My dear Arthur,” said Tessia, “you never could.”",
    "The wind moved through the grass.",
]


def spans_for(paragraphs, speakers):
    """Real segmenter output, with a speaker attached in order."""
    segs = segment(paragraphs)
    out = []
    for span, who in zip(segs.spans, speakers):
        out.append(SpeechSpan(span.paragraph, span.start, span.end, who))
    return out


VOICES = {"arthur": "m1", "tessia": "f1"}


class TestVoiceAssignment:
    def test_voices_match_gender(self):
        got = assign_voices(
            [("Arthur", "male"), ("Tessia", "female")],
            [("m1", "male"), ("f1", "female")],
        )

        assert got == {"arthur": "m1", "tessia": "f1"}

    def test_unknown_gender_gets_no_voice(self):
        # Same refusal the attribution gate makes. Gender came from pronoun
        # counts; "unknown" means the text did not say, and a guess is wrong on
        # every line that character ever speaks.
        got = assign_voices(
            [("Ghost", "unknown")], [("m1", "male"), ("f1", "female")]
        )

        assert got == {}

    def test_a_description_never_gets_a_voice(self):
        got = assign_voices([("the crowd", "male")], [("m1", "male")])

        assert got == {}

    def test_speaking_order_wins_when_the_pack_runs_short(self):
        # The characters who lose out are the ones heard least.
        got = assign_voices(
            [("Busy", "male"), ("Quiet", "male")], [("m1", "male")]
        )

        assert got == {"busy": "m1"}

    def test_a_character_never_borrows_the_other_gender(self):
        got = assign_voices([("Tessia", "female")], [("m1", "male")])

        assert got == {}

    def test_the_pov_character_reads_in_the_narrator_s_voice(self):
        # In a first-person book the narrator and the POV character ARE the
        # same person; a second voice would have one person answering himself.
        got = assign_voices(
            [("Arthur", "male"), ("Tessia", "female")],
            [("m1", "male"), ("f1", "female")],
            pov="Arthur",
        )

        assert got == {"tessia": "f1"}

    def test_the_pov_rule_does_not_depend_on_the_gender_heuristic(self):
        # It cannot see the narrator at all: gender comes from third-person
        # pronouns and first-person narration never uses one about itself. On a
        # real chapter the protagonist scored he=0 she=3 and fell to "unknown"
        # — the right outcome by a broken route, which stops being right the
        # moment the chapter is third person.
        got = assign_voices(
            [("Arthur", "male")], [("m1", "male")], pov="Arthur"
        )

        assert got == {}

    def test_the_pov_match_ignores_titles(self):
        got = assign_voices(
            [("Grandpa Virion", "male")], [("m1", "male")], pov="Virion"
        )

        assert got == {}

    def test_the_narrator_s_voice_is_never_given_to_a_character(self):
        # It is picked from the same pack, so this is an easy mistake: on real
        # plans the flattest male clip became the narrator AND was handed to
        # two characters, who would then be indistinguishable from the
        # narration — the exact thing per-character voices exist to avoid.
        got = assign_voices(
            [("Windsom", "male")],
            [("m1", "male"), ("m2", "male")],
            narrator_voice="m1",
        )

        assert got == {"windsom": "m2"}

    def test_a_character_reads_as_narrator_rather_than_stealing_that_voice(self):
        # When the narrator's voice is the only one of that gender, the
        # character is narrated. Sounding like the narrator by accident is
        # worse than being narrated on purpose.
        got = assign_voices(
            [("Windsom", "male")], [("m1", "male")], narrator_voice="m1"
        )

        assert got == {}

    def test_a_pov_character_still_gets_a_voice_when_they_are_not_the_only_pov(self):
        # The series cast is for the WHOLE book. A character who narrates some
        # chapters still SPEAKS in the ones somebody else narrates, and there
        # they need a voice like anyone else — the chapter plan is what drops
        # the narrator of that particular chapter.
        #
        # Measured on the real series: Tessia narrates 2 of 10 chapters but
        # speaks 175 lines across 6 — more than anyone, the protagonist
        # included. Excluding her from the series cast left her with no voice
        # at all, so through all seven chapters Arthur narrates she was read
        # in his narration voice, indistinguishable from the prose.
        got = assign_voices(
            [("Tessia", "female"), ("Myre", "female")],
            [("f1", "female"), ("f2", "female")],
        )

        assert got == {"tessia": "f1", "myre": "f2"}

    def test_the_twelve_voice_ceiling_holds(self):
        cast = [(f"N{i}", "male") for i in range(30)]
        pack = [(f"m{i}", "male") for i in range(30)]

        assert len(assign_voices(cast, pack)) == 12


class TestPlanning:
    def test_speech_gets_its_speaker_s_voice(self):
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Arthur", "Arthur", "Tessia", "Tessia"]), VOICES)

        speech = [s for s in plan if s.is_speech]
        assert speech and all(s.voice_id for s in speech)

    def test_narration_is_the_narrator(self):
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Arthur", "Arthur", "Tessia", "Tessia"]), VOICES)

        narration = [s for s in plan if not s.is_speech]
        assert narration and all(s.voice_id is None for s in narration)

    def test_an_unvoiced_speaker_reads_as_narrator(self):
        # A character with no voice assigned is narrated, not silent and not
        # given somebody else's voice.
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Nobody"] * 4), {})

        assert all(s.voice_id is None for s in plan)

    def test_every_segment_points_at_its_own_words(self):
        # The highlight follows these offsets. Off by the whitespace the
        # splitter ate is a highlight on the wrong words.
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Arthur", "Arthur", "Tessia", "Tessia"]), VOICES)

        for seg in plan:
            assert CHAPTER[seg.paragraph][seg.start : seg.end] == seg.text

    def test_segments_are_sentences_not_paragraphs(self):
        # What makes follow-along free: one segment rendered at a time means
        # its duration IS len(samples)/rate, with no aligner.
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Arthur", "Arthur", "Tessia", "Tessia"]), VOICES)

        first = [s for s in plan if s.paragraph == 0]
        assert len(first) > 2

    def test_segments_run_in_reading_order(self):
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Arthur", "Arthur", "Tessia", "Tessia"]), VOICES)

        keys = [(s.paragraph, s.start) for s in plan]
        assert keys == sorted(keys)

    def test_a_narration_run_does_not_keep_the_quote_marks(self):
        # They sit outside a speech span, so they land at the edges of the
        # narration either side. Nothing reads them aloud, but they are inside
        # the range the playhead highlights — so follow-along would light up a
        # punctuation mark before reaching the words.
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Arthur", "Arthur", "Tessia", "Tessia"]), VOICES)

        for seg in plan:
            assert seg.text[0] not in "\u201c\u201d\"'"
            assert seg.text[-1] not in "\u201c\u201d"

    def test_trimming_keeps_the_offsets_honest(self):
        # The trim must move the offsets, not desync them: start/end have to
        # bracket exactly the characters that get spoken.
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Arthur", "Arthur", "Tessia", "Tessia"]), VOICES)

        for seg in plan:
            assert CHAPTER[seg.paragraph][seg.start : seg.end] == seg.text

    def test_a_run_of_pure_punctuation_is_never_rendered(self):
        # Paragraphs routinely leave a bare closing quote between spans;
        # rendering it is a clip of silence mid-sentence and a highlight that
        # flickers over punctuation.
        plan = plan_chapter(CHAPTER, spans_for(CHAPTER, ["Arthur", "Arthur", "Tessia", "Tessia"]), VOICES)

        assert all(any(c.isalnum() for c in s.text) for s in plan)

    def test_a_blank_paragraph_contributes_nothing(self):
        plan = plan_chapter(["", "   ", "Real words here."], [], {})

        assert [s.text for s in plan] == ["Real words here."]

    def test_a_tiny_fragment_is_merged_not_rendered_alone(self):
        # A half-second "Oh," between two long sentences is a click in the
        # audio and a highlight nobody can read.
        paragraphs = ["The hall was quiet and cold. Oh. He walked on through it."]
        plan = plan_chapter(paragraphs, [], {})

        assert all(len(s.text) >= MIN_SEGMENT_CHARS for s in plan)

    def test_a_chapter_with_no_speech_is_all_narrator(self):
        plan = plan_chapter(["The wind moved through the grass."], [], VOICES)

        assert len(plan) == 1 and plan[0].voice_id is None

    def test_an_out_of_range_span_is_ignored_not_crashed(self):
        plan = plan_chapter(
            ["Short."], [SpeechSpan(0, 2, 9999, "Arthur")], VOICES
        )

        assert [s.text for s in plan] == ["Short."]
