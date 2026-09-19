"""``GET /novels/attribution`` — who speaks each line, when that is known.

The property worth pinning is what this endpoint does NOT do. Attribution costs
real money per chapter, so it is bought by a deliberate bulk pass and never as
a side effect of a reader turning a page. An endpoint that attributed on demand
would make scrolling a chapter list quietly spend.
"""

from __future__ import annotations

import json

from database.models import NovelChapterAttribution, NovelSeriesCast

# The app has to be BUILT with the flag already on -- the router is mounted at
# create_app, so a client made before the flag flips serves a stock 404. These
# fixtures build it in the right order, and novels_off is production's state.
from tests.test_novels_flag import (  # noqa: F401
    SERIES,
    STUB_SOURCE,
    novels_off,
    novels_on,
    stub_registered,
)

CHAPTER = "ch-1"

DEFAULT_SPANS = [
    {"p": 1, "s": 1, "e": 12, "ord": 0, "head": "Then we go,",
     "cont": False, "speaker": "Arthur", "rule": 1},
    {"p": 2, "s": 1, "e": 9, "ord": 0, "head": "Go on.",
     "cont": False, "speaker": None, "rule": 7},
]


def seed(db, *, status="ok", spans=None, fingerprint="abc123"):
    db.add(NovelChapterAttribution(
        source_id=STUB_SOURCE, series_key=SERIES, chapter_key=CHAPTER,
        text_fingerprint=fingerprint, paragraph_count=3, style="quoted",
        spans=json.dumps(DEFAULT_SPANS if spans is None else spans),
        status=status, model="deepseek-flash",
    ))
    db.add(NovelSeriesCast(
        source_id=STUB_SOURCE, series_key=SERIES, display_name="Arthur",
        normalized_name="arthur", gender="male", voice_id="libritts-2803",
        line_count=40,
    ))
    # A cast member who does not speak in THIS chapter.
    db.add(NovelSeriesCast(
        source_id=STUB_SOURCE, series_key=SERIES, display_name="Nobody",
        normalized_name="nobody", gender="unknown", line_count=1,
    ))
    db.commit()


def fetch(client):
    return client.get(
        "/novels/attribution",
        params={"source": STUB_SOURCE, "series": SERIES, "chapter": CHAPTER},
    )


class TestReading:
    def test_an_attributed_chapter_returns_its_spans(self, novels_on, db_session):
        seed(db_session)

        body = fetch(novels_on).json()

        assert body["attributed"] is True
        assert body["text_fingerprint"] == "abc123"
        assert [s["speaker"] for s in body["spans"]] == ["Arthur"]

    def test_narration_is_not_sent(self, novels_on, db_session):
        # A span with no speaker is prose. Sending it would make the client
        # draw a box around ordinary narration.
        seed(db_session)

        assert all(s["speaker"] for s in fetch(novels_on).json()["spans"])

    def test_the_head_travels_with_each_span(self, novels_on, db_session):
        # It is what lets the client prove the offsets still describe the text
        # it is showing; the chapter cache refetches, so they will disagree.
        seed(db_session)

        assert fetch(novels_on).json()["spans"][0]["head"] == "Then we go,"

    def test_only_speakers_in_this_chapter_are_listed(self, novels_on, db_session):
        # The series cast runs to dozens; a chapter needs the handful that
        # speak in it, so the client's colour assignment stays short and stable.
        seed(db_session)

        assert [c["name"] for c in fetch(novels_on).json()["cast"]] == ["Arthur"]

    def test_the_voice_comes_with_the_cast(self, novels_on, db_session):
        seed(db_session)

        assert fetch(novels_on).json()["cast"][0]["voice_id"] == "libritts-2803"


class TestAbsence:
    def test_an_unattributed_chapter_is_not_an_error(self, novels_on):
        # Most of the library. A client asking about every chapter should not
        # be reading error paths for the ordinary case.
        response = fetch(novels_on)

        assert response.status_code == 200
        assert response.json() == {
            "attributed": False, "spans": [], "cast": [], "text_fingerprint": None,
        }

    def test_a_failed_attribution_reads_as_absent(self, novels_on, db_session):
        # A row that exists because the model truncated is not an answer.
        seed(db_session, status="failed")

        assert fetch(novels_on).json()["attributed"] is False

    def test_a_chapter_with_no_dialogue_reads_as_absent(self, novels_on, db_session):
        seed(db_session, status="no_dialogue", spans=[])

        assert fetch(novels_on).json()["attributed"] is False


class TestItNeverSpends:
    def test_reading_does_not_call_the_model(self, novels_on, monkeypatch):
        # The whole point. An endpoint that attributed on demand would turn
        # scrolling a chapter list into spending.
        from services import deepseek_client

        def boom(*_a, **_k):
            raise AssertionError("a reader request reached the paid API")

        monkeypatch.setattr(deepseek_client, "complete_json", boom)

        assert fetch(novels_on).status_code == 200

    def test_it_writes_nothing(self, novels_on, db_session):
        seed(db_session)

        fetch(novels_on)

        assert db_session.query(NovelChapterAttribution).count() == 1


class TestFlag:
    def test_the_route_is_dark_when_novels_are_off(self, novels_off):
        # The same 404 as a route that was never built.
        response = fetch(novels_off)

        assert response.status_code == 404
