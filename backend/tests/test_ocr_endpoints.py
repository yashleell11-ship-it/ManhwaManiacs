"""HTTP-level tests for ``routes/ocr.py`` (spec §4.4, §7).

All four endpoints end to end: upload a transcript, read it back, list coverage,
and search — every read scoped to the caller's followed series + 18+ gate.

The gate tests lead. ``GET /ocr/chapter`` and ``GET /ocr/coverage`` shipped
taking the ``(source, series, chapter)`` triple straight from the query string
and querying on it alone, so any account on any profile could pull the whole
dialogue transcript of any chapter on any source — including the mature sources
that same profile 404s for everywhere else. The shape tests come after.
"""

from __future__ import annotations

import json

import pytest

import connectors.registry as registry
from connectors.base import SourceConnector
from connectors.models import BrowseMode, Chapter, PaginatedSeriesList, Page, Series
from core import connector_directory
from services.browse_service import get_browse_service
from tests._fakes import FakeBrowse

SRC = "mangadex"
SERIES = "the-max-level-hero"

MATURE_SRC = "stub_mature_ocr"
MATURE_SERIES = "gated-series"

# The series' chapter list as the follow snapshot holds it. An upload is only
# taken for a chapter the server has seen for the series.
KNOWN = json.dumps([{"key": k} for k in ("c1", "c2", "c3")])


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("ocr")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


@pytest.fixture
def h(as_user, acct):
    uid, pid = acct
    return as_user(uid, pid)


@pytest.fixture
def api(app, client, acct):
    app.dependency_overrides[get_browse_service] = lambda: FakeBrowse()
    return client


