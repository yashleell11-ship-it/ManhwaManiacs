"""The roster a listener picks from, and the narration voice they pin.

Choosing a voice by hand is the whole point of these three routes: the
automatic assignment is a starting position, not a verdict. What is worth
pinning here is that a choice the RENDERER cannot honour is refused at the
door — a voice id that is not in the pack does not become a preference, it
becomes a chapter that silently reads as narrator.
"""

from __future__ import annotations

import json

from database.models import NovelSeriesCast, NovelSeriesCastState

from tests.test_novels_flag import (  # noqa: F401
    SERIES,
    STUB_SOURCE,
    novels_off,
    novels_on,
    stub_registered,
)


def install_pack(tmp_path, monkeypatch, clips=None):
    """A pack on disk, because the roster is data and not a constant."""
    from services import voice_pack

    clips = clips if clips is not None else [
        {
            "voice_id": "libritts-2803", "gender": "male", "median_f0_hz": 103.0,
            "pitch_spread": 0.254, "seconds": 8.1, "license": "CC BY 4.0",
            "attribution": "LibriTTS-R", "transcript": "A line.",
            "sample": "m-low.opus",
        },
        {
            "voice_id": "libritts-251", "gender": "male", "median_f0_hz": 147.2,
            "pitch_spread": 0.166, "seconds": 11.5, "license": "CC BY 4.0",
            "attribution": "LibriTTS-R", "transcript": "Another line.",
            "sample": "m-high.opus",
        },
    ]
    for clip in clips:
        if clip.get("sample"):
            (tmp_path / clip["sample"]).write_bytes(b"OggS-stand-in")
    (tmp_path / "manifest.json").write_text(
        json.dumps({"version": "test", "clips": clips}), encoding="utf-8"
    )
    monkeypatch.setenv("MM_VOICES_DIR", str(tmp_path))
    voice_pack._cached.cache_clear()


class TestRoster:
    def test_the_pack_is_served_deepest_first(self, novels_on, tmp_path, monkeypatch):
        # The axis a person chooses on. "I want a deeper narrator" has to be
        # answerable by reading down the list.
        install_pack(tmp_path, monkeypatch)

        body = novels_on.get("/novels/voices").json()

        assert [v["voice_id"] for v in body["voices"]] == [
            "libritts-2803", "libritts-251"
        ]
        assert body["voices"][0]["pitch_hz"] == 103.0

    def test_no_pack_installed_is_an_empty_list_not_an_error(
        self, novels_on, tmp_path, monkeypatch
    ):
        # A deployment with no voices can still read novels; it just cannot
        # give anyone a voice yet.
        from services import voice_pack

        monkeypatch.setenv("MM_VOICES_DIR", str(tmp_path / "absent"))
        voice_pack._cached.cache_clear()

        response = novels_on.get("/novels/voices")

        assert response.status_code == 200
        assert response.json() == {"voices": []}

    def test_the_on_disk_filename_is_never_served(
        self, novels_on, tmp_path, monkeypatch
    ):
        # The client asks for a sample by voice id and never builds a path.
        install_pack(tmp_path, monkeypatch)

        voice = novels_on.get("/novels/voices").json()["voices"][0]

        assert "sample" not in voice and "file" not in voice


class TestSample:
    def test_a_sample_is_served_with_range_support(
        self, novels_on, tmp_path, monkeypatch
    ):
        # Without 206 a player refetches the whole clip on every scrub.
        install_pack(tmp_path, monkeypatch)

        response = novels_on.get("/novels/voices/sample?voice=libritts-2803")

        assert response.status_code == 200
        assert response.headers["accept-ranges"] == "bytes"
        assert response.content == b"OggS-stand-in"

    def test_an_unknown_voice_is_404(self, novels_on, tmp_path, monkeypatch):
        install_pack(tmp_path, monkeypatch)

        assert novels_on.get("/novels/voices/sample?voice=nope").status_code == 404

    def test_a_traversal_cannot_reach_outside_the_pack(
        self, novels_on, tmp_path, monkeypatch
    ):
        # The id arrives off a query string; resolution goes through the
        # manifest precisely so no path is ever built from user input.
        install_pack(tmp_path, monkeypatch)
        (tmp_path.parent / "secret.txt").write_text("not yours", encoding="utf-8")

        for attempt in ("../secret.txt", "..%2fsecret.txt", "/etc/passwd"):
            assert novels_on.get(
                f"/novels/voices/sample?voice={attempt}"
            ).status_code == 404


