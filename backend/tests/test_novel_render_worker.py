"""What the render box talks to.

The box is a machine in a house holding one shared token. Three properties are
worth pinning and none of them is about the happy path:

The token is the ONLY thing in front of these routes — they are mounted
outside the session gate — so "no token configured means not mounted at all"
has to be true, not merely intended.

Two workers must never take the same chapter. The guard is a conditional
UPDATE rather than a Python check, because the second worker is a different
machine and an in-process lock cannot see it.

And a box that simply sleeps mid-render must not wedge that chapter forever.
The lease is a wall clock precisely so a different process, after a restart,
can put the job back.
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from core.config import get_settings
from database.models import NovelAudioJob, NovelChapterCache, NovelChapterAttribution
from database.session import get_db
from main import create_app

from tests.test_novels_flag import (  # noqa: F401
    SERIES,
    STUB_SOURCE,
    stub_registered,
)

TOKEN = "a-render-token"
WORKER = "box-1"


@pytest.fixture
def worker(monkeypatch, session_factory, stub_registered, tmp_path):
    """A client for an app that HAS a render token configured."""
    monkeypatch.setenv("MM_NOVELS_ENABLED", "true")
    monkeypatch.setenv("MM_RENDER_WORKER_TOKEN", TOKEN)
    monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path / "audio"))
    _install_voices(tmp_path / "voices", monkeypatch)
    get_settings.cache_clear()

    def override_get_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    app = create_app(run_migrations=False, run_workers=False)
    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as client:
        yield client
    get_settings.cache_clear()


@pytest.fixture
def tokenless(monkeypatch, session_factory, stub_registered):
    """An app with novels on and NO render token — production's state."""
    monkeypatch.setenv("MM_NOVELS_ENABLED", "true")
    monkeypatch.delenv("MM_RENDER_WORKER_TOKEN", raising=False)
    get_settings.cache_clear()

    def override_get_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    app = create_app(run_migrations=False, run_workers=False)
    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as client:
        yield client
    get_settings.cache_clear()


def _install_voices(root, monkeypatch):
    """A pack on disk. A chapter cannot be cast without one."""
    from services import voice_pack

    root.mkdir(parents=True, exist_ok=True)
    clips = []
    for index, (gender, pitch) in enumerate(
        [("male", 120.0), ("male", 140.0), ("female", 200.0)]
    ):
        name = f"v{index}.opus"
        (root / name).write_bytes(b"OggS")
        clips.append({
            "voice_id": f"v{index}", "name": f"Voice{index}", "gender": gender,
            "median_f0_hz": pitch, "pitch_spread": 0.15 + index * 0.05,
            "seconds": 8.0, "license": "CC BY 4.0", "attribution": "test",
            "transcript": "x", "sample": name,
        })
    (root / "manifest.json").write_text(
        json.dumps({"version": "test", "clips": clips}), encoding="utf-8"
    )
    monkeypatch.setenv("MM_VOICES_DIR", str(root))
    voice_pack._cached.cache_clear()


def seed(db, chapter_key="ch-1", *, attributed=True):
    paragraphs = ['"Then we go," he said.', "He turned and ran."]
    db.add(
        NovelChapterCache(
            source_id=STUB_SOURCE, series_key=SERIES, chapter_key=chapter_key,
            title="Chapter 1", chapter_number=1.0,
            paragraphs=json.dumps(paragraphs), word_count=8,
        )
    )
    if attributed:
        db.add(
            NovelChapterAttribution(
                source_id=STUB_SOURCE, series_key=SERIES, chapter_key=chapter_key,
                text_fingerprint="fp", paragraph_count=len(paragraphs),
                style="quoted",
                spans=json.dumps([
                    {"p": 0, "s": 1, "e": 12, "ord": 0, "head": "Then we go,",
                     "cont": False, "speaker": "Arthur", "rule": 1},
                ]),
                pov=json.dumps(["Arthur"]),
                pronoun_counts=json.dumps({"arthur": {"he": 9, "she": 0}}),
                status="ok", model="test",
            )
        )
    db.commit()


