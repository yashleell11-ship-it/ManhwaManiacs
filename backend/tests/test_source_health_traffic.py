"""A reader's own requests count towards source health -- the right ones only.

The re-probe asks each source for one LISTING page, so a source blocked only on
its series pages or its search (linkmanga was) answered it every day and was
recorded healthy while every series opened from it failed. These tests pin
that a reader's series page, chapter list and single-source search now feed
``source_health`` with no extra upstream request, and -- as hard -- that they
cannot demote a source for everyone on evidence that is not the source's: a
timeout, a 404, an empty answer, or one tap that fired two requests.
"""

from __future__ import annotations

import json
from datetime import timedelta

import httpx
import pytest
from curl_cffi.const import CurlECode
from curl_cffi.requests.exceptions import (
    ConnectionError as CurlConnectionError,
    ConnectTimeout as CurlConnectTimeout,
    DNSError as CurlDNSError,
)
from sqlalchemy import select

from connectors.http.client import ConnectorHttpError
from connectors.models import Chapter, PaginatedSeriesList, Series
from core.errors import AppError
from core.time_utils import utcnow
from database.models import SourceHealth, SourceSeriesCache
from services import source_cache_service as scs
from services import source_health
from services.browse_service import BrowseService
from services.source_health import (
    DEMOTE_AFTER_FAILURES,
    TRAFFIC_BLOCKED,
    TRAFFIC_FAILURE_SPACING,
    TRAFFIC_SERVER_ERROR,
    TRAFFIC_UNREACHABLE,
    record_traffic_outcome,
    reset_traffic_spacing,
    source_side_failure,
)

SRC = "fakesource"
SERIES = "some-series"
# What an httpx failure message looks like: the full request URL, query string
# and all. Must never reach the GLOBAL health row.
LEAKY = "Client error '403 Forbidden' for url 'https://x.test/search?q=private+words'"


class _Connector:
    """Just enough of a connector for the browse paths under test."""

    is_browsable = True
    is_mature = False

    def __init__(self, *, fail: BaseException | None = None, chapters=None) -> None:
        self.fail = fail
        self.chapters = (
            [Chapter(id="c1", series_id=SERIES, title="Chapter 1", number=1.0, page_count=0)]
            if chapters is None
            else chapters
        )
        self.calls = 0

    def _maybe_fail(self) -> None:
        self.calls += 1
        if self.fail is not None:
            raise self.fail

    def get_series(self, series_id: str):
        self._maybe_fail()
        return Series(id=series_id, title="Some Series", chapter_count=len(self.chapters))

    def get_chapters(self, series_id: str):
        self._maybe_fail()
        return list(self.chapters)

    def search_series(self, query: str, page: int, *, sort=None):
        self._maybe_fail()
        return PaginatedSeriesList(items=[Series(id=SERIES, title="Some Series")], total=1)

    def get_series_list(self, page: int, *, sort=None):
        self._maybe_fail()
        return PaginatedSeriesList(items=[Series(id=SERIES, title="Some Series")], total=1)


@pytest.fixture(autouse=True)
def _fresh_spacing():
    reset_traffic_spacing()
    yield
    reset_traffic_spacing()


@pytest.fixture
def client(app):
    """The suite's client, minus re-raising: a connector error nothing maps
    escapes the series and chapter routes as a 500, and that response -- not
    the exception -- is what a reader gets."""
    from fastapi.testclient import TestClient

    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


@pytest.fixture
def use_connector(monkeypatch):
    def _use(connector: _Connector) -> _Connector:
        monkeypatch.setattr(
            "services.browse_service.create_connector", lambda source_id: connector
        )
        return connector

    # The browse page warms the next page on a thread of its own; nothing here
    # is about that.
    monkeypatch.setattr(scs, "_spawn_warm", lambda work: None)
    return _use


def _row(session_factory, source_id: str = SRC) -> SourceHealth | None:
    db = session_factory()
    try:
        return db.execute(
            select(SourceHealth).where(SourceHealth.source_id == source_id)
        ).scalar_one_or_none()
    finally:
        db.close()


def _seed(session_factory, failures: int) -> None:
    db = session_factory()
    try:
        db.add(SourceHealth(source_id=SRC, consecutive_failures=failures))
        db.commit()
    finally:
        db.close()


def _wrapped(cause: BaseException, status: int | None = None) -> ConnectorHttpError:
    """A failure shaped the way the connector HTTP clients raise it."""
    try:
        raise cause
    except BaseException as inner:  # noqa: BLE001
        try:
            raise ConnectorHttpError(str(inner), status_code=status) from inner
        except ConnectorHttpError as outer:
            return outer


