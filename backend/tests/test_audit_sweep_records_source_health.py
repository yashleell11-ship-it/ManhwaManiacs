"""The daily sweep records source health, so a source can recover on its own.

``record_outcomes`` had exactly one non-test caller: the federated-search
fan-out. So the only event that could ever CLEAR a failure streak was the owner
personally typing a search while the source happened to answer. The live table
proved the cost — it had not moved in eight days, and two sources had sat at the
failure ceiling for ten, never re-checked.

The sweep already contacts every followed source, so this costs no extra
upstream request. What it must not do is lie about what it saw.
"""

from __future__ import annotations

import pytest
from core.errors import AppError
from services import update_service as us
from services.source_health import load_states

SRC = "asurascans"


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("reader")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _svc(db, uid, pid):
    return us.UpdateService(db, user_id=uid, profile_id=pid)


class _Boom(Exception):
    pass


def _sweep(db, uid, pid, monkeypatch, *, effect):
    """Run one sweep whose per-series check does `effect`."""
    svc = _svc(db, uid, pid)

    def fake_check_one(row):
        return effect(svc, row)

    monkeypatch.setattr(svc, "_check_one", fake_check_one)
    return svc.run_check(trigger="test")


# --- the classifier, which decides what is even a source problem ------------


def test_a_missing_series_is_not_a_sick_source():
    # The source ANSWERED that one series is gone. The site is working.
    exc = AppError("gone", code="series_not_found", status_code=404)
    assert us._health_failure(exc) is None


def test_an_unregistered_source_is_configuration_not_health():
    # A novel connector with the novels flag off raises exactly this. Counting
    # it would mark a perfectly good source dead because of a local setting.
    exc = AppError("nope", code="source_not_found", status_code=404)
    assert us._health_failure(exc) is None


def test_transport_failures_are_the_source():
    assert us._health_failure(TimeoutError("timed out")) == us._HEALTH_TRANSPORT
    assert us._health_failure(ConnectionError("refused")) == us._HEALTH_TRANSPORT


def test_a_bot_wall_is_recorded_as_a_refusal():
    exc = AppError("blocked", code="upstream_error", status_code=403)
    assert us._health_failure(exc) == us._HEALTH_REFUSED


def test_the_recorded_message_never_carries_the_exception_text():
    # FollowedSeries.last_error may hold str(exc) because that row belongs to
    # one (user, profile). source_health is GLOBAL and served to every account
    # on the instance, and an upstream exception routinely embeds the full
    # request URL with its query string.
    leaky = ConnectionError(
        "failed to GET https://example.test/api?token=tok_abc123&user=someone"
    )
    recorded = us._health_failure(leaky)
    assert recorded is not None
    assert "tok_abc123" not in recorded
    assert "example.test" not in recorded
    assert recorded == us._HEALTH_TRANSPORT


# --- what the sweep actually writes -----------------------------------------


def test_a_clean_pass_clears_a_failing_source(
    db_session, acct, seed_follow, monkeypatch
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key="s1")
    # Put the source at the ceiling the way ten days of nothing did live.
    us.record_outcomes(db_session, {SRC: "down"})
    for _ in range(9):
        us.record_outcomes(db_session, {SRC: "down"})
    assert load_states(db_session)[SRC].consecutive_failures > 0

    _sweep(db_session, uid, pid, monkeypatch, effect=lambda svc, row: 0)

    state = load_states(db_session)[SRC]
    assert state.consecutive_failures == 0, (
        "a source that answered every series is still recorded as failing"
    )


def test_a_failing_pass_is_recorded_against_the_source(
    db_session, acct, seed_follow, monkeypatch
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key="s1")

    def blow_up(svc, row):
        raise ConnectionError("upstream is down")

    _sweep(db_session, uid, pid, monkeypatch, effect=blow_up)

    state = load_states(db_session)[SRC]
    assert state.consecutive_failures == 1
    assert state.last_error == us._HEALTH_TRANSPORT


def test_one_dead_series_does_not_condemn_the_whole_source(
    db_session, acct, seed_follow, monkeypatch
):
    # A site with one gone series is a working site. The streak describes the
    # SITE, so any series answering is enough.
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key="alive")
    seed_follow(uid, pid, source_id=SRC, series_key="gone")

    def mixed(svc, row):
        if row.series_key == "gone":
            raise ConnectionError("nope")
        return 0

    _sweep(db_session, uid, pid, monkeypatch, effect=mixed)

    assert load_states(db_session)[SRC].consecutive_failures == 0


def test_a_degraded_answer_counts_as_neither(
    db_session, acct, seed_follow, monkeypatch
):
    # THE trap. The "Source returned no chapters; snapshot kept" path returns
    # NORMALLY. Treating that as success would reset a soft-blocked source's
    # streak from the ceiling to zero on every pass, so it could never be
    # recorded as failing at all.
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key="s1")
    for _ in range(3):
        us.record_outcomes(db_session, {SRC: "down"})
    before = load_states(db_session)[SRC].consecutive_failures
    assert before == 3

    def degraded(svc, row):
        svc._last_check_degraded = True
        return 0

    _sweep(db_session, uid, pid, monkeypatch, effect=degraded)

    after = load_states(db_session)[SRC].consecutive_failures
    assert after == before, (
        f"a degraded answer moved the streak {before} -> {after}; it is neither "
        "evidence the source works nor evidence it is down"
    )


def test_a_missing_series_alone_leaves_health_untouched(
    db_session, acct, seed_follow, monkeypatch
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key="gone")

    def gone(svc, row):
        raise AppError("gone", code="series_not_found", status_code=404)

    _sweep(db_session, uid, pid, monkeypatch, effect=gone)

    assert SRC not in load_states(db_session), (
        "the source answered correctly and was still marked unhealthy"
    )
