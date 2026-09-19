"""The dialogue segmenter — the coordinate system everything else keys on.

Attribution can only name a speaker for a span this module found, so a span
missed here is a line read by the narrator forever, and a span invented here
gets a character voice attached to something that was never speech. The bias is
deliberately toward missing rather than inventing.

Measured on 120 of the owner's real cached chapters: 4,626 quoted spans, only
19% with a speech verb in the paragraph. These tests use the same prose shapes.
"""

from __future__ import annotations

from services.novel_dialogue import (
    HEAD_CHARS,
    detect_style,
    find_pov_headers,
    normalize_name,
    segment,
)

# The real opening of a cached chapter, curly quotes and all.
TBATE = [
    "Chapter 463",
    "ARTHUR LEYWIN",
    "Thick blades of deep green grass bent under my steps as I walked.",
    "“If only our responsibilities were proportional to our size, then I "
    "could leave all this to you, couldn’t I?” I said aloud.",
    "I watched idly as the scuttling creature made its way around the tree.",
]


def _slice(paragraphs, span):
    return paragraphs[span.paragraph][span.start : span.end]


class TestStyle:
    def test_curly_quoted_prose_is_recognised(self):
        assert detect_style(TBATE) == "quoted"

    def test_em_dash_dialogue_is_recognised_so_it_can_be_skipped(self):
        # No closing delimiter, so the end of a line is a judgement call. We
        # detect it in order to serve narrator, not to parse it.
        paragraphs = [
            "—I told you already, she said.",
            "—And I told you I did not care.",
            "—Then we are finished.",
        ]
        assert detect_style(paragraphs) == "emdash"

    def test_narration_with_no_dialogue_is_neither(self):
        assert detect_style(["He walked.", "The sky was grey.", "Nothing moved."]) == "none"

    def test_an_emdash_source_yields_no_spans(self):
        result = segment(
            [
                "—I told you already.",
                "—And I told you I did not care.",
                "—Then we are finished.",
            ]
        )
        assert result.style == "emdash"
        assert result.spans == ()


class TestSpans:
    def test_a_quoted_line_is_located_by_offset(self):
        result = segment(TBATE)
        assert len(result.spans) == 1
        span = result.spans[0]
        assert span.paragraph == 3
        assert _slice(TBATE, span).startswith("If only our")
        assert span.head == "If only our re"[:HEAD_CHARS]

    def test_offsets_index_the_paragraph_not_the_chapter(self):
        # Everything downstream — the audio timing map, the reader highlight —
        # slices paragraphs[p][s:e]. A global offset would break the moment one
        # paragraph changed on refetch.
        result = segment(TBATE)
        span = result.spans[0]
        assert TBATE[span.paragraph][span.start : span.end].endswith("couldn’t I?")

    def test_straight_quotes_work_too(self):
        paragraphs = ['"Then we go," he said, and the door closed behind them.']
        result = segment(paragraphs)
        assert len(result.spans) == 1
        assert _slice(paragraphs, result.spans[0]) == "Then we go,"

    def test_corner_brackets_work(self):
        paragraphs = ["「I will not ask again.」 The blade did not move."]
        result = segment(paragraphs)
        assert len(result.spans) == 1
        assert _slice(paragraphs, result.spans[0]) == "I will not ask again."


class TestSplitQuotes:
    def test_a_quote_split_by_attribution_is_two_spans(self):
        paragraphs = [
            "“My dear Scrooge,” said the gentleman, “how are you?”"
        ]
        result = segment(paragraphs)
        assert len(result.spans) == 2
        assert _slice(paragraphs, result.spans[0]) == "My dear Scrooge,"
        assert _slice(paragraphs, result.spans[1]) == "how are you?"

    def test_the_tail_is_marked_as_continuing(self):
        # It shares the first span's speaker, so the model is never asked about
        # it — one fewer chance to be confidently wrong.
        paragraphs = [
            "“My dear Scrooge,” said the gentleman, “how are you?”"
        ]
        spans = segment(paragraphs).spans
        assert spans[0].continues is False
        assert spans[1].continues is True