def queue(client, chapter_key="ch-1"):
    return client.post("/novels/audio/render", json={
        "source_id": STUB_SOURCE, "series_key": SERIES,
        "chapter_keys": [chapter_key],
    })


class TestMounting:
    def test_with_no_token_the_routes_do_not_exist(self, tokenless):
        # Not 401 — 404. A render endpoint that exists and refuses is an
        # invitation to guess at; one that was never mounted is
        # indistinguishable from a feature that was never built.
        response = tokenless.post("/novels/render/claim", json={"worker_id": WORKER})

        assert response.status_code == 404

    def test_the_wrong_token_is_refused(self, worker):
        response = worker.post(
            "/novels/render/claim",
            json={"worker_id": WORKER},
            headers={"X-Render-Token": "not-it"},
        )

        assert response.status_code == 401

    def test_no_token_header_is_refused(self, worker):
        assert worker.post(
            "/novels/render/claim", json={"worker_id": WORKER}
        ).status_code == 401


class TestClaim:
    def test_an_empty_queue_is_204_not_an_error(self, worker):
        # The box polls forever. "Nothing to do" is the ordinary answer and
        # must not look like a failure in its logs.
        response = worker.post(
            "/novels/render/claim", json={"worker_id": WORKER},
            headers={"X-Render-Token": TOKEN},
        )

        assert response.status_code == 204

    def test_a_claim_returns_a_frozen_plan(self, worker, db_session):
        # The box holds no database and makes no casting decisions. It renders
        # exactly the segments it is handed.
        seed(db_session)
        queue(worker)

        body = worker.post(
            "/novels/render/claim", json={"worker_id": WORKER},
            headers={"X-Render-Token": TOKEN},
        ).json()

        assert body["chapter_key"] == "ch-1"
        assert body["plan"]["segments"]
        assert body["plan"]["narrator_voice"]
        # The identity triple travels WITH the plan, so a render can never be
        # written under the wrong key.
        assert body["plan"]["source_id"] == STUB_SOURCE
        assert body["plan_hash"]

    def test_two_workers_cannot_take_the_same_chapter(self, worker, db_session):
        # A conditional UPDATE, not a Python check: the second worker is a
        # different machine and an in-process lock cannot see it.
        seed(db_session)
        queue(worker)

        first = worker.post(
            "/novels/render/claim", json={"worker_id": "box-1"},
            headers={"X-Render-Token": TOKEN},
        )
        second = worker.post(
            "/novels/render/claim", json={"worker_id": "box-2"},
            headers={"X-Render-Token": TOKEN},
        )

        assert first.status_code == 200
        assert second.status_code == 204

    def test_an_unattributed_chapter_is_failed_not_held(self, worker, db_session):
        # The worker cannot fix a missing attribution, so the job must not sit
        # on a lease waiting for something that will never happen.
        seed(db_session, attributed=False)
        queue(worker)

        response = worker.post(
            "/novels/render/claim", json={"worker_id": WORKER},
            headers={"X-Render-Token": TOKEN},
        )

        assert response.status_code == 204
        db_session.expire_all()
        job = db_session.query(NovelAudioJob).one()
        assert job.status == "failed"
        assert job.error_code == "not_attributed"