# ---------------------------------------------------------------------------
# What counts
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("exc", "expected"),
    [
        (ConnectorHttpError(LEAKY, status_code=403), TRAFFIC_BLOCKED),
        # How cf_client reports a Cloudflare interstitial, after its retries.
        (
            _wrapped(
                ConnectorHttpError(
                    "Cloudflare challenge blocked the request.",
                    status_code=403,
                    retryable=True,
                ),
                status=403,
            ),
            TRAFFIC_BLOCKED,
        ),
        (ConnectorHttpError("Retryable HTTP 503", status_code=503), TRAFFIC_SERVER_ERROR),
        (ConnectorHttpError("boom", status_code=500), TRAFFIC_SERVER_ERROR),
        (_wrapped(httpx.ConnectError("[Errno 111] Connection refused")), TRAFFIC_UNREACHABLE),
        (_wrapped(CurlDNSError("could not resolve host")), TRAFFIC_UNREACHABLE),
        (
            _wrapped(CurlConnectionError("refused", code=CurlECode.COULDNT_CONNECT)),
            TRAFFIC_UNREACHABLE,
        ),
        (ConnectionRefusedError(111, "Connection refused"), TRAFFIC_UNREACHABLE),
    ],
)
def test_source_side_failures_count(exc, expected):
    assert source_side_failure(exc) == expected


@pytest.mark.parametrize(
    "exc",
    [
        # Timeouts, in every shape the clients raise them.
        _wrapped(httpx.ReadTimeout("timed out")),
        _wrapped(httpx.ConnectTimeout("timed out")),
        _wrapped(CurlConnectTimeout("timed out")),
        TimeoutError("Search deadline exceeded."),
        # firstkissmanga turns "unreachable OR timed out" into a 503; the
        # timeout underneath decides it.
        _wrapped(httpx.ReadTimeout("timed out"), status=503),
        # The site answering about one request, not the site being down.
        ConnectorHttpError("not found", status_code=404),
        ConnectorHttpError("Retryable HTTP 429", status_code=429),
        ConnectorHttpError("bad request", status_code=400),
        # A connection that dropped mid-read is as likely this end's.
        _wrapped(CurlConnectionError("recv failure", code=CurlECode.RECV_ERROR)),
        _wrapped(httpx.ReadError("connection reset")),
        # Ours, not upstream's.
        AppError("Series not found.", code="series_not_found", status_code=404),
        AppError("Bad gateway", code="x", status_code=502),
        RuntimeError("parser found nothing"),
    ],
)
def test_failures_that_are_not_the_sources_do_not_count(exc):
    assert source_side_failure(exc) is None


# ---------------------------------------------------------------------------
# Recording from real reader traffic
# ---------------------------------------------------------------------------


def test_a_series_page_blocked_by_the_source_is_recorded(
    client, session_factory, use_connector
):
    use_connector(_Connector(fail=ConnectorHttpError(LEAKY, status_code=403)))

    response = client.get(f"/sources/{SRC}/series/{SERIES}")

    assert response.status_code >= 500
    row = _row(session_factory)
    assert row is not None
    assert row.consecutive_failures == 1
    # A fixed phrase: the upstream message carried a URL and a query string.
    assert row.last_error == TRAFFIC_BLOCKED
    assert "private" not in (row.last_error or "")


def test_separate_failed_opens_demote_the_source(client, session_factory, use_connector):
    use_connector(_Connector(fail=ConnectorHttpError("Retryable HTTP 503", status_code=503)))

    for _ in range(DEMOTE_AFTER_FAILURES):
        client.get(f"/sources/{SRC}/series/{SERIES}/chapters")
        reset_traffic_spacing()  # stands in for the minute between attempts

    row = _row(session_factory)
    assert row.consecutive_failures == DEMOTE_AFTER_FAILURES
    assert row.last_error == TRAFFIC_SERVER_ERROR
    assert source_health.load_states(session_factory())[SRC].demoted is True


def test_one_open_that_fires_two_requests_counts_once(
    client, session_factory, use_connector
):
    use_connector(_Connector(fail=ConnectorHttpError("blocked", status_code=403)))

    # Opening a series asks for its page and its chapter list together.
    client.get(f"/sources/{SRC}/series/{SERIES}")
    client.get(f"/sources/{SRC}/series/{SERIES}/chapters")

    assert _row(session_factory).consecutive_failures == 1


