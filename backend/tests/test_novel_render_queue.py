"""The audiobook render queue.

Two properties carry the weight here, and both are about cost rather than
correctness in the ordinary sense.

A chapter is about nine minutes on a GPU shared with a training run, so
queuing the same one twice is not a tidiness problem — it is eighteen minutes
and two writers racing for one file. The guard is a partial unique index, so
it holds against two requests in the same millisecond rather than only against
two a user makes slowly.

And rendering reads the chapter, so a chapter that is not cached would be
fetched live from the source. A two-hundred-chapter queue over cache misses is
a two-hundred-request scrape, which is how this project already lost two
sources.
"""

from __future__ import annotations

import json

from database.models import NovelAudioJob, NovelChapterCache

from tests.test_novels_flag import (  # noqa: F401
    SERIES,
    STUB_SOURCE,
    novels_off,
    novels_on,
    stub_registered,
)


def cache_chapter(db, chapter_key, *, number=1.0, paragraphs=None):
    db.add(
        NovelChapterCache(
            source_id=STUB_SOURCE,
            series_key=SERIES,
            chapter_key=chapter_key,
            title=f"Chapter {number:g}",
            chapter_number=number,
            paragraphs=json.dumps(paragraphs or ["He turned and ran."]),
            word_count=4,
        )
    )
    db.commit()


def ask(client, keys, **over):
    body = {"source_id": STUB_SOURCE, "series_key": SERIES, "chapter_keys": keys}
    body.update(over)
    return client.post("/novels/audio/render", json=body)


