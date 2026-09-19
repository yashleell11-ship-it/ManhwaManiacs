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

    def test_a_description_is_never_served_as_a_character(self, novels_on, db_session):
        # The client assigns a colour per cast name, so serving "the crowd" or
        # "Wren Kain, Lyra, and Mordain" would tint a crowd as though it were
        # one person. Measured on three real chapters, seventeen spans would
        # have been tinted that way. It is also the rule the RENDERER applies,
        # and they must agree — otherwise the page shows a character where the
        # audio reads narration.
        seed(db_session, spans=[
            {"p": 1, "s": 1, "e": 12, "ord": 0, "head": "Then we go,",
             "cont": False, "speaker": "Arthur", "rule": 1},
            {"p": 2, "s": 1, "e": 9, "ord": 0, "head": "Run!",
             "cont": False, "speaker": "the crowd", "rule": 1},
            {"p": 3, "s": 1, "e": 9, "ord": 0, "head": "Now!",
             "cont": False, "speaker": "Wren Kain, Lyra, and Mordain", "rule": 1},
        ])

        body = fetch(novels_on).json()

        assert [s["speaker"] for s in body["spans"]] == ["Arthur"]
        assert [c["name"] for c in body["cast"]] == ["Arthur"]

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

    def test_the_chapter_s_own_narrator_comes_back(self, novels_on, db_session):
        # Not the series narrator. A book that rotates POV has a different one
        # per chapter, and the narrator's VOICE has to follow it — otherwise a
        # chapter narrated by a woman is read in the series default.
        from database.models import NovelChapterAttribution

        seed(db_session)
        row = db_session.get(
            NovelChapterAttribution, (STUB_SOURCE, SERIES, CHAPTER)
        )
        row.pov = json.dumps(["Tessia Eralith"])
        db_session.flush()

        assert fetch(novels_on).json()["narrator"] == "Tessia Eralith"

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
            "attributed": False, "spans": [], "cast": [],
            "text_fingerprint": None, "narrator": None,
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


class TestAudioRoutes:
    """`GET /novels/audio` and `/novels/audio/file`.

    Absence is the ordinary state for almost the whole library, and the file
    route has to support Range or every seek in a player re-downloads the
    entire chapter.
    """

    def _render(self, tmp_path, monkeypatch, *, timing=True):
        import json as _json

        from services.chapter_audio_store import chapter_paths

        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
        audio, timing_path = chapter_paths(STUB_SOURCE, SERIES, CHAPTER)
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"OggS" + bytes(range(256)) * 16)
        if timing:
            timing_path.write_text(_json.dumps({
                "total_ms": 61000,
                "segments": [{"i": 0, "start_ms": 0, "end_ms": 1200, "p": 1,
                              "s": 0, "e": 9, "voice": "v1", "speech": True}],
            }), encoding="utf-8")
        return audio

    def _meta(self, client):
        return client.get("/novels/audio", params={
            "source": STUB_SOURCE, "series": SERIES, "chapter": CHAPTER})

    def _file(self, client, headers=None):
        return client.get("/novels/audio/file", params={
            "source": STUB_SOURCE, "series": SERIES, "chapter": CHAPTER},
            headers=headers or {})

    def test_an_unrendered_chapter_is_not_an_error(self, novels_on, tmp_path, monkeypatch):
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))

        body = self._meta(novels_on).json()

        assert body["available"] is False and body["segments"] == []

    def test_a_rendered_chapter_reports_measured_timings(self, novels_on, tmp_path, monkeypatch):
        # Measured, not estimated: each segment was rendered alone, so its
        # duration is the length of the samples that came back.
        self._render(tmp_path, monkeypatch)

        body = self._meta(novels_on).json()

        assert body["available"] is True
        assert body["total_ms"] == 61000
        assert body["segments"][0]["end_ms"] == 1200

    def test_the_file_is_served(self, novels_on, tmp_path, monkeypatch):
        self._render(tmp_path, monkeypatch)

        response = self._file(novels_on)

        assert response.status_code == 200
        assert response.headers["content-type"].startswith("audio/")

    def test_a_range_request_gets_a_206(self, novels_on, tmp_path, monkeypatch):
        # Without this every seek re-downloads the whole chapter. Verified
        # against Starlette rather than assumed.
        self._render(tmp_path, monkeypatch)

        response = self._file(novels_on, {"Range": "bytes=0-99"})

        assert response.status_code == 206
        assert len(response.content) == 100

    def test_it_advertises_range_support(self, novels_on, tmp_path, monkeypatch):
        self._render(tmp_path, monkeypatch)

        assert self._file(novels_on).headers.get("accept-ranges") == "bytes"

    def test_a_missing_file_is_a_plain_404(self, novels_on, tmp_path, monkeypatch):
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))

        assert self._file(novels_on).status_code == 404

    def test_the_audio_routes_are_dark_when_novels_are_off(self, novels_off):
        assert novels_off.get("/novels/audio", params={
            "source": STUB_SOURCE, "series": SERIES, "chapter": CHAPTER,
        }).status_code == 404