class TestMultiParagraphQuotes:
    def test_an_unclosed_quote_carries_into_the_next_paragraph(self):
        # Classic prose opens a quotation per paragraph and closes it only at
        # the very end. A per-paragraph regex pairs the wrong delimiters here
        # and produces garbage on Gutenberg and Standard Ebooks.
        paragraphs = [
            "“It is a truth universally acknowledged, that a single man",
            "“must be in want of a wife.”",
            "He said nothing more.",
        ]
        result = segment(paragraphs)
        assert len(result.spans) == 2
        assert result.spans[0].paragraph == 0
        assert result.spans[1].paragraph == 1
        assert _slice(paragraphs, result.spans[1]) == "must be in want of a wife."

    def test_narration_after_a_closed_quote_is_not_captured(self):
        paragraphs = ["“Go.” He turned away and did not look back."]
        result = segment(paragraphs)
        assert len(result.spans) == 1
        assert _slice(paragraphs, result.spans[0]) == "Go."


class TestScareQuotes:
    def test_emphasis_in_the_middle_of_narration_is_not_speech(self):
        # A Christmas Carol, verbatim, in the same paragraph as real dialogue.
        paragraphs = ["They often “came down” handsomely, and Scrooge never did."]
        assert segment(paragraphs).spans == ()

    def test_a_short_quote_with_an_attribution_verb_IS_speech(self):
        paragraphs = ["“Go,” he said."]
        result = segment(paragraphs)
        assert len(result.spans) == 1

    def test_a_short_quote_with_terminal_punctuation_is_speech(self):
        paragraphs = ["“Run!”"]
        assert len(segment(paragraphs).spans) == 1

    def test_a_scare_quote_swallowing_the_sentence_period_is_still_not_speech(self):
        # Verbatim from a real cached chapter. English convention puts the
        # period INSIDE the closing quote even when the quoted words are not
        # speech, so this ends in terminal punctuation while being narration.
        # An adversarial pass over live attributions caught it being read as a
        # spoken line -- harmless there only because the narrator happened to
        # be the assigned speaker. A scare-quoted phrase echoing a DIFFERENT
        # character switches voices mid-narration in the finished audio.
        paragraphs = ['He seemed amused at the apparent irony of us “lesser races.”']

        assert segment(paragraphs).spans == ()

    def test_a_full_line_ending_in_a_period_is_still_speech(self):
        # The period rule must not swing too far: a quote that OPENS the
        # sentence has no narration before it to read as emphasis.
        paragraphs = ["“Go.” He turned away and did not look back."]

        assert len(segment(paragraphs).spans) == 1

    def test_a_question_inside_narration_is_still_speech(self):
        # Nothing puts a question mark inside quotes by typographic habit, so
        # it remains real evidence even mid-sentence.
        paragraphs = ["She asked him “what now?” and waited."]

        assert len(segment(paragraphs).spans) == 1


class TestPovHeaders:
    def test_a_bare_name_in_capitals_is_a_pov_header(self):
        # 119 of 120 sampled chapters have exactly one, which is what makes
        # first-person dialogue resolvable without asking the model.
        headers = find_pov_headers(TBATE)
        assert [h.name for h in headers] == ["Arthur Leywin"]
        assert headers[0].paragraph == 1

    def test_a_chapter_heading_is_not_a_pov_header(self):
        assert find_pov_headers(["CHAPTER 12", "PART ONE", "PROLOGUE"]) == ()

    def test_a_shouted_line_is_not_a_pov_header(self):
        # Short and uppercase, but it ends in terminal punctuation.
        assert find_pov_headers(["NO!", "STOP."]) == ()

    def test_ordinary_narration_is_not_a_pov_header(self):
        assert find_pov_headers(["He walked into the room and sat down."]) == ()


class TestNormalizeName:
    def test_honorifics_are_stripped(self):
        assert normalize_name("Lord Arthur") == "arthur"
        assert normalize_name("Mr. Scrooge") == "scrooge"

    def test_japanese_korean_suffixes_are_stripped(self):
        assert normalize_name("Tessia-san") == "tessia"
        assert normalize_name("Seo-yeon-nim") == "seo-yeon"

    def test_possessives_are_stripped(self):
        assert normalize_name("Arthur’s") == "arthur"

    def test_a_leading_the_is_stripped(self):
        assert normalize_name("The Lance") == "lance"

    def test_case_and_width_are_normalised(self):
        # One function, so the cast digest sent to the model and the merge of a
        # name it proposes can never disagree about what is the same name.
        assert normalize_name("ARTHUR LEYWIN") == normalize_name("Arthur Leywin")
