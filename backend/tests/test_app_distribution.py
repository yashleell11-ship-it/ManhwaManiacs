from __future__ import annotations

import json
import os
import re
import struct
import zipfile
from datetime import datetime, timezone
from html import escape
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from database.session import get_db
from main import create_app
from routes import app_distribution


@pytest.fixture
def client(db_engine):
    session_factory = sessionmaker(bind=db_engine, autoflush=False, autocommit=False)

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


def test_app_version_payload(client: TestClient):
    response = client.get("/app/version")
    assert response.status_code == 200
    data = response.json()
    assert data["apk"] == "/app/download"
    assert isinstance(data["build"], int)
    assert isinstance(data["version"], str) and data["version"]


def _installable_apk(tmp_path: Path, monkeypatch, size: int = 4096) -> Path:
    apk = tmp_path / "app-release.apk"
    apk.write_bytes(b"PK\x03\x04" + b"\0" * (size - 4))
    monkeypatch.setattr("routes.app_distribution.APK_PATH", apk)
    return apk


def test_root_serves_the_install_page(client: TestClient, tmp_path: Path, monkeypatch):
    _installable_apk(tmp_path, monkeypatch)

    response = client.get("/", headers={"accept": "text/html"})
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert "ManhwaManiacs" in response.text
    assert "/app/download" in response.text


