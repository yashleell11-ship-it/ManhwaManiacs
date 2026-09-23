"""The FTS5 MATCH expression ``GET /ocr/search`` builds (spec §4.4).

Each whitespace-separated term is wrapped in double quotes so that punctuation
a reader types (``!``, ``-``, ``*``, ``:``) is matched literally instead of
being parsed as FTS5 query syntax. Wrapping alone is not enough: a term
carrying its OWN double quote closes the string early. ``he"llo`` became
``"he"llo"`` — an unterminated FTS5 string — and SQLite answered the whole
request with ``OperationalError: unterminated string``, i.e. a 500 on exactly
the query someone searching for a remembered line of manga dialogue types.

``match_expr`` is pure, so the quoting rule is pinned here directly; the
end-to-end test underneath proves the route no longer 500s on it.
"""

from __future__ import annotations

import pytest

from services.ocr_search import match_expr, terms_of

SRC = "mangadex"
SERIES = "the-quoted-series"


# --- the pure rule --------------------------------------------------------


def test_plain_terms_are_quoted_one_by_one():
    assert match_expr("hello world") == '"hello" "world"'


def test_an_embedded_quote_is_doubled_not_left_to_terminate_the_string():
    """The regression. Doubling is how SQL string literals escape a quote, and
    FTS5 strings follow the same rule."""
    assert match_expr('he"llo') == '"he""llo"'


def test_a_bare_quote_is_a_term_of_its_own():
    assert match_expr('"') == '""""'


def test_punctuation_a_reader_types_stays_literal():
    assert match_expr("wait-what?! *sigh*") == '"wait-what?!" "*sigh*"'


def test_terms_and_expression_never_disagree_about_what_was_searched():
    """``terms_of`` also drives snippet highlighting, so a divergence would
    mark the wrong words in results that did match."""
    raw = '  the "crimson"   knight '
    assert terms_of(raw) == ["the", '"crimson"', "knight"]
    assert match_expr(raw) == '"the" """crimson""" "knight"'


# --- the same expression, through real SQLite FTS5 ------------------------


def test_a_nul_byte_separates_terms_instead_of_ending_the_query():
    """FTS5 treats NUL as the end of the query string, so a quoted term with
    one inside never closes: ``unterminated string``, and a 500."""
    assert terms_of("hey\x00you") == ["hey", "you"]
    assert match_expr("hey\x00you") == '"hey" "you"'
    assert terms_of("\x00\x01") == []


@pytest.mark.parametrize(
    "query", ['he"llo', '"', 'a "b" c', 'say "hi"', "hey\x00you", "x\x00"]
)
def test_the_expression_is_accepted_by_sqlite(db_session, query):
    """Straight at the engine: an unescaped quote raises OperationalError here,
    which is what surfaced as the route's 500."""
    from sqlalchemy import text

    db_session.execute(
        text("SELECT rowid FROM chapter_ocr_fts WHERE chapter_ocr_fts MATCH :q"),
        {"q": match_expr(query)},
    ).all()


# --- snippet highlighting --------------------------------------------------


def _snippet(text_value, raw_query):
    from services.ocr_search import OcrSearchService

    return OcrSearchService._snippet(
        text_value, [t.lower() for t in terms_of(raw_query)]
    )


def test_a_short_term_never_splits_the_marks_a_longer_one_added():
    """The regression. One ``re.sub`` per term ran over the output of the one
    before, so "a" matched inside the ``<mark>`` tags already added and the
    clients printed ``<m<mark>a</mark>rk>`` as literal text."""
    assert _snippet("I am a hunter, and that is all.", "i am a hunter") == (
        "<mark>I</mark> <mark>am</mark> <mark>a</mark> <mark>hunter</mark>, "
        "<mark>a</mark>nd th<mark>a</mark>t <mark>i</mark>s <mark>a</mark>ll."
    )


@pytest.mark.parametrize("query", ["hunter mark", "hunter /", "hunter k", "hunter <"])
def test_terms_found_in_the_tag_text_leave_the_tags_whole(query):
    got = _snippet("the hunter left", query)
    assert "<mark>hunter</mark>" in got
    stripped = got.replace("<mark>", "").replace("</mark>", "")
    assert stripped == "the hunter left"


def test_the_longest_term_still_wins_at_a_position():
    assert _snippet("the hunter", "hunt hunter") == "the <mark>hunter</mark>"


# --- end to end -----------------------------------------------------------


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("ocr-quote")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


@pytest.fixture
def h(as_user, acct):
    uid, pid = acct
    return as_user(uid, pid)


@pytest.fixture
def seeded(client, h, acct, seed_follow):
    uid, pid = acct
    seed_follow(
        uid, pid, source_id=SRC, series_key=SERIES,
        known_chapters='[{"key": "c1"}]',
    )
    up = client.post(
        "/ocr/chapter",
        json={
            "source_id": SRC,
            "series_key": SERIES,
            "chapter_key": "c1",
            "engine": "mlkit",
            "pages": [{"page": 1, "text": 'he said "hello" and left'}],
        },
        headers=h,
    )
    assert up.status_code == 200, up.text


@pytest.mark.parametrize("query", ['he"llo', '"', 'said "hello"'])
def test_a_query_with_a_quote_does_not_500(client, h, seeded, query):
    got = client.get("/ocr/search", params={"q": query}, headers=h)
    assert got.status_code == 200, got.text


@pytest.mark.parametrize("query", ["he\x00llo", "\x00", "said\x00hello"])
def test_a_query_with_a_nul_byte_does_not_500(client, h, seeded, query):
    got = client.get("/ocr/search", params={"q": query}, headers=h)
    assert got.status_code == 200, got.text


def test_a_nul_byte_between_words_still_finds_the_line(client, h, seeded):
    got = client.get("/ocr/search", params={"q": "said\x00left"}, headers=h)
    assert got.status_code == 200, got.text
    assert [hit["chapter_key"] for hit in got.json()["items"]] == ["c1"]


def test_a_quoted_phrase_still_finds_the_line(client, h, seeded):
    got = client.get("/ocr/search", params={"q": 'said "hello"'}, headers=h)
    assert got.status_code == 200, got.text
    assert [hit["chapter_key"] for hit in got.json()["items"]] == ["c1"]