class TestPinnedVoices:
    """A cleared pin must plan exactly like a character nobody ever pinned.

    The clients label that option "Automatic voice", so the render has to
    agree: the character gets whatever the automatic pass gives them, not the
    old pin and not the narrator.
    """

    PARAGRAPHS = ['"Then we go," she said.', "He turned and ran."]

    def _seed(self, db):
        from services.novel_attribution_service import chapter_fingerprint

        db.add(
            NovelChapterCache(
                source_id=STUB_SOURCE, series_key=SERIES, chapter_key="ch-1",
                title="Chapter 1", chapter_number=1.0,
                paragraphs=json.dumps(self.PARAGRAPHS), word_count=8,
            )
        )
        db.add(
            NovelChapterAttribution(
                source_id=STUB_SOURCE, series_key=SERIES, chapter_key="ch-1",
                text_fingerprint=chapter_fingerprint(self.PARAGRAPHS),
                paragraph_count=len(self.PARAGRAPHS), style="quoted",
                spans=json.dumps([
                    {"p": 0, "s": 1, "e": 12, "ord": 0, "head": "Then we go,",
                     "cont": False, "speaker": "Tessia", "rule": 1},
                ]),
                pov=json.dumps(["Arthur"]),
                pronoun_counts=json.dumps({"arthur": [9, 0], "tessia": [0, 9]}),
                status="ok", model="test",
            )
        )
        db.commit()

    def _tessia_voice(self, db):
        from services.novel_render_plan import build_chapter_plan

        plan = build_chapter_plan(
            db, STUB_SOURCE, SERIES, "ch-1", list(self.PARAGRAPHS)
        )
        return next(s["voice"] for s in plan["segments"] if s["speech"])

    def test_clearing_a_pin_gives_back_the_automatic_voice(
        self, db_session, tmp_path, monkeypatch
    ):
        from services.novel_attribution_service import correct_cast_member

        _install_voices(tmp_path / "voices", monkeypatch)
        self._seed(db_session)
        automatic = self._tessia_voice(db_session)

        correct_cast_member(db_session, STUB_SOURCE, SERIES, "Tessia",
                            voice_id="v1")
        assert self._tessia_voice(db_session) == "v1"

        correct_cast_member(db_session, STUB_SOURCE, SERIES, "Tessia",
                            voice_id=None)

        # The row stays locked (a gender correction does that too), and a
        # locked row with no voice is still an unpinned character.
        assert automatic == "v2"
        assert self._tessia_voice(db_session) == automatic


class TestHeartbeat:
    def _claim(self, worker, db_session):
        seed(db_session)
        queue(worker)
        return worker.post(
            "/novels/render/claim", json={"worker_id": WORKER},
            headers={"X-Render-Token": TOKEN},
        ).json()["job_id"]

    def test_a_heartbeat_records_progress(self, worker, db_session):
        job_id = self._claim(worker, db_session)

        body = worker.post(
            "/novels/render/heartbeat",
            json={"job_id": job_id, "worker_id": WORKER, "segments_done": 3},
            headers={"X-Render-Token": TOKEN},
        ).json()

        assert body["cancelled"] is False
        db_session.expire_all()
        assert db_session.get(NovelAudioJob, job_id).progress_segments == 3

    def test_a_cancelled_job_tells_the_worker_to_stop(self, worker, db_session):
        # The only way a cancel reaches a machine behind a home NAT.
        job_id = self._claim(worker, db_session)
        worker.delete(f"/novels/audio/jobs/{job_id}")

        body = worker.post(
            "/novels/render/heartbeat",
            json={"job_id": job_id, "worker_id": WORKER, "segments_done": 5},
            headers={"X-Render-Token": TOKEN},
        ).json()

        assert body["cancelled"] is True

    def test_another_worker_cannot_heartbeat_somebody_elses_job(
        self, worker, db_session
    ):
        job_id = self._claim(worker, db_session)

        response = worker.post(
            "/novels/render/heartbeat",
            json={"job_id": job_id, "worker_id": "impostor", "segments_done": 1},
            headers={"X-Render-Token": TOKEN},
        )

        assert response.status_code == 409