class TestEnqueue:
    def test_a_cached_chapter_is_queued(self, novels_on, db_session):
        cache_chapter(db_session, "ch-1")

        body = ask(novels_on, ["ch-1"]).json()

        assert [q["chapter_key"] for q in body["queued"]] == ["ch-1"]
        assert body["skipped"] == []
        row = db_session.query(NovelAudioJob).one()
        assert row.status == "queued"
        # Pinned to the text it was accepted against: a render whose chapter
        # changed underneath produces a timing map pointing at moved words.
        assert row.text_fingerprint

    def test_an_uncached_chapter_is_refused_not_fetched(self, novels_on, db_session):
        # The whole reason the gate exists. Queuing a miss would make the
        # server scrape the source once per chapter.
        body = ask(novels_on, ["never-seen"]).json()

        assert body["queued"] == []
        assert body["skipped"] == [
            {"chapter_key": "never-seen", "reason": "chapter_not_cached"}
        ]
        assert db_session.query(NovelAudioJob).count() == 0

    def test_the_same_chapter_cannot_be_queued_twice(self, novels_on, db_session):
        cache_chapter(db_session, "ch-1")
        ask(novels_on, ["ch-1"])

        body = ask(novels_on, ["ch-1"]).json()

        assert body["queued"] == []
        assert body["skipped"] == [
            {"chapter_key": "ch-1", "reason": "already_queued"}
        ]
        assert db_session.query(NovelAudioJob).count() == 1

    def test_a_chapter_that_already_has_audio_is_skipped(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        from services.chapter_audio_store import chapter_paths

        cache_chapter(db_session, "ch-1")
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
        audio, _ = chapter_paths(STUB_SOURCE, SERIES, "ch-1")
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"OggS")

        body = ask(novels_on, ["ch-1"]).json()

        assert body["skipped"] == [
            {"chapter_key": "ch-1", "reason": "already_rendered"}
        ]

    def test_force_renders_a_chapter_again(
        self, novels_on, db_session, tmp_path, monkeypatch
    ):
        # After a recast or a new narrator the old audio is simply wrong, and
        # without this there was no way to ask for it again: the file check
        # refused before the (deliberately partial) unique index was reached.
        from services.chapter_audio_store import chapter_paths

        cache_chapter(db_session, "ch-1")
        monkeypatch.setenv("MM_AUDIO_DIR", str(tmp_path))
        audio, _ = chapter_paths(STUB_SOURCE, SERIES, "ch-1")
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"OggS")

        body = ask(novels_on, ["ch-1"], force=True).json()

        assert [q["chapter_key"] for q in body["queued"]] == ["ch-1"]
        assert body["skipped"] == []
        db_session.expire_all()
        row = db_session.query(NovelAudioJob).one()
        assert (row.chapter_key, row.status) == ("ch-1", "queued")
        assert row.id == body["queued"][0]["job_id"]
        # The existing audio keeps playing until the new render replaces it.
        assert audio.read_bytes() == b"OggS"

    def test_force_still_cannot_queue_a_chapter_twice(
        self, novels_on, db_session
    ):
        # Force skips the "already has audio" check, not the in-flight one:
        # two renders racing for one file is never what anybody wants.
        cache_chapter(db_session, "ch-1")
        ask(novels_on, ["ch-1"])

        body = ask(novels_on, ["ch-1"], force=True).json()

        assert body["skipped"] == [
            {"chapter_key": "ch-1", "reason": "already_queued"}
        ]
        assert db_session.query(NovelAudioJob).count() == 1

    def test_a_mixed_batch_answers_for_every_chapter(self, novels_on, db_session):
        # Asking for a whole book normally finds some of it already done.
        # Reporting that as a failure would be wrong.
        cache_chapter(db_session, "ch-1")
        cache_chapter(db_session, "ch-2", number=2)

        body = ask(novels_on, ["ch-1", "ch-2", "ch-404"]).json()

        assert {q["chapter_key"] for q in body["queued"]} == {"ch-1", "ch-2"}
        assert [s["chapter_key"] for s in body["skipped"]] == ["ch-404"]

    def test_one_bad_chapter_does_not_lose_the_batch(self, novels_on, db_session):
        # Each job is flushed on its own precisely so a constraint failure is
        # one chapter's problem.
        cache_chapter(db_session, "ch-1")
        ask(novels_on, ["ch-1"])
        cache_chapter(db_session, "ch-2", number=2)

        body = ask(novels_on, ["ch-1", "ch-2"]).json()

        assert [q["chapter_key"] for q in body["queued"]] == ["ch-2"]
        assert [s["reason"] for s in body["skipped"]] == ["already_queued"]

    def test_an_already_queued_chapter_last_does_not_lose_the_ones_before_it(
        self, novels_on, db_session
    ):
        # The order the previous test cannot see. A duplicate that arrives
        # AFTER new chapters used to roll back the whole transaction, taking
        # the new chapters with it while the response still called them queued.
        cache_chapter(db_session, "ch-1")
        ask(novels_on, ["ch-1"])
        cache_chapter(db_session, "ch-2", number=2)
        cache_chapter(db_session, "ch-3", number=3)

        body = ask(novels_on, ["ch-2", "ch-1", "ch-3"]).json()

        assert [q["chapter_key"] for q in body["queued"]] == ["ch-2", "ch-3"]
        assert body["skipped"] == [
            {"chapter_key": "ch-1", "reason": "already_queued"}
        ]
        # The table, not the response, is what a worker will ever render.
        db_session.expire_all()
        rows = {
            row.chapter_key: row.id
            for row in db_session.query(NovelAudioJob).all()
        }
        assert set(rows) == {"ch-1", "ch-2", "ch-3"}
        for queued in body["queued"]:
            assert rows[queued["chapter_key"]] == queued["job_id"]

    def test_a_key_repeated_in_one_request_is_queued_once(
        self, novels_on, db_session
    ):
        # No earlier request needed: the second copy of a key hitting the
        # unique index must not undo the first copy, or anything before it.
        cache_chapter(db_session, "ch-1")
        cache_chapter(db_session, "ch-2", number=2)

        body = ask(novels_on, ["ch-2", "ch-1", "ch-1"]).json()

        assert [q["chapter_key"] for q in body["queued"]] == ["ch-2", "ch-1"]
        assert body["skipped"] == [
            {"chapter_key": "ch-1", "reason": "already_queued"}
        ]
        db_session.expire_all()
        rows = sorted(
            (row.chapter_key, row.status)
            for row in db_session.query(NovelAudioJob).all()
        )
        assert rows == [("ch-1", "queued"), ("ch-2", "queued")]

    def test_the_batch_is_bounded(self, novels_on):
        # Each chapter is ~9 minutes of GPU. A whole long book is a fair ask,
        # but as a deliberate batch rather than one click booking days.
        assert ask(novels_on, [f"ch-{i}" for i in range(201)]).status_code == 422

    def test_an_empty_request_is_refused(self, novels_on):
        assert ask(novels_on, []).status_code == 422


class TestListing:
    def test_jobs_for_a_book_are_listed_with_progress(self, novels_on, db_session):
        cache_chapter(db_session, "ch-1")
        ask(novels_on, ["ch-1"])
        row = db_session.query(NovelAudioJob).one()
        row.segment_count = 200
        row.progress_segments = 50
        row.status = "rendering"
        db_session.commit()

        job = novels_on.get(
            "/novels/audio/jobs",
            params={"source": STUB_SOURCE, "series": SERIES},
        ).json()["jobs"][0]

        assert job["status"] == "rendering"
        # A fraction, because the client draws a bar and a segment count means
        # nothing to a reader.
        assert job["progress"] == 0.25

    def test_progress_is_zero_rather_than_a_divide_by_zero(
        self, novels_on, db_session
    ):
        cache_chapter(db_session, "ch-1")
        ask(novels_on, ["ch-1"])

        job = novels_on.get(
            "/novels/audio/jobs",
            params={"source": STUB_SOURCE, "series": SERIES},
        ).json()["jobs"][0]

        assert job["progress"] == 0.0

    def test_active_jobs_span_every_book(self, novels_on, db_session):
        # Somebody who queued a book and went to read something else still
        # wants to know it is working.
        cache_chapter(db_session, "ch-1")
        ask(novels_on, ["ch-1"])

        body = novels_on.get("/novels/audio/jobs/active").json()

        assert len(body["jobs"]) == 1

    def test_a_finished_job_is_not_active(self, novels_on, db_session):
        cache_chapter(db_session, "ch-1")
        ask(novels_on, ["ch-1"])
        db_session.query(NovelAudioJob).one().status = "done"
        db_session.commit()

        assert novels_on.get("/novels/audio/jobs/active").json()["jobs"] == []