class TestCastCorrections:
    """Pinning a voice by hand, and declaring one name another character."""

    def _seed_cast(self, db, name="Arthur", gender="unknown"):
        from database.models import NovelSeriesCast

        row = NovelSeriesCast(
            source_id=STUB_SOURCE, series_key=SERIES, display_name=name,
            normalized_name=name.casefold(), gender=gender,
        )
        db.add(row)
        db.flush()
        return row

    def _correct(self, client, **over):
        body = {"source_id": STUB_SOURCE, "series_key": SERIES, "name": "Arthur"}
        body.update(over)
        return client.post("/novels/cast", json=body)

    def test_a_gender_can_be_pinned(self, novels_on, db_session):
        self._seed_cast(db_session)

        body = self._correct(novels_on, gender="male").json()

        assert body["gender"] == "male" and body["locked"] is True

    def test_a_voice_can_be_pinned(self, novels_on, db_session):
        self._seed_cast(db_session)

        assert self._correct(novels_on, voice_id="libritts-251").json()["voice_id"] == "libritts-251"

    def test_a_nonsense_gender_is_rejected_at_the_edge(self, novels_on, db_session):
        # Stored, it would silently route the character to the narrator.
        self._seed_cast(db_session)

        assert self._correct(novels_on, gender="woman").status_code == 422

    def test_an_alias_can_be_declared(self, novels_on, db_session):
        self._seed_cast(db_session)

        response = novels_on.post("/novels/cast/alias", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "alias": "King Grey", "canonical": "Arthur",
        })

        assert response.status_code == 200
        assert response.json()["resolves_to"] == "Arthur"

    def test_one_alias_corrects_every_chapter_at_once(self, novels_on, db_session):
        # The whole reason spans store a label instead of a foreign key. No
        # chapter is re-attributed and no span is rewritten.
        from services import novel_attribution_service as svc
        from services.novel_dialogue import normalize_name

        cast = self._seed_cast(db_session)
        cast.voice_id = "voice-m1"
        db_session.flush()

        novels_on.post("/novels/cast/alias", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "alias": "King Grey", "canonical": "Arthur",
        })

        mapping = svc.resolve_voice_map(db_session, STUB_SOURCE, SERIES)
        assert mapping[normalize_name("King Grey")] == "voice-m1"

    def test_an_alias_to_an_unknown_character_is_a_404(self, novels_on):
        # An alias pointing at nobody resolves to nothing, which is harder to
        # notice than an error.
        response = novels_on.post("/novels/cast/alias", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "alias": "King Grey", "canonical": "Nobody At All",
        })

        assert response.status_code == 404

    def test_a_name_cannot_alias_itself(self, novels_on, db_session):
        self._seed_cast(db_session)

        response = novels_on.post("/novels/cast/alias", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "alias": "Arthur", "canonical": "Arthur",
        })

        assert response.status_code == 400

    def test_the_cast_routes_are_dark_when_novels_are_off(self, novels_off):
        assert novels_off.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES, "name": "Arthur",
        }).status_code == 404