@pytest.fixture
def follows(seed_follow, acct):
    """The caller's library. Reads are follow-scoped, so without this the
    endpoints correctly answer "nothing here"."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES, known_chapters=KNOWN)


def _upload(api, h, chapter_key, text, engine="mlkit", source_id=SRC, series=SERIES):
    return api.post(
        "/ocr/chapter",
        json={
            "source_id": source_id, "series_key": series, "chapter_key": chapter_key,
            "chapter_number": 1.0, "language": "en", "engine": engine,
            "pages": [{"page": 1, "text": text}],
        },
        headers=h,
    )


# --- the 18+ gate, over the real wiring ----------------------------------


class StubMatureOcrSource(SourceConnector):
    """A MATURE source in the real registry — no network, no fixtures.

    The reads never call it for data; it exists so ``get_browse_service`` has a
    genuinely 18+ source to gate, which is what turns "the OCR route inherits
    the caller's gate" into something a test can observe.
    """

    SOURCE_TYPE = MATURE_SRC
    DISPLAY_NAME = "Stub Mature OCR"
    DESCRIPTION = "Test-only mature source."
    BROWSABLE = True
    SUPPORTS_IMPORT = False
    MATURE = True
    CONTENT_KIND = "manga"

    @property
    def source_type(self) -> str:
        return self.SOURCE_TYPE

    @property
    def display_name(self) -> str:
        return self.DISPLAY_NAME

    def list_browse_modes(self) -> list[BrowseMode]:
        return [BrowseMode(id="default", label="Browse")]

    def get_series_list(self, page: int, *, sort: str | None = None):
        return PaginatedSeriesList(items=[], page=page, page_size=20, total=0)

    def search_series(self, query: str, page: int, *, sort: str | None = None):
        return self.get_series_list(page, sort=sort)

    def get_series(self, series_id: str) -> Series | None:
        return None

    def get_chapters(self, series_id: str) -> list[Chapter]:
        return []

    def get_chapter_pages(self, chapter_id: str) -> list[Page]:
        return []


@pytest.fixture
def mature_source():
    """Put the stub in the REAL registry for one test, and take it back out.

    The registry is process-global, and ``core.connector_directory`` memoizes a
    descriptor index over it keyed on ``(novels_enabled, len(_REGISTRY))``.
    Five other modules register a stub of their own, so every one of them moves
    the registry from N to N+1 and lands on that *same* key: whichever runs
    first builds the index, and the rest are served it — holding a stub they
    never registered and missing the one they did. ``descriptor_for_source``
    then answers ``None`` for their source, which silently switches off rule 3
    of ``resolve_tracker_rating`` (a follow on an 18+ SOURCE is 18+) and
    ``mature_source_ids``, so their gate test passes for the wrong reason.

    Dropping the memo on both edges keeps this fixture's registry mutation from
    outliving it. It is the memo, not the registry, that leaks: ``_REGISTRY``
    and ``_INSTANCE_CACHE`` were already being restored.
    """
    registry.register_connector(MATURE_SRC, StubMatureOcrSource)
    connector_directory.reset_cache()
    yield
    registry._REGISTRY.pop(MATURE_SRC, None)
    registry._INSTANCE_CACHE.pop(MATURE_SRC, None)
    connector_directory.reset_cache()


def test_the_stub_source_is_visible_through_the_connector_directory(mature_source):
    """The gate test below rests on this, so it is asserted rather than assumed.

    ``ensure_visible`` reads the registry directly and would 404 the stub either
    way; the *series* half of the gate reads ``descriptor_for_source``. When a
    stale memo hides the stub, that half stops being exercised and nothing says
    so — the run still comes back green.
    """
    assert connector_directory.descriptor_for_source(MATURE_SRC) is not None
    assert MATURE_SRC in connector_directory.mature_source_ids()


def test_mature_source_transcript_is_gated_per_profile(
    client, as_user, make_user, make_profile, seed_follow, mature_source
):
    """Two profiles of ONE account, both following the same 18+ series.

    Same account, same token, same global ``chapter_ocr`` row — only
    ``X-Profile-Id`` differs. If the route ever resolves its gate from
    ``get_settings()`` instead of the request's profile (the bug that made the
    in-app toggle inert once before), both calls return the transcript.
    """
    user = make_user("ocr-gate")
    adult = make_profile(user.id, "Adult", mature_content_enabled=True)
    kid = make_profile(user.id, "Kid", mature_content_enabled=False, sort_order=1)
    for pid in (adult.id, kid.id):
        seed_follow(
            user.id, pid, source_id=MATURE_SRC, series_key=MATURE_SERIES,
            known_chapters=KNOWN,
        )

    adult_h = as_user(user.id, adult.id)
    assert _upload(
        client, adult_h, "c1", "explicit dialogue",
        source_id=MATURE_SRC, series=MATURE_SERIES,
    ).status_code == 200

    params = {"source": MATURE_SRC, "series": MATURE_SERIES, "chapter": "c1"}
    allowed = client.get("/ocr/chapter", params=params, headers=adult_h)
    assert allowed.status_code == 200, allowed.text
    assert allowed.json()["page_texts"][0]["text"] == "explicit dialogue"

    gated = client.get("/ocr/chapter", params=params, headers=as_user(user.id, kid.id))
    assert gated.status_code == 404, gated.text
    assert gated.json()["code"] == "source_not_found"

    gated_cov = client.get(
        "/ocr/coverage",
        params={"source": MATURE_SRC, "series": MATURE_SERIES},
        headers=as_user(user.id, kid.id),
    )
    assert gated_cov.status_code == 404, gated_cov.text


def test_mature_series_on_a_general_source_is_gated_per_profile(
    api, as_user, make_user, make_profile, seed_follow
):
    """The source gate alone misses an 18+ series on a general source.

    The follow row's own rating has to be resolved too, or ``mangadex`` — which
    no source-level gate ever touches — carries the adult transcript through.
    """
    user = make_user("ocr-series-gate")
    adult = make_profile(user.id, "Adult", mature_content_enabled=True)
    kid = make_profile(user.id, "Kid", mature_content_enabled=False, sort_order=1)
    for pid in (adult.id, kid.id):
        seed_follow(
            user.id, pid, source_id=SRC, series_key=SERIES, mature_override=True,
            known_chapters=KNOWN,
        )

    adult_h = as_user(user.id, adult.id)
    _upload(api, adult_h, "c1", "adult only dialogue")

    params = {"source": SRC, "series": SERIES, "chapter": "c1"}
    assert api.get("/ocr/chapter", params=params, headers=adult_h).status_code == 200

    gated = api.get("/ocr/chapter", params=params, headers=as_user(user.id, kid.id))
    assert gated.status_code == 404, gated.text
    assert (
        api.get(
            "/ocr/coverage",
            params={"source": SRC, "series": SERIES},
            headers=as_user(user.id, kid.id),
        ).json()["chapters"]
        == []
    )


# --- the follow scope ----------------------------------------------------


def test_another_account_cannot_read_the_transcript_by_identity_triple(
    api, h, follows, as_user, make_user, make_profile
):
    """The reported hole, at the wire.

    A second account, on its own profile, following nothing, asking with the
    same three query parameters. It must not be able to tell the difference
    between "not for you" and "nobody has OCR'd this" — 404, never 403.
    """
    _upload(api, h, "c1", "the hero swung his blade")

    other = make_user("stranger")
    other_profile = make_profile(other.id, "Theirs")
    other_h = as_user(other.id, other_profile.id)

    denied = api.get(
        "/ocr/chapter",
        params={"source": SRC, "series": SERIES, "chapter": "c1"},
        headers=other_h,
    )
    assert denied.status_code == 404, denied.text
    assert denied.json()["code"] == "not_found"

    cov = api.get(
        "/ocr/coverage", params={"source": SRC, "series": SERIES}, headers=other_h
    )
    assert cov.status_code == 200
    assert cov.json()["chapters"] == []


def test_a_second_profile_of_the_same_account_is_denied_too(
    api, h, follows, acct, as_user, make_profile
):
    """Only ``X-Profile-Id`` changes; the follow lives on the other profile."""
    uid, _ = acct
    other_profile = make_profile(uid, "Second", sort_order=1)
    _upload(api, h, "c1", "the hero swung his blade")

    denied = api.get(
        "/ocr/chapter",
        params={"source": SRC, "series": SERIES, "chapter": "c1"},
        headers=as_user(uid, other_profile.id),
    )
    assert denied.status_code == 404, denied.text


def test_an_unauthenticated_caller_never_reaches_the_store(api, h, follows):
    """The leak needed an account; the front door is still shut without one."""
    _upload(api, h, "c1", "the hero swung his blade")
    anon = api.get(
        "/ocr/chapter", params={"source": SRC, "series": SERIES, "chapter": "c1"}
    )
    assert anon.status_code == 401, anon.text


# --- the write scope ------------------------------------------------------


def test_a_stranger_cannot_contribute_ocr_for_a_series_it_does_not_follow(
    api, h, follows, as_user, make_user, make_profile
):
    """The reported hole, end to end: the write had NO authorization at all.

    ``require_profile_context`` proves the caller owns the profile it named. It
    says nothing about the series, and ``ingest_chapter`` asked nothing else —
    so with registration open, any account could POST the identity triple of
    any chapter of any series anyone follows and REPLACE the stored transcript
    with up to 2,000,000 characters of its own text. The owner then reads that
    text as the in-reader dialogue overlay and as ``/ocr/search`` results,
    with nothing marking it as not his own scan, and the real transcript is
    gone rather than versioned.

    The asymmetry is what made it easy to miss: the stranger's READ of the very
    row it just wrote was already refused. Reads were scoped per
    ``(user, profile)``; the write was not scoped at all.
    """
    assert _upload(api, h, "c1", "the original scan").status_code == 200

    stranger = make_user("ocr-stranger")
    stranger_profile = make_profile(stranger.id, "Main")
    stranger_h = as_user(stranger.id, stranger_profile.id)

    poisoned = _upload(api, stranger_h, "c1", "attacker supplied dialogue")
    assert poisoned.status_code == 404, poisoned.text
    assert poisoned.json()["code"] == "series_not_found"

    # And the owner's transcript is untouched.
    got = api.get(
        "/ocr/chapter",
        params={"source": SRC, "series": SERIES, "chapter": "c1"},
        headers=h,
    )
    assert got.status_code == 200, got.text
    assert got.json()["page_texts"][0]["text"] == "the original scan"


def test_a_stranger_cannot_mint_a_new_chapter_row_either(
    api, db_session, as_user, make_user, make_profile
):
    """Not just overwrites: creating a row for an unfollowed series is refused
    too, so an account with no library cannot grow the table at all."""
    from database.models import ChapterOcr

    stranger = make_user("ocr-stranger-2")
    stranger_profile = make_profile(stranger.id, "Main")
    stranger_h = as_user(stranger.id, stranger_profile.id)

    made = _upload(api, stranger_h, "brand-new", "unsolicited text")
    assert made.status_code == 404, made.text
    assert (
        db_session.query(ChapterOcr).filter_by(chapter_key="brand-new").count() == 0
    )


# --- shape ---------------------------------------------------------------


def test_upload_get_coverage_roundtrip(api, h, follows):
    up = _upload(api, h, "c1", "the hero swung his blade")
    assert up.status_code == 200, up.text
    assert up.json()["word_count"] == 5

    got = api.get(
        "/ocr/chapter", params={"source": SRC, "series": SERIES, "chapter": "c1"},
        headers=h,
    )
    assert got.status_code == 200, got.text
    assert got.json()["page_texts"][0]["text"] == "the hero swung his blade"

    missing = api.get(
        "/ocr/chapter", params={"source": SRC, "series": SERIES, "chapter": "zzz"},
        headers=h,
    )
    assert missing.status_code == 404

    _upload(api, h, "c3", "another chapter of dialogue")
    cov = api.get(
        "/ocr/coverage", params={"source": SRC, "series": SERIES}, headers=h
    ).json()
    assert {c["chapter_key"] for c in cov["chapters"]} == {"c1", "c3"}


def test_empty_upload_does_not_clobber(api, h, follows):
    _upload(api, h, "c1", "important spoken line")
    _upload(api, h, "c1", "")
    got = api.get(
        "/ocr/chapter", params={"source": SRC, "series": SERIES, "chapter": "c1"},
        headers=h,
    ).json()
    assert got["word_count"] == 3


def test_search_is_scoped_to_followed_series(
    api, h, acct, seed_follow, as_user, make_user, make_profile
):
    """The row is global storage; a search hit still needs the caller's own
    follow. Contributing now needs one too, so the non-follower here has to be
    a second account rather than the uploader before it followed."""
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES, known_chapters=KNOWN)
    _upload(api, h, "c1", "the crimson knight bellowed a challenge")

    other = make_user("ocr-searcher")
    other_profile = make_profile(other.id, "Main")
    other_h = as_user(other.id, other_profile.id)

    # not following yet → no hit
    assert (
        api.get("/ocr/search", params={"q": "crimson"}, headers=other_h).json()["items"]
        == []
    )

    seed_follow(other.id, other_profile.id, source_id=SRC, series_key=SERIES)
    hits = api.get("/ocr/search", params={"q": "crimson"}, headers=other_h).json()
    assert [hit["chapter_key"] for hit in hits["items"]] == ["c1"]
    assert "<mark>" in hits["items"][0]["snippet"]


def test_search_blank_query_is_empty(api, h):
    assert api.get("/ocr/search", params={"q": "   "}, headers=h).json()["items"] == []


# --- the chapter must be one the server has seen ----------------------------


def test_an_invented_chapter_key_is_refused(api, h, follows, db_session):
    """Following is self-service, so the follow gate alone let any account
    follow the owner's series and POST ``<series>:99999`` -- a chapter that
    does not exist -- stuffed with common words. Every follower, the owner
    included, then got search hits and coverage for it. The key is now checked
    against the chapters the server has seen for the series."""
    from database.models import ChapterOcr

    made = _upload(api, h, f"{SERIES}:99999", "the the the hero hero hero")
    assert made.status_code == 404, made.text
    assert made.json()["code"] == "chapter_not_found"
    assert db_session.query(ChapterOcr).count() == 0

    cov = api.get(
        "/ocr/coverage", params={"source": SRC, "series": SERIES}, headers=h
    ).json()
    assert cov["chapters"] == []
    hits = api.get("/ocr/search", params={"q": "hero"}, headers=h).json()
    assert hits["items"] == []


def test_a_chapter_only_the_series_cache_knows_is_accepted(
    api, h, acct, seed_follow, db_session
):
    """The follow snapshot can lag the source (the sweep refreshes it); the
    series' cached chapter list counts too, whatever its TTL."""
    from database.models import SourceSeriesCache

    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=SERIES)  # empty snapshot
    db_session.add(
        SourceSeriesCache(
            source_id=SRC, series_key=SERIES, chapters='[{"key": "fresh-ch"}]'
        )
    )
    db_session.commit()

    assert _upload(api, h, "fresh-ch", "a brand new chapter").status_code == 200
    stale = _upload(api, h, "never-listed", "a chapter nobody listed")
    assert stale.status_code == 404, stale.text
    assert stale.json()["code"] == "chapter_not_found"


def test_a_percent_encoded_key_matches_the_chapter_it_names(
    api, h, acct, seed_follow
):
    """Keys are compared in the fully-unquoted form the row is stored under,
    so a client that sends the key still encoded is not refused."""
    uid, pid = acct
    seed_follow(
        uid, pid, source_id=SRC, series_key=SERIES,
        known_chapters='[{"key": "chapter 1"}]',
    )
    up = _upload(api, h, "chapter%201", "the hero swung")
    assert up.status_code == 200, up.text
    assert up.json()["chapter_key"] == "chapter 1"
