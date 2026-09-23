"""A removed 18+ source's rows keep their 18+ status.

A follow's maturity is its override, then the rating captured from its genres
at follow time, then the source's own maturity. Madara adult sites often tag a
series with nothing the genre rule recognises, so ``content_rating`` is NULL
and the source is the only thing hiding the row. That signal used to be read
from the installed registry alone, so the day an adult source was deregistered
(lilymanga 2026-09-22, linkmanga 2026-09-23) every such follow dropped from
mature to unknown, and unknown is shown: a series hidden from a profile with
18+ off one day was in its library by title and cover the next.

Both halves of the rule are pinned: the Python one the library list uses, and
the SQL mirror the history, statistics, bookmarks and notifications use.
"""

from __future__ import annotations

import pytest

import connectors.registry as registry
from connectors.excluded import RETIRED_MATURE_SOURCES
from core.connector_directory import (
    descriptor_for_source,
    gated_source_ids,
    is_mature_source,
    mature_source_ids,
)
from services.progress_service import ProgressService
from tests.test_audit_mature_library_writes import StubMatureSource

RETIRED = "lilymanga"
INSTALLED_ADULT = "manga18x"
SAFE_SRC = "mangadex"


@pytest.fixture
def kid(make_user, make_profile):
    user = make_user("household")
    profile = make_profile(user.id, "Kid", mature_content_enabled=False)
    return user.id, profile.id


def test_the_premise_the_source_is_really_gone():
    assert descriptor_for_source(RETIRED) is None
    assert RETIRED not in mature_source_ids()
    assert RETIRED in RETIRED_MATURE_SOURCES


def test_a_removed_adult_source_is_still_adult():
    assert is_mature_source(RETIRED)
    assert is_mature_source("linkmanga")
    assert is_mature_source("topmanhua")
    assert is_mature_source("toonilyme")
    assert RETIRED in gated_source_ids()
    # The set only ever adds: an id it never named is not swept in with it.
    assert not is_mature_source("never-a-source")
    assert not is_mature_source(SAFE_SRC)
    assert is_mature_source(INSTALLED_ADULT)


def test_an_installed_descriptor_wins_over_the_retired_set():
    """A retired id that comes back general-audience is judged by its descriptor."""

    class _Back(StubMatureSource):
        SOURCE_TYPE = RETIRED
        MATURE = False

    registry.register_connector(RETIRED, _Back)
    try:
        assert descriptor_for_source(RETIRED) is not None
        assert not is_mature_source(RETIRED)
        assert RETIRED not in gated_source_ids()
    finally:
        registry._REGISTRY.pop(RETIRED, None)
        registry._INSTANCE_CACHE.pop(RETIRED, None)


def test_the_library_keeps_hiding_an_unrated_follow_on_a_removed_adult_source(
    client, as_user, kid, seed_follow
):
    uid, pid = kid
    for source_id in (RETIRED, INSTALLED_ADULT, SAFE_SRC):
        seed_follow(
            uid, pid, source_id=source_id, series_key="s1",
            title=f"Title on {source_id}", content_rating=None,
        )

    resp = client.get("/library/series", headers=as_user(uid, pid))
    assert resp.status_code == 200, resp.json()
    payload = resp.json()
    items = payload.get("items", payload) if isinstance(payload, dict) else payload
    assert sorted(r["source_id"] for r in items) == [SAFE_SRC]


def test_history_keeps_hiding_progress_on_a_removed_adult_source(
    db_session, kid, seed_follow, seed_progress
):
    """The SQL mirror (``mature_tracker_case``), with and without a follow row."""
    uid, pid = kid
    seed_follow(uid, pid, source_id=RETIRED, series_key="followed", content_rating=None)
    for series_key in ("followed", "unfollowed"):
        seed_progress(uid, pid, source_id=RETIRED, series_key=series_key, chapter_key="c1")
    seed_progress(uid, pid, source_id=SAFE_SRC, series_key="safe", chapter_key="c1")

    history = ProgressService(db_session, user_id=uid, profile_id=pid).reading_history()
    assert [r["source_id"] for r in history] == [SAFE_SRC]


def test_an_explicit_not_18_plus_still_wins(client, as_user, kid, seed_follow):
    """The source only fills in when the row says nothing: the owner's one-tap
    override outranks it for a removed source exactly as for an installed one."""
    uid, pid = kid
    seed_follow(uid, pid, source_id=RETIRED, series_key="s1", mature_override=False)

    payload = client.get("/library/series", headers=as_user(uid, pid)).json()
    items = payload.get("items", payload) if isinstance(payload, dict) else payload
    assert [r["source_id"] for r in items] == [RETIRED]
