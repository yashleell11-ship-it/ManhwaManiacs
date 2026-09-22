"""One series, one profile, every gated read surface — they must agree.

The 18+ gate over stored rows was closed one surface at a time, by three
separate changes: ``update_service`` (notifications), ``progress_service``
(``/reader/progress/series`` + ``/reader/history``), ``source_cache_service``
(the series cache), on top of ``bookmark_service`` and ``ocr_ingest_service``
before them. Each shipped with its own test file, and each of those files
proves only that *its own* surface hides the series.

That is the gap this file covers. Nothing pinned that the surfaces agree with
each other, and they resolve the rating through three different mechanisms —
a SQL ``_mature_case`` mirror (history, bookmarks, notifications), a Python
``resolve_tracker_rating`` call (``progress/series``), and
``BrowseService.ensure_visible`` (the source-level check). Three mirrors of one
rule drift silently: a change to any one of them keeps every existing file
green while the screens start disagreeing about what is adult, which is exactly
the inconsistency the gate existed to remove — hidden in browse, listed in
history.

So these assert the whole surface at once, through the router, with the profile
as the only variable:

  * a shut gate hides the series **everywhere** (not on three of four screens);
  * an open gate shows it **everywhere** — the regression that "fixing" a leak
    by breaking the feature would produce, and the one no denial test can catch;
  * a shut gate hides nothing that is not adult.

"Everywhere" is meant literally, and it is the second thing this file exists
for. It first walked five surfaces, which is how ``/library/series``,
``/library/search``, the collection routes and the OCR reads each shipped
ungated and were each found separately afterwards: the gate is applied per
service method, so a route reaching the same tables through a new method is
ungated by default and every existing test stays green. The walk is therefore
over ROUTES, in three parts — the stored-row reads (one series, rated by its
follow row), the source-scoped reads (a whole source that is adult by nature),
and a last test asserting the walk covers every GET the app serves or names,
with a reason, the ones that cannot carry series-derived data at all.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

import connectors.registry as registry
from connectors.base import SourceConnector
from connectors.models import BrowseMode, PaginatedSeriesList, Series as ConnectorSeries
import core.connector_directory as connector_directory
from core.connector_directory import mature_source_ids
from core.time_utils import utcnow
from database.models import (
    ChapterOcr,
    Collection,
    CollectionSeries,
    SourcePin,
    SourceSeriesCache,
    UpdateNotification,
)

SRC = "mangadex"
ADULT = "an-adult-series"
SAFE = "a-safe-series"

#: Markers for the surfaces that answer about a chapter or a genre rather than
#: naming the series: the OCR routes echo ``series_key`` even when they deny
#: (``coverage`` returns the key with an empty chapter list), and
#: ``/library/recommendations`` returns genres and no series at all.
ADULT_CHAPTER = "adult-only-chapter"
SAFE_CHAPTER = "safe-only-chapter"
ADULT_GENRE = "adultonlygenre"
SAFE_GENRE = "safeonlygenre"


@pytest.fixture
def household(make_user, make_profile):
    """One account, two profiles. The gate is the only difference between them.

    Two profiles of the same account is the shape that matters: anything that
    resolves its gate from ``get_settings()`` rather than from the request's
    profile answers identically for both, and every assertion below would pass
    for the wrong reason.
    """
    user = make_user("household")
    return {
        "uid": user.id,
        "kid": make_profile(user.id, "Kid", mature_content_enabled=False).id,
        "grown": make_profile(
            user.id, "Grown", mature_content_enabled=True, sort_order=1
        ).id,
    }


@pytest.fixture
def seeded(db_session, household, seed_follow, seed_progress, seed_bookmark):
    """The identical two series under both profiles, on every gated surface.

    ``mature_override`` on a ``mangadex`` follow deliberately: a general source
    no source-level check ever touches, so the follow row's own rating is the
    only signal there is and every surface has to resolve it the same way.

    Returns the per-profile row ids the id-addressed routes need. The two
    profiles hold *separate* follow rows for the same series, so a test that
    reused one profile's id against the other would be asking a different
    question than the one it looks like it is asking.
    """
    ids: dict[str, dict[str, int]] = {"kid": {}, "grown": {}}
    for name in ("kid", "grown"):
        pid = household[name]
        for series_key, adult in ((ADULT, True), (SAFE, False)):
            follow = seed_follow(
                household["uid"], pid, source_id=SRC, series_key=series_key,
                mature_override=adult,
                # ``/library/recently-updated`` only lists rows a sweep has
                # touched; without this it is empty for both profiles and
                # would agree with itself for the wrong reason.
                last_checked_at=utcnow(),
            )
            ids[name][series_key] = follow.id
            seed_progress(
                household["uid"], pid, source_id=SRC, series_key=series_key,
                chapter_key="c1",
            )
            seed_bookmark(
                household["uid"], pid, source_id=SRC, series_key=series_key,
                chapter_key="c1",
            )
            db_session.add(
                UpdateNotification(
                    user_id=household["uid"],
                    profile_id=pid,
                    followed_series_id=follow.id,
                    source_id=SRC,
                    series_key=series_key,
                    chapter_key="c1",
                    chapter_title="Chapter 1",
                    chapter_number=1.0,
                    is_read=False,
                )
            )
    # Global rows, one per series rather than per profile: the OCR transcript
    # and the metadata cache belong to the series, and the gate is the only
    # thing standing between a profile and another profile's contribution.
    for series_key, chapter_key, genre in (
        (ADULT, ADULT_CHAPTER, ADULT_GENRE),
        (SAFE, SAFE_CHAPTER, SAFE_GENRE),
    ):
        db_session.add(
            ChapterOcr(
                source_id=SRC,
                series_key=series_key,
                chapter_key=chapter_key,
                full_text="dialogue",
                page_texts='[{"page": 1, "text": "dialogue"}]',
                engine="test",
                word_count=1,
            )
        )
        db_session.add(
            SourceSeriesCache(
                source_id=SRC,
                series_key=series_key,
                title=series_key,
                genres=f'["{genre}"]',
            )
        )
    db_session.commit()
    return ids


def _surfaces(client, headers) -> dict[str, object]:
    """Every gated read of a stored row, as the client actually calls them."""
    return {
        "progress/series": [
            r["chapter_key"]
            for r in client.get(
                "/reader/progress/series",
                params={"source": SRC, "series": ADULT},
                headers=headers,
            ).json()
        ],
        "history": sorted(
            r["series_key"]
            for r in client.get("/reader/history", headers=headers).json()
        ),
        "bookmarks": sorted(
            r["series_key"]
            for r in client.get("/reader/bookmarks", headers=headers).json()
        ),
        "notifications": sorted(
            n["series_key"]
            for n in client.get("/updates/notifications", headers=headers).json()
        ),
        "badge": client.get(
            "/updates/notifications/unread-count", headers=headers
        ).json()["count"],
    }


def test_a_shut_gate_hides_the_same_series_on_every_surface(
    client, as_user, household, seeded
):
    """Hidden in browse means hidden in *all* of the profile's own records.

    A gate that holds on three screens and not the fourth is what the original
    defect was; asserting the surfaces together is what keeps the three separate
    mirrors of the rating rule from drifting apart one commit at a time.
    """
    got = _surfaces(client, as_user(household["uid"], household["kid"]))

    assert got["progress/series"] == []
    assert got["history"] == [SAFE]
    assert got["bookmarks"] == [SAFE]
    assert got["notifications"] == [SAFE]
    # The badge has to count exactly the listing, or the client shows an unread
    # number for something it can never open and that never falls.
    assert got["badge"] == 1


def test_an_open_gate_shows_the_same_series_on_every_surface(
    client, as_user, household, seeded
):
    """The ordinary case, which no denial test can catch.

    Same account, same rows, same tokens — only ``X-Profile-Id`` differs. It is
    easy to close a leak by breaking the feature, and a profile that opted in to
    adult content must still get its own reading position, history, bookmarks
    and new-chapter notifications for a mature series.
    """
    got = _surfaces(client, as_user(household["uid"], household["grown"]))

    both = sorted([ADULT, SAFE])
    assert got["progress/series"] == ["c1"]
    assert got["history"] == both
    assert got["bookmarks"] == both
    assert got["notifications"] == both
    assert got["badge"] == 2


def test_the_history_total_header_counts_what_the_body_returns(
    client, as_user, household, seeded
):
    """The count the client is handed is the count of what it was handed.

    ``/reader/history`` reports the page's own cardinality, so this is not a
    claim about a table total. It pins the header to the *gated* page: the gate
    lives inside the query, and a filter moved out of SQL to a pass over the
    rows afterwards would keep the body correct while the header went on
    reporting the ungated count.
    """
    for profile, expected in (("kid", 1), ("grown", 2)):
        resp = client.get(
            "/reader/history", headers=as_user(household["uid"], household[profile])
        )
        assert len(resp.json()) == expected
        assert resp.headers["X-Total-Count"] == str(expected)


@pytest.fixture
def collections(db_session, household):
    """One collection per profile, both holding both series.

    Collections were the surface the gate never reached: membership rows carry
    no rating, so ``get_collection`` printed ``(source_id, series_key)`` for a
    series every other screen here hides — the "hidden in browse, listed in
    history" failure this file exists to prevent, one route later.
    """
    ids = {}
    for profile in ("kid", "grown"):
        row = Collection(
            user_id=household["uid"], profile_id=household[profile], name="Mixed"
        )
        db_session.add(row)
        db_session.commit()
        db_session.refresh(row)
        for order, series_key in enumerate((SAFE, ADULT)):
            db_session.add(
                CollectionSeries(
                    collection_id=row.id,
                    source_id=SRC,
                    series_key=series_key,
                    sort_order=order,
                )
            )
        ids[profile] = row.id
    db_session.commit()
    return ids


@pytest.mark.parametrize(
    "profile, expected", [("kid", [SAFE]), ("grown", sorted([ADULT, SAFE]))]
)
def test_a_collection_lists_what_the_other_surfaces_list(
    client, as_user, household, seeded, collections, profile, expected
):
    """Both directions, like every other surface above: shut hides, open shows."""
    headers = as_user(household["uid"], household[profile])

    detail = client.get(
        f"/library/collections/{collections[profile]}", headers=headers
    ).json()

    assert sorted(s["series_key"] for s in detail["series"]) == expected


@pytest.mark.parametrize("profile, expected", [("kid", 1), ("grown", 2)])
def test_the_collection_count_equals_what_the_collection_lists(
    client, as_user, household, seeded, collections, profile, expected
):
    """The listing's badge and the detail's own count are the gated membership.

    A count taken beside the gate rather than through it is the same
    disclosure in miniature: a profile told its collection holds two series and
    shown one knows exactly how many are being withheld.
    """
    headers = as_user(household["uid"], household[profile])

    listed = client.get("/library/collections", headers=headers).json()
    detail = client.get(
        f"/library/collections/{collections[profile]}", headers=headers
    ).json()

    assert [c["series_count"] for c in listed] == [expected]
    assert detail["series_count"] == expected


# ---------------------------------------------------------------------------
# Every read route, not five of them
# ---------------------------------------------------------------------------
#
# The surfaces above were the ones that had already leaked. The failure mode
# that is left is a route nobody thought of: the gate is applied per service
# method, so a new endpoint reaching the same tables through a new method is
# ungated by default and every existing test stays green. ``/library/series``,
# ``/library/continue-reading``, ``/library/search``, the OCR reads and the
# collection routes each arrived that way.
#
# So the walk below is over ROUTES rather than over services, and the last test
# in this file asserts the walk is exhaustive: every GET the app serves is
# either exercised here or named, with a reason, as one that cannot carry
# series-derived data. A new route is a failing test until somebody classifies
# it.


def _adult_marker_reads(ids: dict[str, int]) -> list[tuple[str, object]]:
    """(openapi path, request) for every read that must name the adult series.

    Keyed by the OpenAPI path so the completeness test can subtract this list
    from the app's own route table; the callable is how a client actually
    reaches it.
    """
    return [
        ("/library/series", lambda c, h: c.get("/library/series", headers=h)),
        (
            "/library/series/{followed_id}",
            lambda c, h: c.get(f"/library/series/{ids[ADULT]}", headers=h),
        ),
        (
            "/library/continue-reading",
            lambda c, h: c.get("/library/continue-reading", headers=h),
        ),
        (
            "/library/recently-updated",
            lambda c, h: c.get("/library/recently-updated", headers=h),
        ),
        (
            "/library/search",
            lambda c, h: c.get("/library/search", params={"q": "series"}, headers=h),
        ),
        ("/reader/history", lambda c, h: c.get("/reader/history", headers=h)),
        ("/reader/bookmarks", lambda c, h: c.get("/reader/bookmarks", headers=h)),
        (
            "/updates/notifications",
            lambda c, h: c.get("/updates/notifications", headers=h),
        ),
    ]


def _adult_chapter_reads() -> list[tuple[str, object]]:
    """The OCR reads, which must name the adult series' CHAPTER.

    ``/ocr/coverage`` echoes the ``series_key`` it was asked about even while
    denying, so the series key cannot be the marker here; the chapter key only
    appears when the transcript itself is being handed over.
    """
    return [
        (
            "/ocr/search",
            lambda c, h: c.get("/ocr/search", params={"q": "dialogue"}, headers=h),
        ),
        (
            "/ocr/coverage",
            lambda c, h: c.get(
                "/ocr/coverage", params={"source": SRC, "series": ADULT}, headers=h
            ),
        ),
        (
            "/ocr/chapter",
            lambda c, h: c.get(
                "/ocr/chapter",
                params={"source": SRC, "series": ADULT, "chapter": ADULT_CHAPTER},
                headers=h,
            ),
        ),
    ]


#: Stand-in ids for the two callers that read only the PATHS out of the tables
#: above (parametrisation and the completeness check). The real ids come from
#: the ``seeded`` fixture, which is per-test and so cannot be reached here.
_PATHS_ONLY = {ADULT: 0}


def _read_route_cases():
    """Every (path, marker) pair the two parametrised tests below share."""
    return [(path, ADULT) for path, _ in _adult_marker_reads(_PATHS_ONLY)] + [
        (path, ADULT_CHAPTER) for path, _ in _adult_chapter_reads()
    ]


def _request_for(path: str, ids: dict[str, int]):
    lookup = dict(_adult_marker_reads(ids) + _adult_chapter_reads())
    return lookup[path]


@pytest.mark.parametrize(
    "path, marker", _read_route_cases(), ids=[p for p, _ in _read_route_cases()]
)
def test_no_read_route_prints_the_adult_series_to_a_shut_gate(
    client, as_user, household, seeded, path, marker
):
    """Whatever the route, the adult series is not in the bytes.

    Asserted against the raw response text rather than a parsed field: a leak
    is a leak wherever in the payload it lands, and a route that starts
    embedding the key somewhere new (an ``href``, an ``X-`` header echo, an
    error message naming what was not found) is caught without this file
    having to know the payload's shape.
    """
    resp = _request_for(path, seeded["kid"])(
        client, as_user(household["uid"], household["kid"])
    )

    assert marker not in resp.text, resp.text


@pytest.mark.parametrize(
    "path, marker", _read_route_cases(), ids=[p for p, _ in _read_route_cases()]
)
def test_every_read_route_still_serves_an_open_gate(
    client, as_user, household, seeded, path, marker
):
    """The other half, and the one the denial test cannot give.

    Without it, deleting the route's body passes the test above. This is also
    what proves each route really does reach the adult series at all -- a
    request that returns nothing for BOTH profiles hides it vacuously.
    """
    resp = _request_for(path, seeded["grown"])(
        client, as_user(household["uid"], household["grown"])
    )

    assert resp.status_code == 200, resp.text
    assert marker in resp.text, resp.text


def test_recommendations_are_built_only_from_series_the_profile_may_see(
    client, as_user, household, seeded
):
    """Genres, not series keys -- and the leak is the genre.

    ``/library/recommendations`` returns a genre histogram over the followed
    set, so an ungated version discloses that the account follows something
    tagged ``adultonlygenre`` without ever printing a series key. It is the
    one route here whose payload cannot carry the marker the others do.
    """
    def _genres(profile: str) -> set[str]:
        return {
            row["genre"]
            for row in client.get(
                "/library/recommendations",
                headers=as_user(household["uid"], household[profile]),
            ).json()
        }

    assert _genres("kid") == {SAFE_GENRE}
    assert _genres("grown") == {SAFE_GENRE, ADULT_GENRE}


@pytest.mark.parametrize("profile, expected", [("kid", 1), ("grown", 2)])
def test_statistics_counts_only_what_the_profile_may_see(
    client, as_user, household, seeded, profile, expected
):
    """A count is a disclosure too.

    ``/library/statistics`` names no series, so the marker sweep above cannot
    speak for it; a profile told it follows two series and shown one knows
    exactly how much is being withheld.
    """
    payload = client.get(
        "/library/statistics", headers=as_user(household["uid"], household[profile])
    ).json()

    assert payload["followed_total"] == expected


def test_tags_carry_no_series_identity_at_all(client, as_user, household, seeded):
    """The route in the walk that is gated by carrying nothing to gate.

    ``profile_series_tags`` maps series to tags, and no GET exposes that
    mapping today -- ``/library/tags`` returns the tag rows alone. Pinning the
    payload's shape is what turns "there is nothing to hide here" from an
    assumption into an assertion: the day a ``series`` list or a count is added
    to it, this fails and somebody has to gate it.
    """
    client.post(
        "/library/tags",
        json={"name": "Favourites"},
        headers=as_user(household["uid"], household["grown"]),
    )

    rows = client.get(
        "/library/tags", headers=as_user(household["uid"], household["grown"])
    ).json()

    assert rows, "the fixture must actually create a tag or this passes empty"
    assert all(
        set(row) == {"id", "name", "category", "color"} for row in rows
    ), rows


# ---------------------------------------------------------------------------
# The other gate: a source that is adult by nature
# ---------------------------------------------------------------------------
#
# Everything above gates ONE SERIES on a general source. The routes that name a
# source and no stored row -- browse, detail, chapters, pages, covers, the
# reader -- cannot be reached that way: they resolve their connector through
# ``BrowseService._get_connector`` and are gated by ``SourceConnector.MATURE``
# instead. Same file, because it is the same question asked of the same profile
# ("what may this reader see?") and the two halves have to answer it together;
# the audit's finding was that this file walked five routes out of thirty.
#
# Denial is 404 ``source_not_found`` everywhere, never 403 and never a distinct
# code: an adult source's *existence* is the disclosure.

MATURE_SRC = "stub_mature_cross_surface"


class _StubMatureSource(SourceConnector):
    """An 18+ source that answers every read without touching the network.

    Registered into the real registry rather than patched into the service, so
    the routes below resolve it exactly as they resolve a shipped connector --
    including ``core.connector_directory``, whose memo is keyed on the registry
    size and so rebuilds itself around this.
    """

    SOURCE_TYPE = MATURE_SRC
    DISPLAY_NAME = "Stub Mature Cross Surface"
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

    def list_browse_modes(self):
        return [BrowseMode(id="default", label="Browse")]

    def list_genres(self):
        return [BrowseMode(id="all", label="All")]

    def get_series_list(self, page, *, sort=None):
        return PaginatedSeriesList(
            items=[ConnectorSeries(id="s1", title="Stub Series")],
            page=page,
            page_size=20,
            total=1,
        )

    def search_series(self, query, page, *, sort=None):
        return self.get_series_list(page, sort=sort)

    def get_series(self, series_id):
        return ConnectorSeries(id=series_id, title="Stub Series")

    def get_chapters(self, series_id):
        return []

    def get_chapter_pages(self, chapter_id):
        return []

    def find_page(self, page_id):
        # Overridden because the base class refuses to guess (its default
        # traversal is O(series x chapters x pages) per proxied image). None
        # is "no such page", which is the answer that is NOT the gate's.
        return None


@pytest.fixture
def mature_source():
    registry.register_connector(MATURE_SRC, _StubMatureSource)
    # ``connector_directory``'s memo is keyed on ``len(_REGISTRY)``, so a
    # registry of the same SIZE is a cache hit: without these resets the next
    # file to register its own one stub is served this file's index instead,
    # and its adult source silently stops being adult.
    connector_directory.reset_cache()
    yield MATURE_SRC
    registry._REGISTRY.pop(MATURE_SRC, None)
    registry._INSTANCE_CACHE.pop(MATURE_SRC, None)
    connector_directory.reset_cache()


#: (openapi path, the request). Every one must be a 404 ``source_not_found``
#: for the shut profile and something else entirely for the open one.
SOURCE_SCOPED_READS = [
    (
        "/sources/{source_id}/browse-modes",
        lambda c, h: c.get(f"/sources/{MATURE_SRC}/browse-modes", headers=h),
    ),
    (
        "/sources/{source_id}/genres",
        lambda c, h: c.get(f"/sources/{MATURE_SRC}/genres", headers=h),
    ),
    (
        "/sources/{source_id}/series",
        lambda c, h: c.get(f"/sources/{MATURE_SRC}/series", headers=h),
    ),
    (
        "/sources/{source_id}/series/{series_id}",
        lambda c, h: c.get(f"/sources/{MATURE_SRC}/series/s1", headers=h),
    ),
    (
        "/sources/{source_id}/series/{series_id}/chapters",
        lambda c, h: c.get(f"/sources/{MATURE_SRC}/series/s1/chapters", headers=h),
    ),
    (
        "/sources/{source_id}/series/{series_id}/cover",
        lambda c, h: c.get(f"/sources/{MATURE_SRC}/series/s1/cover", headers=h),
    ),
    (
        "/sources/{source_id}/series/{series_id}/chapters/{chapter_id}/reader",
        lambda c, h: c.get(
            f"/sources/{MATURE_SRC}/series/s1/chapters/c1/reader", headers=h
        ),
    ),
    (
        "/sources/{source_id}/chapters/{chapter_id}/pages",
        lambda c, h: c.get(f"/sources/{MATURE_SRC}/chapters/c1/pages", headers=h),
    ),
    (
        "/sources/{source_id}/pages/{page_id}/image",
        lambda c, h: c.get(f"/sources/{MATURE_SRC}/pages/p1/image", headers=h),
    ),
    (
        "/reader/chapter/manifest",
        lambda c, h: c.get(
            "/reader/chapter/manifest",
            params={"source": MATURE_SRC, "series": "s1", "chapter": "c1"},
            headers=h,
        ),
    ),
    (
        "/reader/progress/series",
        lambda c, h: c.get(
            "/reader/progress/series",
            params={"source": MATURE_SRC, "series": "s1"},
            headers=h,
        ),
    ),
]


def _is_source_not_found(resp) -> bool:
    if resp.status_code != 404:
        return False
    body = resp.json()
    return "source_not_found" in str(body)


@pytest.mark.parametrize(
    "request_", [r for _, r in SOURCE_SCOPED_READS],
    ids=[p for p, _ in SOURCE_SCOPED_READS],
)
def test_an_adult_source_is_not_found_for_a_shut_gate(
    client, as_user, household, mature_source, request_
):
    resp = request_(client, as_user(household["uid"], household["kid"]))

    assert _is_source_not_found(resp), (resp.status_code, resp.text)


@pytest.mark.parametrize(
    "request_", [r for _, r in SOURCE_SCOPED_READS],
    ids=[p for p, _ in SOURCE_SCOPED_READS],
)
def test_an_adult_source_is_reachable_for_an_open_gate(
    client, as_user, household, mature_source, request_
):
    """Not "returns 200": several of these legitimately fail for other reasons
    on a stub (a cover with no image, a page key that is not a URL). What must
    not happen is the *gate's* denial, which is the one answer that means the
    profile is being told the source does not exist.
    """
    resp = request_(client, as_user(household["uid"], household["grown"]))

    assert not _is_source_not_found(resp), (resp.status_code, resp.text)


#: The listings. An adult source must not be named in them at all.
SOURCE_LISTINGS = [
    ("/sources", lambda c, h: c.get("/sources", headers=h)),
    ("/sources/health", lambda c, h: c.get("/sources/health", headers=h)),
    ("/sources/pins", lambda c, h: c.get("/sources/pins", headers=h)),
    ("/updates/sources", lambda c, h: c.get("/updates/sources", headers=h)),
]


@pytest.fixture
def pinned_mature_source(db_session, household, mature_source):
    """A pin naming the adult source, under both profiles.

    Written directly rather than through ``PUT /sources/pins``: the write path
    refuses the id for the shut profile, and the disclosure being tested is a
    pin that already exists -- made while the gate was open, or by the profile
    that may see it.
    """
    for name in ("kid", "grown"):
        db_session.add(
            SourcePin(
                user_id=household["uid"],
                profile_id=household[name],
                source_id=MATURE_SRC,
                sort_order=0,
            )
        )
    db_session.commit()


@pytest.mark.parametrize(
    "request_", [r for _, r in SOURCE_LISTINGS], ids=[p for p, _ in SOURCE_LISTINGS]
)
def test_no_source_listing_names_an_adult_source_to_a_shut_gate(
    client, as_user, household, pinned_mature_source, request_
):
    resp = request_(client, as_user(household["uid"], household["kid"]))

    assert MATURE_SRC not in resp.text, resp.text


@pytest.mark.parametrize(
    "request_", [r for _, r in SOURCE_LISTINGS], ids=[p for p, _ in SOURCE_LISTINGS]
)
def test_every_source_listing_names_it_to_an_open_gate(
    client, as_user, household, pinned_mature_source, request_
):
    resp = request_(client, as_user(household["uid"], household["grown"]))

    assert resp.status_code == 200, resp.text
    assert MATURE_SRC in resp.text, resp.text


def test_the_source_health_banner_counts_only_visible_sources(
    client, as_user, household, mature_source
):
    """``/system/source-health`` is a count, so it cannot be walked with the
    others -- and a total that moves with what the caller may see is the same
    disclosure, one number wide.

    The expected gap is every installed adult source, not just the stub: this
    install ships a good few, and reading the count from the same registry the
    route reads it from is what keeps the assertion exact rather than
    ``grown > kid``.
    """
    def _total(profile: str) -> int:
        return client.get(
            "/system/source-health",
            headers=as_user(household["uid"], household[profile]),
        ).json()["total"]

    installed_adult = len(mature_source_ids())
    assert mature_source in mature_source_ids()
    assert _total("grown") == _total("kid") + installed_adult


def test_federated_search_queries_only_visible_sources(client, as_user, household):
    """``GET /sources/search`` fans out to every installed connector, so it is
    driven against a stubbed registry here -- the real one would put ~50
    connectors on the network for one assertion."""
    class _Descriptor:
        def __init__(self, source_type, mature):
            self.source_type = source_type
            self.name = source_type
            self.mature = mature
            self.browsable = True
            self.icon_url = ""

    class _Connector:
        def __init__(self, title):
            self._title = title

        def search_series(self, query, page, *, sort=None):
            return PaginatedSeriesList(items=[ConnectorSeries(id="x", title=self._title)])

    descriptors = [_Descriptor("safe-src", False), _Descriptor(MATURE_SRC, True)]
    connectors = {"safe-src": _Connector("Safe"), MATURE_SRC: _Connector("Adult")}

    def _listed(*, browsable_only=False, include_mature=True):
        out = [d for d in descriptors if d.browsable or not browsable_only]
        return out if include_mature else [d for d in out if not d.mature]

    def _search(profile: str) -> str:
        with patch(
            "services.browse_service.list_installed_connectors", _listed
        ), patch(
            "services.browse_service.create_connector",
            side_effect=lambda source_id: connectors[source_id],
        ):
            return client.get(
                "/sources/search",
                params={"q": "anything"},
                headers=as_user(household["uid"], household[profile]),
            ).text

    assert MATURE_SRC not in _search("kid")
    assert MATURE_SRC in _search("grown")


# ---------------------------------------------------------------------------
# The walk is exhaustive, and stays exhaustive
# ---------------------------------------------------------------------------

#: Every GET the app serves that cannot carry series-derived data, with why.
#: A route belongs here only if no answer it can give depends on what series
#: exist, what a profile follows, or what a source publishes.
NOT_SERIES_DERIVED = {
    "/": "the install page",
    "/health": "liveness; one of the two unauthenticated routes",
    "/app/version": "client build metadata",
    "/app/changelog": "client build metadata",
    "/app/download": "the APK itself",
    "/app/ios/download": "the iOS build",
    "/app/source.json": "the AltStore feed",
    "/app/media/{name}": "static images for the install page",
    "/auth/bootstrap-status": "whether the users table is empty",
    "/auth/me": "the caller's own account",
    "/auth/sessions": "the caller's own sessions",
    "/auth/users": "admin-only account list",
    "/backup/export": (
        "admin-only whole-database export -- the owner's own backup, not a "
        "per-profile read, and gating it would produce a backup that cannot "
        "restore the account it came from"
    ),
    "/backup/status": "backup file sizes and timestamps",
    "/settings": "the gate's own value, per profile",
    "/profiles": "the caller's own profiles",
    "/updates/settings": "the instance-wide sweep singleton",
    "/updates/runs": "admin-only; counts per sweep, no series identity",
    "/updates/runs/{run_id}": "admin-only; counts for one sweep",
    "/library/suggest/availability": (
        "whether AI suggestions can run: a bool, a reason string and today's "
        "remaining request count. It names no series and reads no catalog "
        "table, so there is nothing for the gate to hide. The suggestions "
        "THEMSELVES are gated three ways and walked by "
        "tests/test_suggestion_service.py -- the adult rows never reach the "
        "prompt, let alone the response"
    ),
}

#: Every path this file actually drives, taken from the tables above so the
#: two cannot drift. The literal block is the routes asserted by their own
#: named tests rather than by a parametrised walk.
WALKED_HERE = (
    {path for path, _ in _adult_marker_reads(_PATHS_ONLY)}
    | {path for path, _ in _adult_chapter_reads()}
    | {path for path, _ in SOURCE_SCOPED_READS}
    | {path for path, _ in SOURCE_LISTINGS}
    | {
        "/library/collections",
        "/library/collections/{collection_id}",
        "/library/recommendations",
        "/library/statistics",
        "/library/tags",
        "/updates/notifications/unread-count",
        "/sources/search",
        "/system/source-health",
    }
)


def _app_get_paths(app) -> set[str]:
    return {
        path
        for path, operations in app.openapi()["paths"].items()
        if "get" in operations
    }


def test_every_walked_route_still_exists(app):
    """A renamed route must not fall silently out of the walk.

    Without this, ``/library/continue-reading`` becoming ``/library/resume``
    leaves the parametrised case above passing against a 404 -- the marker is
    absent from a not-found body, so the shut-gate half stays green while the
    new route is ungated.
    """
    assert WALKED_HERE <= _app_get_paths(app), sorted(
        WALKED_HERE - _app_get_paths(app)
    )


def test_no_read_route_escapes_this_file(app):
    """The point of the whole file, as one assertion.

    Every gap the 18+ gate has ever had was a route nobody had thought to
    check: collections, ``/library/search``, the OCR reads, the browse cache.
    A new GET is now a failing test until somebody either walks it above or
    writes down, in ``NOT_SERIES_DERIVED``, why it cannot leak -- which is a
    decision that should be made once, deliberately, and not by omission.
    """
    unclassified = _app_get_paths(app) - WALKED_HERE - set(NOT_SERIES_DERIVED)

    assert unclassified == set(), (
        "new GET route(s) with no 18+ gate coverage: "
        f"{sorted(unclassified)} -- walk them above or explain them in "
        "NOT_SERIES_DERIVED"
    )
