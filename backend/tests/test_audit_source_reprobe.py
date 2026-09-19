"""A source nobody follows can still come back from the dead.

The daily sweep records health for FOLLOWED sources, which gives those a
recovery path. It can never reach the rest — and the rest is where the problem
was: harimanga and coffeemanga sat at the failure ceiling from 2026-09-03 with
last_ok_at null, never re-checked once, because nobody follows them and the only
other writer was the search fan-out. The sources most likely to be marked dead
were exactly the ones nothing could un-mark.
"""

from __future__ import annotations

from datetime import timedelta

import pytest
from core.time_utils import utcnow
from services import source_probe_service as probe
from services.source_health import MAX_STREAK, load_states, record_outcomes

NOW = utcnow()


def _fail(db, source_id, times=1, *, when=None):
    for _ in range(times):
        record_outcomes(db, {source_id: "down"}, now=when or NOW)


def test_a_source_never_seen_is_probed_first(db_session):
    # An unknown source is where a probe buys the most.
    targets = probe.select_reprobe_targets(
        db_session, ["neverseen", "alsonew"], now=NOW
    )

    assert set(targets) == {"neverseen", "alsonew"}


def test_a_source_checked_just_now_is_left_alone(db_session):
    record_outcomes(db_session, {"fresh": None}, now=NOW)

    targets = probe.select_reprobe_targets(db_session, ["fresh"], now=NOW)

    assert targets == []


def test_a_stale_source_comes_due(db_session):
    record_outcomes(db_session, {"stale": None}, now=NOW - timedelta(hours=30))

    targets = probe.select_reprobe_targets(db_session, ["stale"], now=NOW)

    assert targets == ["stale"]


def test_a_source_at_the_ceiling_waits_longer_but_not_forever(db_session):
    # Re-asking a site that failed ten times running, every day, is traffic
    # spent to learn nothing. Never re-asking is how one stays wrong for a
    # fortnight, which is precisely what happened.
    _fail(db_session, "dead", times=MAX_STREAK + 2, when=NOW - timedelta(days=2))
    state = load_states(db_session)["dead"]
    assert state.consecutive_failures >= MAX_STREAK

    assert probe.select_reprobe_targets(db_session, ["dead"], now=NOW) == []

    later = NOW + timedelta(days=8)
    assert probe.select_reprobe_targets(db_session, ["dead"], now=later) == ["dead"]


def test_the_batch_is_capped(db_session):
    targets = probe.select_reprobe_targets(
        db_session, [f"src{i}" for i in range(50)], now=NOW, limit=6
    )

    assert len(targets) == 6


def test_selection_is_deterministic(db_session):
    # Two ticks must not disagree about what is due; the tie-break is the id.
    names = [f"src{i}" for i in range(20)]
    first = probe.select_reprobe_targets(db_session, names, now=NOW, limit=5)
    again = probe.select_reprobe_targets(db_session, names, now=NOW, limit=5)

    assert first == again


def test_a_working_source_is_cleared(db_session, monkeypatch):
    _fail(db_session, "asurascans", times=3, when=NOW - timedelta(days=2))

    class _Listing:
        items = [object()]

    monkeypatch.setattr(
        probe,
        "list_installed_connectors",
        lambda **_: [type("D", (), {"source_type": "asurascans"})()],
    )
    monkeypatch.setattr(
        probe, "create_connector", lambda _s: type("C", (), {"get_series_list": lambda self, p: _Listing()})()
    )

    out = probe.reprobe_sources(db_session, now=NOW)

    assert out == {"asurascans": None}
    assert load_states(db_session)["asurascans"].consecutive_failures == 0


def test_a_dead_source_stays_recorded_dead(db_session, monkeypatch):
    monkeypatch.setattr(
        probe,
        "list_installed_connectors",
        lambda **_: [type("D", (), {"source_type": "harimanga"})()],
    )

    def boom(_s):
        raise ConnectionError("failed to GET https://harimanga.test/?token=abc")

    monkeypatch.setattr(probe, "create_connector", boom)

    out = probe.reprobe_sources(db_session, now=NOW)

    assert out["harimanga"] is not None
    # Fixed phrase, never str(exc): source_health is GLOBAL and served to every
    # account, and an upstream exception routinely carries the request URL.
    assert "harimanga.test" not in out["harimanga"]
    assert "abc" not in out["harimanga"]


def test_an_empty_listing_counts_as_a_failure(db_session, monkeypatch):
    # Unlike the update sweep, where an empty answer is weighed against a known
    # chapter snapshot. A source whose front page has nothing on it is not
    # usable for browsing, whatever the reason.
    class _Empty:
        items: list[object] = []

    monkeypatch.setattr(
        probe,
        "list_installed_connectors",
        lambda **_: [type("D", (), {"source_type": "coffeemanga"})()],
    )
    monkeypatch.setattr(
        probe, "create_connector", lambda _s: type("C", (), {"get_series_list": lambda self, p: _Empty()})()
    )

    out = probe.reprobe_sources(db_session, now=NOW)

    assert out["coffeemanga"] is not None


def test_the_batch_stops_at_its_budget(db_session, monkeypatch):
    # A run of wedged sites must not hold the scheduler thread.
    monkeypatch.setattr(
        probe,
        "list_installed_connectors",
        lambda **_: [
            type("D", (), {"source_type": f"src{i}"})() for i in range(6)
        ],
    )

    class _Listing:
        items = [object()]

    monkeypatch.setattr(
        probe, "create_connector", lambda _s: type("C", (), {"get_series_list": lambda self, p: _Listing()})()
    )

    ticks = iter([0.0, 0.0, 99.0, 99.0, 99.0, 99.0, 99.0, 99.0])
    out = probe.reprobe_sources(
        db_session, now=NOW, budget_seconds=10.0, clock=lambda: next(ticks)
    )

    assert len(out) < 6


def test_nothing_due_means_no_upstream_traffic(db_session, monkeypatch):
    record_outcomes(db_session, {"fresh": None}, now=NOW)
    monkeypatch.setattr(
        probe,
        "list_installed_connectors",
        lambda **_: [type("D", (), {"source_type": "fresh"})()],
    )

    def never(_s):
        raise AssertionError("probed a source that was not due")

    monkeypatch.setattr(probe, "create_connector", never)

    assert probe.reprobe_sources(db_session, now=NOW) == {}