class TestCancel:
    def test_a_queued_job_can_be_cancelled(self, novels_on, db_session):
        cache_chapter(db_session, "ch-1")
        job_id = ask(novels_on, ["ch-1"]).json()["queued"][0]["job_id"]

        assert novels_on.delete(f"/novels/audio/jobs/{job_id}").status_code == 204
        db_session.expire_all()
        assert db_session.get(NovelAudioJob, job_id).status == "cancelled"

    def test_cancelling_frees_the_chapter_to_be_asked_for_again(
        self, novels_on, db_session
    ):
        # The unique index is partial for exactly this: it binds only while a
        # job is in flight.
        cache_chapter(db_session, "ch-1")
        job_id = ask(novels_on, ["ch-1"]).json()["queued"][0]["job_id"]
        novels_on.delete(f"/novels/audio/jobs/{job_id}")

        body = ask(novels_on, ["ch-1"]).json()

        assert [q["chapter_key"] for q in body["queued"]] == ["ch-1"]

    def test_an_unknown_job_is_404(self, novels_on):
        assert novels_on.delete("/novels/audio/jobs/nope").status_code == 404

    def test_a_finished_job_cannot_be_cancelled(self, novels_on, db_session):
        cache_chapter(db_session, "ch-1")
        job_id = ask(novels_on, ["ch-1"]).json()["queued"][0]["job_id"]
        db_session.get(NovelAudioJob, job_id).status = "done"
        db_session.commit()

        assert novels_on.delete(f"/novels/audio/jobs/{job_id}").status_code == 404


class TestOwnerOnly:
    """Jobs have no owner, and the GPU is the owner's.

    Any signed-in account could otherwise book two hundred chapters of card
    time at priority 9 or cancel every job in the instance, since the active
    list hands every job id to every caller. Reading stays open: everybody
    may see what is being narrated.
    """

    def test_a_non_admin_cannot_queue_narration(
        self, novels_on, db_session, as_user, make_user
    ):
        reader = make_user("reader")
        cache_chapter(db_session, "ch-1")

        response = novels_on.post(
            "/novels/audio/render",
            json={"source_id": STUB_SOURCE, "series_key": SERIES,
                  "chapter_keys": ["ch-1"], "priority": 9},
            headers=as_user(reader.id),
        )

        assert response.status_code == 403
        assert response.json()["message"] == "Administrator access required."
        assert db_session.query(NovelAudioJob).count() == 0

    def test_a_non_admin_cannot_cancel_a_job(
        self, novels_on, db_session, as_user, make_user
    ):
        owner = make_user("owner", is_admin=True)
        reader = make_user("reader")
        cache_chapter(db_session, "ch-1")
        job_id = novels_on.post(
            "/novels/audio/render",
            json={"source_id": STUB_SOURCE, "series_key": SERIES,
                  "chapter_keys": ["ch-1"]},
            headers=as_user(owner.id),
        ).json()["queued"][0]["job_id"]

        response = novels_on.delete(
            f"/novels/audio/jobs/{job_id}", headers=as_user(reader.id)
        )

        assert response.status_code == 403
        assert response.json()["message"] == "Administrator access required."
        db_session.expire_all()
        assert db_session.get(NovelAudioJob, job_id).status == "queued"

    def test_a_non_admin_can_still_see_the_jobs(
        self, novels_on, db_session, as_user, make_user
    ):
        owner = make_user("owner", is_admin=True)
        reader = make_user("reader")
        cache_chapter(db_session, "ch-1")
        novels_on.post(
            "/novels/audio/render",
            json={"source_id": STUB_SOURCE, "series_key": SERIES,
                  "chapter_keys": ["ch-1"]},
            headers=as_user(owner.id),
        )

        active = novels_on.get(
            "/novels/audio/jobs/active", headers=as_user(reader.id)
        ).json()["jobs"]

        assert [job["chapter_key"] for job in active] == ["ch-1"]


class TestFlagOff:
    def test_the_queue_is_a_stock_404_when_novels_are_off(self, novels_off):
        assert novels_off.get("/novels/audio/jobs/active").status_code == 404