def test_root_serves_html_regardless_of_accept_header(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # This is the whole point of the route: `/` is the URL people are *handed*
    # to install the app, so it must be a page for every caller -- not only ones
    # that happen to ask for text/html. It used to content-negotiate, which left
    # curl, link previews and terse in-app webviews staring at raw JSON.
    _installable_apk(tmp_path, monkeypatch)

    for accept in ("*/*", "application/json", "", "text/plain"):
        response = client.get("/", headers={"accept": accept})
        assert response.status_code == 200, accept
        assert "text/html" in response.headers["content-type"], accept
        assert "<!doctype html>" in response.text.lower(), accept


def test_install_page_shows_both_platforms_and_the_web_app(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # Both routes are always offered and always labelled. Nothing here sniffs a
    # user agent to hide the "wrong" one: a phone lying about itself, or a friend
    # on a desktop sending the link on, must still see how to install on either.
    _installable_apk(tmp_path, monkeypatch)
    html = client.get("/").text

    assert "<h2>Android</h2>" in html
    assert "<h2>iPhone</h2>" in html
    # The zero-install option gets its own link -- for many visitors it is the
    # right answer, and it is the only one that works while a build is missing.
    assert app_distribution.WEB_APP_URL in html


def test_install_page_reads_its_version_live(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # The page and /app/version must never be able to disagree: both read the
    # pubspec at request time. Asserted against a pubspec this test writes, so a
    # hardcoded version anywhere in the page would fail here rather than quietly
    # advertising a build nobody can download.
    _installable_apk(tmp_path, monkeypatch)
    pubspec = tmp_path / "pubspec.yaml"
    pubspec.write_text("name: manhwamaniacs\nversion: 7.3.1+404\n", encoding="utf-8")
    monkeypatch.setattr("routes.app_distribution.PUBSPEC_PATH", pubspec)

    html = client.get("/").text
    assert "7.3.1" in html
    assert "404" in html
    assert client.get("/app/version").json() == {
        "version": "7.3.1",
        "build": 404,
        "apk": "/app/download",
    }


def _compiled_manifest(version_name: str, version_code: int, *, utf8: bool) -> bytes:
    """A binary AndroidManifest.xml carrying just ``<manifest>`` and its version.

    Laid out the way aapt2 writes one: a string pool, the resource-id map that
    names the android: attributes, then the root start tag.
    """
    strings = ["versionCode", "versionName", "manifest", version_name]
    data = b""
    offsets = []
    for text in strings:
        offsets.append(len(data))
        if utf8:
            raw = text.encode("utf-8")
            data += bytes([len(text), len(raw)]) + raw + b"\0"
        else:
            data += struct.pack("<H", len(text)) + text.encode("utf-16-le") + b"\0\0"
    data += b"\0" * (-len(data) % 4)
    header = 28 + 4 * len(strings)
    pool = struct.pack(
        "<HHIIIIII",
        0x0001, 28, header + len(data), len(strings), 0,
        0x100 if utf8 else 0, header, 0,
    ) + struct.pack(f"<{len(strings)}I", *offsets) + data
    ids = struct.pack("<HHI2I", 0x0180, 8, 16, 0x0101021B, 0x0101021C)
    attrs = struct.pack("<IIIHBBI", 0xFFFFFFFF, 0, 0xFFFFFFFF, 8, 0, 0x10, version_code)
    attrs += struct.pack("<IIIHBBI", 0xFFFFFFFF, 1, 3, 8, 0, 0x03, 3)
    element = struct.pack(
        "<HHIIIIIHHHHHH",
        0x0102, 16, 36 + len(attrs), 1, 0xFFFFFFFF,
        0xFFFFFFFF, 2, 20, 20, 2, 0, 0, 0,
    ) + attrs
    body = pool + ids + element
    return struct.pack("<HHI", 0x0003, 8, 8 + len(body)) + body


def _released_apk(
    tmp_path: Path, monkeypatch, version: str, build: int, *, utf8: bool = False
) -> Path:
    apk = tmp_path / "app-release.apk"
    with zipfile.ZipFile(apk, "w") as archive:
        archive.writestr(
            "AndroidManifest.xml", _compiled_manifest(version, build, utf8=utf8)
        )
    monkeypatch.setattr("routes.app_distribution.APK_PATH", apk)
    return apk


@pytest.mark.parametrize("utf8", [False, True])
def test_phones_are_only_offered_the_build_the_download_serves(
    client: TestClient, tmp_path: Path, monkeypatch, utf8: bool
):
    # `push.sh all` puts the new pubspec on the box minutes before `push.sh apk`
    # publishes the binary, and for good if an APK gate refuses it. Phones decide
    # on `build` alone, so advertising the pubspec's offered every phone an
    # update that downloaded the APK it already had -- and then offered it again.
    pubspec = tmp_path / "pubspec.yaml"
    pubspec.write_text("name: manhwamaniacs\nversion: 7.3.2+405\n", encoding="utf-8")
    monkeypatch.setattr("routes.app_distribution.PUBSPEC_PATH", pubspec)
    _released_apk(tmp_path, monkeypatch, "7.3.1", 404, utf8=utf8)

    advertised = client.get("/app/version").json()
    assert advertised["build"] == 404
    # The release name stays the pubspec's: ops/vps/deploy.sh proves a deploy by
    # matching it against the compiled changelog while the old APK is still up.
    assert advertised["version"] == "7.3.2"

    disposition = client.get("/app/download").headers["content-disposition"]
    assert "manhwamaniacs-7.3.1.apk" in disposition

    html = client.get("/").text
    assert "Version 7.3.1 · build 404" in html
    assert "7.3.2" not in html


def test_a_new_apk_is_offered_as_soon_as_it_is_served(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # The other half: the number follows the file, so publishing the APK is the
    # whole update even before the pubspec catches up.
    pubspec = tmp_path / "pubspec.yaml"
    pubspec.write_text("name: manhwamaniacs\nversion: 7.3.1+404\n", encoding="utf-8")
    monkeypatch.setattr("routes.app_distribution.PUBSPEC_PATH", pubspec)
    apk = _released_apk(tmp_path, monkeypatch, "7.3.1", 404)
    assert client.get("/app/version").json()["build"] == 404

    replacement = tmp_path / "next.apk"
    with zipfile.ZipFile(replacement, "w") as archive:
        archive.writestr(
            "AndroidManifest.xml", _compiled_manifest("7.3.2", 405, utf8=False)
        )
    replacement.replace(apk)

    assert client.get("/app/version").json()["build"] == 405


def test_install_page_reports_the_real_file_size_and_date(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # "40 MB, updated today" is only useful if it is true, so both come off the
    # file's own stat rather than a constant somebody has to remember to edit.
    apk = _installable_apk(tmp_path, monkeypatch, size=3 * 1024 * 1024)
    when = datetime(2026, 3, 9, 12, 0, tzinfo=timezone.utc)
    os.utime(apk, (when.timestamp(), when.timestamp()))

    html = client.get("/").text
    assert "3.0 MB" in html
    assert "9 Mar 2026" in html


def test_install_page_says_so_when_the_android_build_is_missing(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # No dead button: an absent artifact is stated plainly instead of offering a
    # link that 404s on the visitor.
    monkeypatch.setattr("routes.app_distribution.APK_PATH", tmp_path / "missing.apk")
    response = client.get("/")

    assert response.status_code == 200
    assert "No Android build published yet." in response.text
    assert 'href="/app/download"' not in response.text
    # ...and the page still stands up: name, the other platform, the website.
    assert "ManhwaManiacs" in response.text
    assert "<h2>iPhone</h2>" in response.text


def test_install_page_says_so_when_the_ios_build_is_missing(
    client: TestClient, tmp_path: Path, monkeypatch
):
    _installable_apk(tmp_path, monkeypatch)
    monkeypatch.setattr("routes.app_distribution.IPA_PATH", tmp_path / "missing.ipa")

    html = client.get("/").text
    assert "No iPhone build published yet." in html
    # Walking someone through adding a SideStore source that contains nothing
    # installable is worse than telling them there is no build.
    assert "/app/source.json" not in html


def test_install_page_describes_the_published_ios_build(
    client: TestClient, tmp_path: Path, monkeypatch
):
    _installable_apk(tmp_path, monkeypatch)
    ipa = tmp_path / "ManhwaManiacs.ipa"
    ipa.write_bytes(b"PK\x03\x04" + b"\0" * (2 * 1024 * 1024))
    monkeypatch.setattr("routes.app_distribution.IPA_PATH", ipa)
    (tmp_path / "ios-build.json").write_text(
        json.dumps({"version": "9.9.9", "buildVersion": "1042", "date": "2026-01-02"}),
        encoding="utf-8",
    )
    monkeypatch.delenv("MM_IOS_META_PATH", raising=False)
    monkeypatch.setenv("MM_PUBLIC_BASE_URL", "https://app.manhwamaniacs.xyz")

    html = client.get("/").text
    # The feed address is pasted into another app, so it has to be absolute --
    # a relative path is meaningless once it leaves this page.
    assert "https://app.manhwamaniacs.xyz/app/source.json" in html
    # The numbers describe the .ipa CI published, not this server's pubspec.
    assert "9.9.9 (build 1042)" in html
    assert "2 Jan 2026" in html
    assert client.get("/app/version").json()["version"] != "9.9.9"


def test_install_page_shows_the_newest_release_notes(
    client: TestClient, tmp_path: Path, monkeypatch
):
    _installable_apk(tmp_path, monkeypatch)
    newest = client.get("/app/changelog").json()["entries"][0]

    html = client.get("/").text
    assert f"What's new in {newest['version']}" in html
    for highlight in newest["highlights"]:
        # Escape the expectation rather than requiring release notes to avoid
        # apostrophes: the page escapes what it renders, and a prefix rule that
        # silently fails on "GitHub's" sent three correct changelogs back as
        # broken. This asserts the whole highlight is present, not a prefix.
        assert escape(highlight) in html


def test_install_page_omits_screenshots_it_cannot_serve(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # The screenshots are a bind mount in production. An unmounted one must give
    # a page with no pictures, not a page of broken-image icons.
    _installable_apk(tmp_path, monkeypatch)
    empty = tmp_path / "no-screenshots"
    empty.mkdir()
    monkeypatch.setattr("routes.app_distribution.SCREENSHOTS_DIR", empty)

    html = client.get("/").text
    assert "/app/media/" not in html
    assert "<h2>Android</h2>" in html


def test_install_page_makes_no_external_requests(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # Served behind a strict CSP, and read on whatever connection the visitor
    # has. A font CDN or a stray script tag would be a page that renders wrong
    # exactly when it matters. Hyperlinks are fine; loaded subresources are not.
    _installable_apk(tmp_path, monkeypatch)
    html = client.get("/").text

    assert "<script" not in html.lower()
    for attr in re.findall(r'\b(?:src|href)="([^"]+)"', html):
        if attr.startswith(("#", "/")):
            continue
        # The only absolute URLs on the page are things you click, not fetch.
        assert attr in (
            app_distribution.WEB_APP_URL,
            app_distribution.SIDESTORE_URL,
        ) or attr.endswith("/app/source.json"), attr


def test_changelog_payload(client: TestClient):
    response = client.get("/app/changelog")
    assert response.status_code == 200
    entries = response.json()["entries"]
    assert isinstance(entries, list) and entries
    first = entries[0]
    assert isinstance(first["version"], str) and first["version"]
    assert isinstance(first["build"], int)
    assert isinstance(first["highlights"], list) and first["highlights"]


def test_media_serves_known_screenshot(client: TestClient, tmp_path: Path, monkeypatch):
    shots = tmp_path / "screenshots"
    shots.mkdir()
    (shots / "shot-library-screenshot.png").write_bytes(b"\x89PNG\r\n\x1a\n fake png")
    monkeypatch.setattr("routes.app_distribution.SCREENSHOTS_DIR", shots)

    response = client.get("/app/media/shot-library-screenshot.png")
    assert response.status_code == 200
    assert response.content.startswith(b"\x89PNG")


def test_media_rejects_traversal_and_unknown_types(
    client: TestClient, tmp_path: Path, monkeypatch
):
    shots = tmp_path / "screenshots"
    shots.mkdir()
    (shots / "ok.png").write_bytes(b"\x89PNG fake")
    (tmp_path / "secret.txt").write_text("top secret")
    monkeypatch.setattr("routes.app_distribution.SCREENSHOTS_DIR", shots)

    # Path traversal is neutralised (only the basename is ever used).
    assert client.get("/app/media/../secret.txt").status_code in (404, 400)
    # Non-image extensions are refused even if present in the directory.
    (shots / "notes.txt").write_text("nope")
    assert client.get("/app/media/notes.txt").status_code == 404
    # Missing files 404.
    assert client.get("/app/media/does-not-exist.png").status_code == 404


def test_json_status_lives_at_health(client: TestClient):
    # `/` is a page now, so this is the JSON status payload's only home. It is
    # what every consumer already uses -- the mobile server-URL probe, the
    # backend healthcheck in both compose files, ops/vps/deploy.sh -- which is
    # what made moving `/` off JSON safe.
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "online"
    assert response.json()["name"]
    assert response.json()["version"]


def test_download_returns_404_when_apk_missing(
    client: TestClient, tmp_path: Path, monkeypatch
):
    monkeypatch.setattr("routes.app_distribution.APK_PATH", tmp_path / "missing.apk")
    response = client.get("/app/download")
    assert response.status_code == 404


def test_download_serves_latest_apk(client: TestClient, tmp_path: Path, monkeypatch):
    apk = tmp_path / "app-release.apk"
    apk.write_bytes(b"PK\x03\x04 latest build")
    monkeypatch.setattr("routes.app_distribution.APK_PATH", apk)

    response = client.get("/app/download")
    assert response.status_code == 200
    assert response.content == b"PK\x03\x04 latest build"
    assert "application/vnd.android.package-archive" in response.headers["content-type"]
    assert ".apk" in response.headers.get("content-disposition", "")


def test_download_treats_directory_path_as_not_built(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # In production the APK is a read-only bind mount; when no APK has been built
    # the mount surfaces as an (empty) directory, not a file. That must read as
    # "not built yet" (404), never a 500 from trying to stream a directory.
    apk_dir = tmp_path / "apk" / "app-release.apk"
    apk_dir.mkdir(parents=True)
    monkeypatch.setattr("routes.app_distribution.APK_PATH", apk_dir)

    assert client.get("/app/download").status_code == 404
    # The install page still renders, and offers no button it cannot honour.
    landing = client.get("/")
    assert landing.status_code == 200
    assert "No Android build published yet." in landing.text


# ── iOS / SideStore source ───────────────────────────────────────────────────


def _fake_ipa(tmp_path: Path, monkeypatch) -> Path:
    ipa = tmp_path / "ManhwaManiacs.ipa"
    ipa.write_bytes(b"PK\x03\x04 fake ipa bytes")
    monkeypatch.setattr("routes.app_distribution.IPA_PATH", ipa)
    # The metadata is looked up beside the .ipa; make sure a stray env override
    # from the host can't point these tests at a real deploy's file.
    monkeypatch.delenv("MM_IOS_META_PATH", raising=False)
    return ipa


def test_ios_source_lists_published_build(
    client: TestClient, tmp_path: Path, monkeypatch
):
    ipa = _fake_ipa(tmp_path, monkeypatch)
    monkeypatch.setenv("MM_PUBLIC_BASE_URL", "https://app.manhwamaniacs.xyz")

    source = client.get("/app/source.json").json()
    assert source["name"] == "ManhwaManiacs"
    assert source["news"] == []

    app = source["apps"][0]
    # Bundle id must match the Xcode project or SideStore treats an update as a
    # separate app instead of replacing the installed one.
    assert app["bundleIdentifier"] == "com.manhwamaniacs.reader"

    version = app["versions"][0]
    assert version["downloadURL"] == (
        "https://app.manhwamaniacs.xyz/app/ios/download"
    )
    assert version["size"] == ipa.stat().st_size
    # No CI metadata beside this .ipa, so the pubspec numbers are the fallback.
    assert version["version"] == client.get("/app/version").json()["version"]
    assert version["buildVersion"] == str(client.get("/app/version").json()["build"])


def test_ios_source_advertises_ci_build_metadata(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # The whole point of the metadata file: the build number CI stamped into the
    # binary is what gets advertised, *not* this server's pubspec. Without it,
    # pushing code would never surface an update on the phone.
    _fake_ipa(tmp_path, monkeypatch)
    (tmp_path / "ios-build.json").write_text(
        json.dumps(
            {
                "version": "9.9.9",
                "buildVersion": "1042",
                "date": "2026-01-02",
                "commit": "deadbee",
                "runId": "5",
            }
        ),
        encoding="utf-8",
    )

    version = client.get("/app/source.json").json()["apps"][0]["versions"][0]
    assert version["version"] == "9.9.9"
    assert version["buildVersion"] == "1042"
    assert version["date"] == "2026-01-02"
    # ...and the pubspec numbers it overrode are genuinely different, so this
    # test would fail if the fallback path were silently taken.
    assert client.get("/app/version").json()["version"] != "9.9.9"


def test_ios_source_survives_unusable_metadata(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # A half-written or garbled metadata file must degrade to the pubspec
    # numbers, never 500 — a broken source URL takes SideStore out entirely.
    _fake_ipa(tmp_path, monkeypatch)
    pubspec = client.get("/app/version").json()

    for junk in ("not json at all", "[]", '{"buildVersion": "not-a-number"}'):
        (tmp_path / "ios-build.json").write_text(junk, encoding="utf-8")
        response = client.get("/app/source.json")
        assert response.status_code == 200, junk
        version = response.json()["apps"][0]["versions"][0]
        assert version["version"] == pubspec["version"], junk
        assert version["buildVersion"] == str(pubspec["build"]), junk


def test_ios_download_filename_names_the_published_build(
    client: TestClient, tmp_path: Path, monkeypatch
):
    _fake_ipa(tmp_path, monkeypatch)
    (tmp_path / "ios-build.json").write_text(
        json.dumps({"version": "9.9.9", "buildVersion": "1042"}), encoding="utf-8"
    )

    disposition = client.get("/app/ios/download").headers.get("content-disposition", "")
    assert "manhwamaniacs-9.9.9-1042.ipa" in disposition


def test_ios_source_uses_request_origin_when_unconfigured(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # Without MM_PUBLIC_BASE_URL the manifest must still emit absolute URLs —
    # they are fetched by the phone, so a relative path would be unusable.
    _fake_ipa(tmp_path, monkeypatch)
    monkeypatch.delenv("MM_PUBLIC_BASE_URL", raising=False)

    version = client.get("/app/source.json").json()["apps"][0]["versions"][0]
    assert version["downloadURL"].startswith("http")
    assert version["downloadURL"].endswith("/app/ios/download")


def test_ios_source_valid_with_no_build_published(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # A source with no installable version is still a *valid* source; SideStore
    # must be able to add it rather than erroring on an unpublished app.
    monkeypatch.setattr("routes.app_distribution.IPA_PATH", tmp_path / "missing.ipa")

    source = client.get("/app/source.json")
    assert source.status_code == 200
    assert source.json()["apps"][0]["versions"] == []
    assert client.get("/app/ios/download").status_code == 404


def test_ios_download_serves_ipa(client: TestClient, tmp_path: Path, monkeypatch):
    _fake_ipa(tmp_path, monkeypatch)
    response = client.get("/app/ios/download")
    assert response.status_code == 200
    assert response.content == b"PK\x03\x04 fake ipa bytes"
    assert ".ipa" in response.headers.get("content-disposition", "")


def test_ios_download_treats_directory_path_as_not_published(
    client: TestClient, tmp_path: Path, monkeypatch
):
    # Same failure mode as the APK: an empty read-only bind mount is a directory.
    ipa_dir = tmp_path / "ipa" / "ManhwaManiacs.ipa"
    ipa_dir.mkdir(parents=True)
    monkeypatch.setattr("routes.app_distribution.IPA_PATH", ipa_dir)
    assert client.get("/app/ios/download").status_code == 404