class TestCompleteAndFail:
    def _claim(self, worker, db_session):
        seed(db_session)
        queue(worker)
        return worker.post(
            "/novels/render/claim", json={"worker_id": WORKER},
            headers={"X-Render-Token": TOKEN},
        ).json()["job_id"]

    def test_an_upload_lands_and_is_immediately_playable(self, worker, db_session):
        from services.chapter_audio_store import read_chapter_audio

        job_id = self._claim(worker, db_session)

        response = worker.post(
            "/novels/render/complete",
            data={"job_id": job_id, "worker_id": WORKER},
            files={
                "audio": ("c.opus", b"OggS" + b"\0" * 400, "audio/ogg"),
                "timing": (
                    "c.timing.json",
                    json.dumps({"total_ms": 1234, "segments": []}).encode(),
                    "application/json",
                ),
            },
            headers={"X-Render-Token": TOKEN},
        )

        assert response.status_code == 200
        db_session.expire_all()
        assert db_session.get(NovelAudioJob, job_id).status == "done"
        found = read_chapter_audio(STUB_SOURCE, SERIES, "ch-1")
        assert found.available is True
        assert found.total_ms == 1234

    def test_no_tmp_files_are_left_behind(self, worker, db_session, tmp_path):
        job_id = self._claim(worker, db_session)
        worker.post(
            "/novels/render/complete",
            data={"job_id": job_id, "worker_id": WORKER},
            files={
                "audio": ("c.opus", b"OggS", "audio/ogg"),
                "timing": ("c.timing.json", b"{}", "application/json"),
            },
            headers={"X-Render-Token": TOKEN},
        )

        leftovers = list((tmp_path / "audio").rglob("*.tmp"))
        assert leftovers == []

    def test_a_retryable_failure_goes_back_in_the_queue(self, worker, db_session):
        # A dropped connection should be tried again; that is the whole
        # distinction this flag carries.
        job_id = self._claim(worker, db_session)

        worker.post(
            "/novels/render/fail",
            json={"job_id": job_id, "worker_id": WORKER, "code": "net",
                  "detail": "connection reset", "retryable": True},
            headers={"X-Render-Token": TOKEN},
        )

        db_session.expire_all()
        assert db_session.get(NovelAudioJob, job_id).status == "queued"

    def test_an_unretryable_failure_stops(self, worker, db_session):
        job_id = self._claim(worker, db_session)

        worker.post(
            "/novels/render/fail",
            json={"job_id": job_id, "worker_id": WORKER, "code": "bad_text",
                  "detail": "nothing to say", "retryable": False},
            headers={"X-Render-Token": TOKEN},
        )

        db_session.expire_all()
        assert db_session.get(NovelAudioJob, job_id).status == "failed"

    def test_releasing_does_not_charge_an_attempt(self, worker, db_session):
        # The GPU was wanted by a training run. Charging an attempt would mean
        # three of those permanently exhaust a chapter's retries.
        job_id = self._claim(worker, db_session)
        db_session.expire_all()
        before = db_session.get(NovelAudioJob, job_id).attempts

        worker.post(
            "/novels/render/release",
            json={"job_id": job_id, "worker_id": WORKER, "reason": "gpu busy"},
            headers={"X-Render-Token": TOKEN},
        )

        db_session.expire_all()
        job = db_session.get(NovelAudioJob, job_id)
        assert job.status == "queued"
        assert job.attempts == before - 1


class TestLeaseReaping:
    def test_a_job_whose_box_went_away_is_requeued(self, worker, db_session):
        # Without this a box that slept mid-render wedges the chapter forever:
        # the row says rendering and nobody will ever claim it again.
        from datetime import timedelta

        from database.models import utcnow
        from services.novel_render_queue import reap_expired

        seed(db_session)
        queue(worker)
        worker.post(
            "/novels/render/claim", json={"worker_id": WORKER},
            headers={"X-Render-Token": TOKEN},
        )
        db_session.expire_all()
        job = db_session.query(NovelAudioJob).one()
        job.lease_until = utcnow() - timedelta(minutes=1)
        db_session.commit()

        assert reap_expired(db_session) == 1
        db_session.commit()

        db_session.expire_all()
        assert db_session.query(NovelAudioJob).one().status == "queued"

    def test_a_live_lease_is_left_alone(self, worker, db_session):
        from services.novel_render_queue import reap_expired

        seed(db_session)
        queue(worker)
        worker.post(
            "/novels/render/claim", json={"worker_id": WORKER},
            headers={"X-Render-Token": TOKEN},
        )

        assert reap_expired(db_session) == 0
