"""Server-side source pins: scoping, ordering, validation, and routing.

Pins are per (account, profile) like every other user-owned row: two accounts
never see each other's pins, and neither do two profiles on one account. The
routes are driven over real HTTP with a real session so the ``/sources/pins``
declaration order and the X-Profile-Id enforcement are exercised end to end.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from core.config import get_settings
from database.models import SourcePin
from database.session import get_db
from main import create_app

PIN_REGISTRY = "services.source_pin_service.list_installed_connectors"


class _FakeDescriptor:
    def __init__(self, source_type: str, *, mature: bool = False) -> None:
        self.source_type = source_type
        self.name = source_type.title()
        self.mature = mature
        self.browsable = True
        self.icon_url = f"/static/sources/{source_type}.png"


def _fake_registry(*descriptors: _FakeDescriptor):
    def _fake(*, browsable_only: bool = False, include_mature: bool = True):
        out = list(descriptors)
        if not include_mature:
            out = [d for d in out if not d.mature]
        return out

    return _fake


def _make_client(db_engine) -> tuple[TestClient, sessionmaker]:
    factory = sessionmaker(bind=db_engine, autoflush=False, autocommit=False)

    def override_get_db():
        db = factory()
        try:
            yield db
        finally:
            db.close()

    app = create_app(run_migrations=False, run_workers=False)
    app.dependency_overrides[get_db] = override_get_db
    return TestClient(app), factory


def _register(client: TestClient, username: str) -> int:
    response = client.post(
        "/auth/register", json={"username": username, "password": "supersecret"}
    )
    assert response.status_code in (200, 201), response.text
    return int(response.json()["user"]["id"])


@pytest.mark.real_auth
class TestSourcePins:
    @pytest.fixture
    def env(self, db_engine, monkeypatch):
        monkeypatch.setenv("MM_COOKIE_SECURE", "false")
        get_settings.cache_clear()
        client, factory = _make_client(db_engine)
        user_id = _register(client, "owner")
        yield {"client": client, "factory": factory, "user_id": user_id}
        get_settings.cache_clear()

    # --- reads / writes ------------------------------------------------------

    def test_pins_start_empty(self, env):
        response = env["client"].get("/sources/pins")
        assert response.status_code == 200, response.text
        assert response.json() == []

    def test_replace_pins_sets_order_and_display_metadata(self, env):
        client = env["client"]

        response = client.put(
            "/sources/pins", json={"source_ids": ["mangadex", "asurascans"]}
        )
        assert response.status_code == 200, response.text
        pins = response.json()

        assert [pin["source_id"] for pin in pins] == ["mangadex", "asurascans"]
        assert [pin["sort_order"] for pin in pins] == [0, 1]
        assert pins[0]["name"] == "MangaDex"
        assert pins[0]["available"] is True
        assert pins[0]["icon_url"]
        assert all(isinstance(pin["mature"], bool) for pin in pins)
        # The read path returns exactly what the write path reported.
        assert client.get("/sources/pins").json() == pins

    def test_replace_pins_replaces_the_whole_set(self, env):
        client = env["client"]
        client.put("/sources/pins", json={"source_ids": ["mangadex", "asurascans"]})

        pins = client.put("/sources/pins", json={"source_ids": ["asurascans"]}).json()

        assert [pin["source_id"] for pin in pins] == ["asurascans"]
        assert pins[0]["sort_order"] == 0
        assert client.put("/sources/pins", json={"source_ids": []}).json() == []

    def test_duplicate_ids_are_collapsed(self, env):
        pins = env["client"].put(
            "/sources/pins", json={"source_ids": ["mangadex", "mangadex"]}
        ).json()

        assert [pin["source_id"] for pin in pins] == ["mangadex"]

    def test_unknown_source_is_rejected(self, env):
        response = env["client"].put(
            "/sources/pins", json={"source_ids": ["mangadex", "not-a-source"]}
        )

        assert response.status_code == 422, response.text
        body = response.json()
        assert body["code"] == "unknown_source"
        assert body["details"]["source_ids"] == ["not-a-source"]
        # Nothing was written: the whole set is validated before it is applied.
        assert env["client"].get("/sources/pins").json() == []

    def _seed_pin(self, env, source_id: str, sort_order: int) -> None:
        db = env["factory"]()
        try:
            db.add(
                SourcePin(
                    user_id=env["user_id"],
                    profile_id=None,
                    source_id=source_id,
                    sort_order=sort_order,
                )
            )
            db.commit()
        finally:
            db.close()

    def _stored_ids(self, env) -> set[str]:
        db = env["factory"]()
        try:
            return {pin.source_id for pin in db.query(SourcePin).all()}
        finally:
            db.close()

    def test_a_pin_on_a_removed_source_is_not_served(self, env):
        """``source_id`` is a connector key, not an FK. A pin whose connector was
        unregistered (linkmanga, lilymanga) is left out of the list rather than
        served as a dead row the user has to find and drop first."""
        self._seed_pin(env, "retired-source", 0)
        self._seed_pin(env, "asurascans", 1)

        pins = env["client"].get("/sources/pins").json()

        assert [pin["source_id"] for pin in pins] == ["asurascans"]
        assert pins[0]["available"] is True

    def test_a_removed_source_does_not_block_later_pins_or_unpins(self, env):
        """Both clients rebuild the whole set from the list they were given. One
        that still holds the dead id sends it back with every edit, and that
        used to refuse the whole request as "Unknown source."."""
        client = env["client"]
        self._seed_pin(env, "retired-source", 0)
        self._seed_pin(env, "asurascans", 1)

        pinned = client.put(
            "/sources/pins",
            json={"source_ids": ["retired-source", "asurascans", "mangadex"]},
        )
        assert pinned.status_code == 200, pinned.text
        assert [p["source_id"] for p in pinned.json()] == ["asurascans", "mangadex"]

        unpinned = client.put(
            "/sources/pins", json={"source_ids": ["retired-source", "mangadex"]}
        )
        assert unpinned.status_code == 200, unpinned.text
        assert [p["source_id"] for p in unpinned.json()] == ["mangadex"]

        # A client that has the new list (no dead id) edits freely too, and the
        # dead row is left alone rather than deleted, so it would come back if
        # its connector did.
        assert client.put("/sources/pins", json={"source_ids": []}).status_code == 200
        assert self._stored_ids(env) == {"retired-source"}

        # A NEW unresolvable id is still an error.
        assert (
            client.put(
                "/sources/pins", json={"source_ids": ["another-retired"]}
            ).status_code
            == 422
        )

    def test_mature_source_cannot_be_pinned_when_the_gate_is_off(self, env, monkeypatch):
        monkeypatch.setenv("MM_MATURE_CONTENT_ENABLED", "false")
        get_settings.cache_clear()
        registry = _fake_registry(
            _FakeDescriptor("safe"), _FakeDescriptor("adult", mature=True)
        )

        with patch(PIN_REGISTRY, registry):
            rejected = env["client"].put("/sources/pins", json={"source_ids": ["adult"]})
            accepted = env["client"].put("/sources/pins", json={"source_ids": ["safe"]})

        assert rejected.status_code == 422
        assert rejected.json()["details"]["source_ids"] == ["adult"]
        assert [pin["source_id"] for pin in accepted.json()] == ["safe"]

    # --- routing -------------------------------------------------------------

    def test_pins_path_is_not_captured_as_a_source_id(self, env):
        """``/sources/pins`` must resolve to the pins routes, not to the
        ``/{source_id}`` family declared after them."""
        client = env["client"]

        assert client.get("/sources/pins").status_code == 200
        assert client.put("/sources/pins", json={"source_ids": []}).status_code == 200
        # The /{source_id} family still resolves normally around them.
        assert client.get("/sources/mangadex/browse-modes").status_code == 200
        assert client.get("/sources/pins/browse-modes").status_code == 404

    # --- scoping -------------------------------------------------------------

    def test_pins_are_isolated_between_accounts(self, env, db_engine):
        env["client"].put("/sources/pins", json={"source_ids": ["mangadex"]})

        other, _ = _make_client(db_engine)
        _register(other, "stranger")

        # A brand-new account sees nothing the first account pinned.
        assert other.get("/sources/pins").json() == []
        other.put("/sources/pins", json={"source_ids": ["asurascans"]})
        assert [p["source_id"] for p in other.get("/sources/pins").json()] == [
            "asurascans"
        ]
        # ... and the first account is untouched.
        assert [p["source_id"] for p in env["client"].get("/sources/pins").json()] == [
            "mangadex"
        ]

    def test_pins_are_isolated_between_profiles(self, env):
        client = env["client"]
        alpha = client.post("/profiles", json={"name": "Alpha"}).json()["id"]
        beta = client.post("/profiles", json={"name": "Beta"}).json()["id"]

        client.put(
            "/sources/pins",
            json={"source_ids": ["mangadex"]},
            headers={"X-Profile-Id": str(alpha)},
        )

        assert client.get(
            "/sources/pins", headers={"X-Profile-Id": str(beta)}
        ).json() == []
        assert [
            pin["source_id"]
            for pin in client.get(
                "/sources/pins", headers={"X-Profile-Id": str(alpha)}
            ).json()
        ] == ["mangadex"]

    def test_write_requires_an_active_profile(self, env):
        client = env["client"]
        client.post("/profiles", json={"name": "Alpha"})

        # The account owns profiles, so a write must name the one it is for.
        missing = client.put("/sources/pins", json={"source_ids": ["mangadex"]})
        assert missing.status_code == 400
        assert missing.json()["code"] == "profile_required"

        foreign = client.put(
            "/sources/pins",
            json={"source_ids": ["mangadex"]},
            headers={"X-Profile-Id": "99999"},
        )
        assert foreign.status_code == 404
        assert foreign.json()["code"] == "profile_not_found"