def real_pack(tmp_path, monkeypatch):
    """A pack whose samples are real Ogg Opus, so ``format=m4a`` transcodes."""
    from tests.test_chapter_audio_m4a import make_opus

    install_pack(tmp_path, monkeypatch)
    for name in ("m-low.opus", "m-high.opus"):
        make_opus(tmp_path / name)
    return tmp_path / "m-low.opus"


def sample(client, voice="libritts-2803", fmt=None, headers=None):
    params = {"voice": voice}
    if fmt is not None:
        params["format"] = fmt
    return client.get(
        "/novels/voices/sample", params=params, headers=headers or {}
    )


class TestSampleFormats:
    """Every preview was silent on an iPhone: the pack is Ogg Opus, and
    AVPlayer cannot open Ogg at all. ``format=m4a`` is the chapter route's
    answer, applied to the clips."""

    def test_the_default_is_still_the_clip_itself(
        self, novels_on, tmp_path, monkeypatch
    ):
        clip = real_pack(tmp_path, monkeypatch)

        for fmt in (None, "ogg"):
            response = sample(novels_on, fmt=fmt)
            assert response.headers["content-type"] == "audio/ogg"
            assert response.content == clip.read_bytes()
        assert not list(tmp_path.rglob("*.m4a"))

    def test_m4a_is_aac_in_mp4_made_once_beside_the_clip(
        self, novels_on, tmp_path, monkeypatch
    ):
        clip = real_pack(tmp_path, monkeypatch)

        first = sample(novels_on, fmt="m4a")
        stored = clip.with_suffix(".m4a")
        inode = stored.stat().st_ino
        second = sample(novels_on, fmt="m4a")

        assert first.status_code == 200
        assert first.headers["content-type"] == "audio/mp4"
        assert first.content[4:8] == b"ftyp"
        assert first.content == second.content == stored.read_bytes()
        assert stored.stat().st_ino == inode
        # Only the clip asked for.
        assert not (tmp_path / "m-high.m4a").exists()

    def test_m4a_answers_a_range_with_206(self, novels_on, tmp_path, monkeypatch):
        # iOS will not play a progressive MP4 from a server that ignores Range,
        # and its first request for one is usually a Range.
        real_pack(tmp_path, monkeypatch)

        part = sample(novels_on, fmt="m4a", headers={"Range": "bytes=0-1"})
        full = sample(novels_on, fmt="m4a").content

        assert part.status_code == 206
        assert part.headers["content-type"] == "audio/mp4"
        assert part.headers["content-range"] == f"bytes 0-1/{len(full)}"
        assert part.content == full[:2]

    def test_an_unknown_voice_or_a_path_is_404_and_writes_nothing(
        self, novels_on, tmp_path, monkeypatch
    ):
        # The voice id is resolved through the manifest before anything is
        # made, so no id can name a file to transcode or a place to write.
        from tests.test_chapter_audio_m4a import make_opus

        pack = tmp_path / "pack"
        pack.mkdir()
        real_pack(pack, monkeypatch)
        outside = make_opus(tmp_path / "outside.opus")

        for attempt in ("nope", "../outside.opus", "../outside"):
            assert sample(novels_on, attempt, "m4a").status_code == 404
        # Too long to be an id at all, which is refused before any lookup.
        assert sample(novels_on, str(outside), "m4a").status_code in (404, 422)
        assert not list(tmp_path.rglob("*.m4a"))

    def test_any_other_format_is_refused(self, novels_on, tmp_path, monkeypatch):
        real_pack(tmp_path, monkeypatch)

        assert sample(novels_on, fmt="flac").status_code == 422
        assert not list(tmp_path.rglob("*.m4a"))

    def test_a_clip_that_will_not_convert_is_the_chapter_routes_error(
        self, novels_on, tmp_path, monkeypatch
    ):
        # install_pack's stand-in bytes are not audio.
        install_pack(tmp_path, monkeypatch)

        response = sample(novels_on, fmt="m4a")

        assert response.status_code == 500
        assert response.json()["code"] == "audio_convert_failed"
        assert not list(tmp_path.rglob("*.m4a"))

    def test_a_pack_this_process_cannot_write_to_is_an_error_not_a_crash(
        self, novels_on, tmp_path, monkeypatch
    ):
        # The pack is copied onto the box by hand and can arrive owned by
        # someone else. The Ogg preview still plays; m4a says it could not.
        import os

        if os.geteuid() == 0:
            import pytest

            pytest.skip("root writes through any mode")
        clip = real_pack(tmp_path, monkeypatch)
        tmp_path.chmod(0o555)
        try:
            response = sample(novels_on, fmt="m4a")
            ogg = sample(novels_on)
        finally:
            tmp_path.chmod(0o755)

        assert response.status_code == 500
        assert response.json()["code"] == "audio_convert_failed"
        assert ogg.content == clip.read_bytes()

    def test_m4a_is_dark_when_novels_are_off(self, novels_off, tmp_path, monkeypatch):
        real_pack(tmp_path, monkeypatch)

        assert sample(novels_off, fmt="m4a").status_code == 404
        assert not list(tmp_path.rglob("*.m4a"))


