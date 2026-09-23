"""Federated search: relevance, per-source grouping, and fan-out bounds.

The regression these guard: searching "lookism" returned 40 rows of unrelated
Chinese titles and zero Lookism. Two bugs stacked up -- the flat
``merged[:per_page]`` truncation let the third source (ordered by connector
display name) spend every slot on a catalog dump that ignored the query, and the
cross-source de-dupe collapsed the five genuine hits into one row.
"""

from __future__ import annotations

import time
from collections import Counter
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from connectors.models import PaginatedSeriesList, Series as ConnectorSeries
from database.session import get_db
from main import create_app


# ---------------------------------------------------------------------------
# Test doubles: fake registry descriptors + connectors (never hit the network)
# ---------------------------------------------------------------------------


class _FakeDescriptor:
    def __init__(
        self,
        source_type: str,
        *,
        mature: bool = False,
        name: str | None = None,
    ) -> None:
        self.source_type = source_type
        self.name = name or source_type
        self.mature = mature
        self.browsable = True
        self.icon_url = f"/static/sources/{source_type}.png"


class _FakeConnector:
    """Minimal connector stub exposing only ``search_series``."""

    def __init__(
        self,
        items: list[ConnectorSeries],
        *,
        has_more: bool = False,
        raises: Exception | None = None,
        delay: float = 0.0,
    ) -> None:
        self._items = items
        self._has_more = has_more
        self._raises = raises
        self._delay = delay

    def search_series(self, query: str, page: int, *, sort=None):
        if self._delay:
            time.sleep(self._delay)
        if self._raises is not None:
            raise self._raises
        return PaginatedSeriesList(items=self._items, api_has_more=self._has_more)


def _make_list_installed(descriptors: list[_FakeDescriptor]):
    """Mirror the real registry filter: browsable_only + include_mature."""

    def _fake(*, browsable_only: bool = False, include_mature: bool = True):
        out = list(descriptors)
        if browsable_only:
            out = [d for d in out if d.browsable]
        if not include_mature:
            out = [d for d in out if not d.mature]
        return out

    return _fake


def _series(sid: str, title: str, author: str | None = None) -> ConnectorSeries:
    return ConnectorSeries(id=sid, title=title, author=author)


def _group(payload: dict, source: str | None) -> dict:
    return next(g for g in payload["groups"] if g["source"] == source)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def session_factory(db_engine):
    return sessionmaker(bind=db_engine, autoflush=False, autocommit=False)


@pytest.fixture
def client(db_engine, session_factory):
    def override_get_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    app = create_app(run_migrations=False, run_workers=False)
    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as test_client:
        yield test_client


def _search(client, descriptors, connectors: dict, query: str, **params):
    """Run GET /sources/search against a fake registry."""

    def _create(source_id: str):
        return connectors[source_id]

    with patch(
        "services.browse_service.list_installed_connectors",
        _make_list_installed(descriptors),
    ), patch("services.browse_service.create_connector", side_effect=_create):
        return client.get("/sources/search", params={"q": query, **params})


# ---------------------------------------------------------------------------
# The reported bug
# ---------------------------------------------------------------------------


# Real payloads measured against the live registry on 2026-07-27: baozimh
# answers "lookism" with 82 distinct catalog titles, mangakatana with Lookism
# first followed by fuzzy "Look..." matches.
_BAOZIMH_CATALOG = [
    _series(f"bz-{i}", f"{title} {i}")
    for i, title in enumerate(
        ["斗羅大陸", "從前有座靈劍山", "妖神記", "武動乾坤", "元尊", "全職法師"] * 14
    )
][:82]
_MANGAKATANA_HITS = [
    _series("mk-1", "Lookism"),
    _series("mk-2", "Go! Go! Lookie-Lou"),
    _series("mk-3", "Looking Up to You"),
    _series("mk-4", "Looking up to Magical Girls"),
]


def test_source_ignoring_the_query_cannot_fill_the_page(client, session_factory):
    """The exact reported failure: baozimh sorts third by display name and
    answers every query with its whole catalog. Before the fix it took all 40
    slots and Lookism -- mangakatana's first hit -- never made the page."""
    descriptors = [
        _FakeDescriptor("asurascans", name="Asura Scans"),
        _FakeDescriptor("baozimh", name="BaoZiMH"),
        _FakeDescriptor("mangakatana", name="MangaKatana"),
    ]
    connectors = {
        "asurascans": _FakeConnector([]),
        "baozimh": _FakeConnector(_BAOZIMH_CATALOG),
        "mangakatana": _FakeConnector(_MANGAKATANA_HITS),
    }

    payload = _search(client, descriptors, connectors, "lookism").json()

    titles = [item["title"] for item in payload["items"]]
    assert "Lookism" in titles
    # No single source may own the page.
    per_source = Counter(item["source"] for item in payload["items"])
    assert per_source["baozimh"] == 0
    assert max(per_source.values()) < len(payload["items"]) or len(per_source) == 1

    ignored = _group(payload, "baozimh")
    assert ignored["status"] == "empty"
    assert ignored["items"] == []
    assert "unrelated" in ignored["error"]