def test_the_spacing_window_is_what_collapses_a_burst(db_engine, session_factory):
    ticks = iter([0.0, 1.0, TRAFFIC_FAILURE_SPACING.total_seconds() + 1.0])
    clock = lambda: next(ticks)  # noqa: E731

    record_traffic_outcome(db_engine, SRC, TRAFFIC_BLOCKED, clock=clock)
    record_traffic_outcome(db_engine, SRC, TRAFFIC_BLOCKED, clock=clock)
    assert _row(session_factory).consecutive_failures == 1

    record_traffic_outcome(db_engine, SRC, TRAFFIC_BLOCKED, clock=clock)
    assert _row(session_factory).consecutive_failures == 2


def test_a_timeout_on_a_readers_request_is_not_recorded(
    client, session_factory, use_connector
):
    use_connector(_Connector(fail=_wrapped(httpx.ReadTimeout("timed out"))))

    client.get(f"/sources/{SRC}/series/{SERIES}")
    client.get(f"/sources/{SRC}/series?query=private")

    assert _row(session_factory) is None


def test_a_single_source_search_counts_but_a_plain_browse_does_not(
    client, session_factory, use_connector
):
    use_connector(_Connector(fail=_wrapped(httpx.ConnectError("refused"))))

    # The plain browse is the re-probe's own question; it keeps answering it.
    client.get(f"/sources/{SRC}/series")
    assert _row(session_factory) is None

    response = client.get(f"/sources/{SRC}/series", params={"query": "private words"})

    assert response.status_code == 502
    row = _row(session_factory)
    assert row.consecutive_failures == 1
    assert row.last_error == TRAFFIC_UNREACHABLE


def test_a_success_clears_a_streak_search_built(client, session_factory, use_connector):
    _seed(session_factory, DEMOTE_AFTER_FAILURES + 2)
    use_connector(_Connector())

    response = client.get(f"/sources/{SRC}/series/{SERIES}")

    assert response.status_code == 200
    row = _row(session_factory)
    assert row.consecutive_failures == 0
    assert row.last_ok_at is not None


def test_a_search_with_no_results_is_still_the_source_answering(
    client, session_factory, use_connector
):
    _seed(session_factory, 4)
    connector = use_connector(_Connector())
    connector.search_series = lambda query, page, *, sort=None: PaginatedSeriesList()

    client.get(f"/sources/{SRC}/series", params={"query": "nothing matches"})

    assert _row(session_factory).consecutive_failures == 0


def test_an_empty_chapter_list_does_not_clear_a_streak(
    client, session_factory, use_connector
):
    _seed(session_factory, 4)
    use_connector(_Connector(chapters=[]))

    response = client.get(f"/sources/{SRC}/series/{SERIES}/chapters")

    assert response.status_code == 200
    assert response.json() == []
    # A soft block answering 200 with nothing parses exactly like this; it is
    # the sweep's "degraded" case and must not un-demote a blocked source.
    assert _row(session_factory).consecutive_failures == 4


def test_the_series_cache_records_what_it_degrades_past(
    client, session_factory, use_connector
):
    """The reader manifest reaches the connector through the series cache,
    which serves a stale row when the source fails. The reader never sees the
    failure; health still must."""
    use_connector(_Connector(fail=ConnectorHttpError("blocked", status_code=403)))
    db = session_factory()
    try:
        # Old enough to be refetched, so the connector is asked and fails.
        db.add(
            SourceSeriesCache(
                source_id=SRC,
                series_key=SERIES,
                title="Cached Title",
                chapters=json.dumps([]),
                fetched_at=utcnow() - timedelta(days=30),
            )
        )
        db.commit()
        browse = BrowseService(mature_enabled=True, db=db, record_traffic_health=True)
        served = scs.SourceCacheService(db, browse).get_series_meta(SRC, SERIES)
    finally:
        db.close()

    assert served["title"] == "Cached Title"
    assert _row(session_factory).consecutive_failures == 1


def test_background_actors_do_not_record_through_this_path(
    session_factory, use_connector
):
    """The update sweep builds its own BrowseService and records one outcome
    per source per pass, by rules of its own. A per-call record underneath it
    would double-count failures and undo its "degraded is neither" rule."""
    use_connector(_Connector(fail=ConnectorHttpError("blocked", status_code=403)))
    db = session_factory()
    try:
        with pytest.raises(ConnectorHttpError):
            BrowseService(mature_enabled=True, db=db).get_chapters(SRC, SERIES)
    finally:
        db.close()

    assert _row(session_factory) is None


def test_recording_never_breaks_a_readers_request(
    client, session_factory, use_connector, monkeypatch
):
    def _explode(*args, **kwargs):
        raise RuntimeError("health table on fire")

    monkeypatch.setattr(source_health, "record_outcomes", _explode)
    use_connector(_Connector())

    response = client.get(f"/sources/{SRC}/series/{SERIES}")

    assert response.status_code == 200
    assert response.json()["title"] == "Some Series"