class TestNarratorVoice:
    def _post(self, client, voice_id):
        return client.post("/novels/narrator", json={
            "source_id": STUB_SOURCE, "series_key": SERIES, "voice_id": voice_id,
        })

    def test_a_narration_voice_is_pinned_for_the_series(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        install_pack(tmp_path, monkeypatch)

        response = self._post(novels_on, "libritts-2803")

        assert response.status_code == 200
        assert response.json()["narrator_voice_id"] == "libritts-2803"
        row = db_session.get(NovelSeriesCastState, (STUB_SOURCE, SERIES))
        assert row.narrator_voice_id == "libritts-2803"

    def test_null_restores_the_derived_default(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # There has to be a way back from a choice, and "no voice at all" is
        # not a state the renderer can be in.
        install_pack(tmp_path, monkeypatch)
        self._post(novels_on, "libritts-2803")

        response = self._post(novels_on, None)

        assert response.json()["narrator_voice_id"] is None

    def test_a_voice_the_renderer_does_not_have_is_refused(
        self, novels_on, tmp_path, monkeypatch
    ):
        # Storing it would not be a preference — it would be narration that
        # silently falls back, with the UI still showing the choice.
        install_pack(tmp_path, monkeypatch)

        assert self._post(novels_on, "libritts-does-not-exist").status_code == 400

    def test_pinning_bumps_the_cast_version(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # It changes how the book sounds, so a client holding a cached voice
        # map has to notice.
        install_pack(tmp_path, monkeypatch)

        self._post(novels_on, "libritts-2803")
        first = db_session.get(NovelSeriesCastState, (STUB_SOURCE, SERIES)).cast_version
        db_session.expire_all()
        self._post(novels_on, "libritts-251")
        second = db_session.get(NovelSeriesCastState, (STUB_SOURCE, SERIES)).cast_version

        assert second > first


class TestCastVoiceValidation:
    def test_a_character_can_be_given_a_voice_from_the_pack(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        install_pack(tmp_path, monkeypatch)

        response = novels_on.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "name": "Arthur", "voice_id": "libritts-2803",
        })

        assert response.status_code == 200
        assert response.json()["voice_id"] == "libritts-2803"
        # Locked, so the next recast does not quietly undo the choice.
        assert response.json()["locked"] is True

    def test_a_voice_outside_the_pack_is_refused(
        self, novels_on, tmp_path, monkeypatch
    ):
        install_pack(tmp_path, monkeypatch)

        response = novels_on.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "name": "Arthur", "voice_id": "some-other-model",
        })

        assert response.status_code == 400

    def _stored(self, db_session, name="arthur"):
        db_session.expire_all()
        return db_session.query(NovelSeriesCast).filter_by(
            source_id=STUB_SOURCE, series_key=SERIES, normalized_name=name
        ).one()

    def test_an_explicit_null_clears_the_pinned_voice(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # Null is "Automatic voice": the character goes back to whatever the
        # automatic assignment gives them. It must get past the membership
        # check AND actually clear the pin — this used to answer 200 with the
        # old voice still stored, so the choice could never be undone.
        install_pack(tmp_path, monkeypatch)
        novels_on.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "name": "Arthur", "voice_id": "libritts-2803",
        })

        response = novels_on.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "name": "Arthur", "voice_id": None,
        })

        assert response.status_code == 200
        assert response.json()["voice_id"] is None
        assert self._stored(db_session).voice_id is None

    def test_a_gender_correction_leaves_the_voice_alone(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # Omitted is not null. Fixing somebody's gender must not quietly
        # throw away the voice the owner picked for them.
        install_pack(tmp_path, monkeypatch)
        novels_on.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "name": "Arthur", "voice_id": "libritts-2803",
        })

        response = novels_on.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "name": "Arthur", "gender": "male",
        })

        assert response.json()["voice_id"] == "libritts-2803"
        row = self._stored(db_session)
        assert row.voice_id == "libritts-2803"
        assert row.gender == "male"