def test_multi_source_hits_each_keep_their_own_group(client, session_factory):
    """The five real Lookism hits used to collapse into one row via the
    cross-source title de-dupe. Each source now keeps its own group."""
    sources = ["mangakatana", "mangaread", "webtoons", "weebcentral", "harimanga"]
    descriptors = [_FakeDescriptor(s) for s in sources]
    connectors = {s: _FakeConnector([_series(f"{s}-1", "Lookism")]) for s in sources}

    payload = _search(client, descriptors, connectors, "lookism").json()

    hit_groups = {g["source"] for g in payload["groups"] if g["items"]}
    assert hit_groups == set(sources)
    # ... and all five survive into the flat list too.
    flat = [item for item in payload["items"] if item["title"] == "Lookism"]
    assert {item["source"] for item in flat} == set(sources)


def test_alternative_title_hit_is_not_discarded(client, session_factory):
    """MangaDex answers "lookism" with the single romanized title
    "Oemo Jisangjuui" (verified live: total=1). It shares no token with the
    query, so a naive relevance guard would throw the only real hit away."""
    descriptors = [_FakeDescriptor("mangadex", name="MangaDex")]
    connectors = {"mangadex": _FakeConnector([_series("md-1", "Oemo Jisangjuui")])}

    payload = _search(client, descriptors, connectors, "lookism").json()

    group = _group(payload, "mangadex")
    assert group["status"] == "ok"
    assert [item["title"] for item in group["items"]] == ["Oemo Jisangjuui"]
    assert payload["items"][0]["title"] == "Oemo Jisangjuui"


def test_relevant_hits_outrank_a_source_that_ignored_the_query(client, session_factory):
    """A source under the drop threshold is demoted, not dropped: its rows sit
    behind every source that actually matched."""
    descriptors = [
        _FakeDescriptor("aaa-noise", name="AAA Noise"),
        _FakeDescriptor("zzz-hit", name="ZZZ Hit"),
    ]
    connectors = {
        "aaa-noise": _FakeConnector([_series("n-1", "Totally Other Comic")]),
        "zzz-hit": _FakeConnector([_series("h-1", "Lookism")]),
    }

    payload = _search(client, descriptors, connectors, "lookism").json()

    assert [g["source"] for g in payload["groups"]] == [None, "zzz-hit", "aaa-noise"]
    assert payload["items"][0]["source"] == "zzz-hit"
    # Demoted, not dropped -- it may be an alternative-title match.
    assert _group(payload, "aaa-noise")["status"] == "ok"


def test_one_source_with_many_hits_cannot_starve_the_others(client, session_factory):
    """Per-source interleaving: a source returning a full page of matches still
    leaves room for every other source's hits."""
    descriptors = [_FakeDescriptor("bulk"), _FakeDescriptor("small")]
    connectors = {
        "bulk": _FakeConnector([_series(f"b-{i}", f"Lookism {i}") for i in range(60)]),
        "small": _FakeConnector([_series("s-1", "Lookism Special")]),
    }

    payload = _search(client, descriptors, connectors, "lookism", per_page=10).json()

    assert len(payload["items"]) == 10
    assert "small" in {item["source"] for item in payload["items"]}
    assert payload["has_more"] is True


# ---------------------------------------------------------------------------
# Grouped payload
# ---------------------------------------------------------------------------


def test_groups_carry_display_metadata(client, session_factory):
    descriptors = [_FakeDescriptor("mangadex", name="MangaDex")]
    connectors = {
        "mangadex": _FakeConnector(
            [_series("md-1", "One Piece Colored", author="Oda")], has_more=True
        )
    }

    payload = _search(client, descriptors, connectors, "one piece").json()

    source_group = _group(payload, "mangadex")
    assert source_group["source_name"] == "MangaDex"
    assert source_group["icon_url"] == "/static/sources/mangadex.png"
    assert source_group["status"] == "ok"
    assert source_group["has_more"] is True
    assert source_group["total"] == 1
    assert source_group["error"] is None


def test_cover_url_is_relative_whatever_host_the_request_arrived_on(
    client, session_factory
):
    """Behind the web's /api rewrite the request's Host is the backend's
    container name, and behind Caddy its scheme is plain http. A cover built
    on either never loaded on web and sent the app's bearer token in clear
    text, so the path comes back relative -- the same one the browse listing
    serves -- for each client to resolve against its own API base."""
    descriptors = [_FakeDescriptor("mangadex")]
    connectors = {"mangadex": _FakeConnector([_series("md/1", "Lookism")])}

    with patch(
        "services.browse_service.list_installed_connectors",
        _make_list_installed(descriptors),
    ), patch(
        "services.browse_service.create_connector",
        side_effect=lambda source_id: connectors[source_id],
    ):
        payload = client.get(
            "/sources/search",
            params={"q": "lookism"},
            headers={"host": "manhwamaniacs-backend:8000"},
        ).json()

    (item,) = _group(payload, "mangadex")["items"]
    assert item["cover_url"] == "/sources/mangadex/series/md%2F1/cover"
    assert payload["items"][0]["cover_url"] == item["cover_url"]