class TestOwnerOnly:
    """The cast, the narrator and the aliases belong to the book, not a user.

    None of those rows carries a user id, so one account's change is what
    every listener hears, and a locked row outranks any later recast. Only
    the admin may make that kind of change; everybody may read it.
    """

    FORBIDDEN = "Administrator access required."

    def _cast_row(self, db_session, name="arthur"):
        db_session.expire_all()
        return db_session.query(NovelSeriesCast).filter_by(
            source_id=STUB_SOURCE, series_key=SERIES, normalized_name=name
        ).one_or_none()

    def test_a_non_admin_cannot_pick_the_narrator(
        self, novels_on, db_session, tmp_path, monkeypatch, as_user, make_user
    ):
        install_pack(tmp_path, monkeypatch)
        reader = make_user("reader")

        response = novels_on.post("/novels/narrator", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "voice_id": "libritts-2803",
        }, headers=as_user(reader.id))

        assert response.status_code == 403
        assert response.json()["message"] == self.FORBIDDEN
        assert db_session.get(NovelSeriesCastState, (STUB_SOURCE, SERIES)) is None

    def test_a_non_admin_cannot_recast_a_character(
        self, novels_on, db_session, tmp_path, monkeypatch, as_user, make_user
    ):
        install_pack(tmp_path, monkeypatch)
        reader = make_user("reader")

        response = novels_on.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "name": "Arthur", "voice_id": "libritts-2803",
        }, headers=as_user(reader.id))

        assert response.status_code == 403
        assert response.json()["message"] == self.FORBIDDEN
        assert self._cast_row(db_session) is None

    def test_a_non_admin_cannot_merge_characters(
        self, novels_on, db_session, as_user, make_user
    ):
        from database.models import NovelSeriesAlias

        reader = make_user("reader")
        db_session.add(NovelSeriesCast(
            source_id=STUB_SOURCE, series_key=SERIES,
            display_name="Tessia", normalized_name="tessia",
        ))
        db_session.commit()

        response = novels_on.post("/novels/cast/alias", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "alias": "Arthur", "canonical": "Tessia",
        }, headers=as_user(reader.id))

        assert response.status_code == 403
        assert response.json()["message"] == self.FORBIDDEN
        db_session.expire_all()
        assert db_session.query(NovelSeriesAlias).count() == 0

    def test_the_admin_still_can(
        self, novels_on, db_session, tmp_path, monkeypatch, as_user, make_user
    ):
        install_pack(tmp_path, monkeypatch)
        owner = make_user("owner", is_admin=True)

        response = novels_on.post("/novels/cast", json={
            "source_id": STUB_SOURCE, "series_key": SERIES,
            "name": "Arthur", "voice_id": "libritts-2803",
        }, headers=as_user(owner.id))

        assert response.status_code == 200
        assert self._cast_row(db_session).voice_id == "libritts-2803"

    def test_a_non_admin_can_still_read_the_roster(
        self, novels_on, tmp_path, monkeypatch, as_user, make_user
    ):
        install_pack(tmp_path, monkeypatch)
        reader = make_user("reader")

        body = novels_on.get("/novels/voices", headers=as_user(reader.id)).json()

        assert [v["voice_id"] for v in body["voices"]] == [
            "libritts-2803", "libritts-251"
        ]


class TestFlagOff:
    def test_the_roster_is_a_stock_404_when_novels_are_off(self, novels_off):
        assert novels_off.get("/novels/voices").status_code == 404