def test_failing_source_becomes_an_error_group(client, session_factory):
    descriptors = [_FakeDescriptor("good"), _FakeDescriptor("bad")]
    connectors = {
        "good": _FakeConnector([_series("g-1", "Good Hit")]),
        "bad": _FakeConnector([], raises=RuntimeError("cloudflare wall")),
    }

    payload = _search(client, descriptors, connectors, "hit").json()

    assert payload["sources_failed"] == 1
    failed = _group(payload, "bad")
    assert failed["status"] == "error"
    assert "cloudflare wall" in failed["error"]
    assert failed["items"] == []
    assert "Good Hit" in {item["title"] for item in payload["items"]}


def test_flat_items_are_still_served_alongside_groups(client, session_factory):
    """The installed mobile build reads ``items`` only; dropping it would
    reproduce the empty-results bug for anyone who has not updated."""
    descriptors = [_FakeDescriptor("mangadex")]
    connectors = {"mangadex": _FakeConnector([_series("md-1", "Lookism")])}

    payload = _search(client, descriptors, connectors, "lookism").json()

    assert payload["items"] == _group(payload, "mangadex")["items"]
    assert payload["page"] == 1
    assert payload["sources_queried"] == 1


def test_same_title_twice_from_one_source_is_de_duped(client, session_factory):
    """De-dupe is scoped to a single source, where a repeat really is a repeat."""
    descriptors = [_FakeDescriptor("mangadex")]
    connectors = {
        "mangadex": _FakeConnector(
            [_series("md-1", "Lookism"), _series("md-2", "lookism ")]
        )
    }

    payload = _search(client, descriptors, connectors, "lookism").json()

    assert _group(payload, "mangadex")["total"] == 1


# ---------------------------------------------------------------------------
# Fan-out bounds
# ---------------------------------------------------------------------------


def test_slow_source_is_cut_at_the_deadline(client, session_factory, monkeypatch):
    """A wedged source is reported failed instead of holding the whole request
    past the mobile client's receive timeout."""
    monkeypatch.setattr("services.browse_service._SEARCH_TIMEOUT_SECONDS", 0.2)
    monkeypatch.setattr("services.browse_service._SEARCH_DEADLINE_SECONDS", 0.4)
    descriptors = [_FakeDescriptor("slow"), _FakeDescriptor("fast")]
    connectors = {
        "slow": _FakeConnector([_series("s-1", "Lookism Slow")], delay=1.0),
        "fast": _FakeConnector([_series("f-1", "Lookism")]),
    }

    started = time.monotonic()
    payload = _search(client, descriptors, connectors, "lookism").json()
    elapsed = time.monotonic() - started

    assert elapsed < 1.0
    assert payload["sources_failed"] == 1
    assert _group(payload, "slow")["status"] == "error"
    assert [item["source"] for item in payload["items"]] == ["fast"]


def test_search_uses_its_own_bounded_executor(client, session_factory):
    """All sources are queried in one round; the old semaphore of 8 serialised
    the registry into ceil(N/8) rounds of the per-source timeout."""
    from services import browse_service

    descriptors = [_FakeDescriptor(f"s{i}") for i in range(24)]
    connectors = {
        d.source_type: _FakeConnector([_series("x", "Lookism")], delay=0.05)
        for d in descriptors
    }

    started = time.monotonic()
    payload = _search(client, descriptors, connectors, "lookism").json()
    elapsed = time.monotonic() - started

    assert payload["sources_queried"] == 24
    assert payload["sources_failed"] == 0
    assert elapsed < 1.0
    assert browse_service._get_search_executor()._max_workers >= 24


# ---------------------------------------------------------------------------
# Pre-existing behaviour that must not regress
# ---------------------------------------------------------------------------


def test_empty_query_returns_empty_items_but_queries_sources(client, session_factory):
    descriptors = [_FakeDescriptor("mangadex"), _FakeDescriptor("asura")]

    with patch(
        "services.browse_service.list_installed_connectors",
        _make_list_installed(descriptors),
    ), patch(
        "services.browse_service.create_connector",
        side_effect=AssertionError("should not query connectors on empty query"),
    ):
        response = client.get("/sources/search", params={"q": "   "})

    assert response.status_code == 200
    payload = response.json()
    assert payload["items"] == []
    assert payload["sources_queried"] == 2
    assert payload["sources_failed"] == 0
    assert payload["has_more"] is False
    assert all(g["status"] == "empty" for g in payload["groups"])


def test_no_matches_returns_empty_items(client, session_factory):
    descriptors = [_FakeDescriptor("mangadex")]
    connectors = {"mangadex": _FakeConnector([])}

    payload = _search(client, descriptors, connectors, "zzz-no-such-title").json()

    assert payload["items"] == []
    assert payload["sources_queried"] == 1
    assert _group(payload, "mangadex")["status"] == "empty"


def test_source_list_exposes_the_mature_flag(client):
    """The client badges 18+ sources; the descriptor always carried the flag,
    the payload just dropped it."""
    response = client.get("/sources")

    assert response.status_code == 200
    payload = response.json()
    assert payload
    assert all(isinstance(item["mature"], bool) for item in payload)
