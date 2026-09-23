"""The two scripts that put a build in front of phones publish in a safe order.

Both advertise a version through a file that sits beside the binary it
describes, and both used to be able to leave that description pointing at a
build the box was not serving: ``push.sh apk`` synced the pubspec before the APK
upload, and ``fetch-ios-build.sh`` published an .ipa, and stamped its release
done, when the release's ios-build.json had failed to download.

These run the real scripts against stand-ins for curl/ssh/scp/rsync, so what is
asserted is what lands in the destination, not what the source says.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[2] / "ops"

pytestmark = pytest.mark.skipif(
    shutil.which("bash") is None or shutil.which("unzip") is None,
    reason="needs bash and unzip",
)


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


# ── fetch-ios-build.sh ───────────────────────────────────────────────────────

# Behaves like curl for the flags the script uses: -o, and -f turning an HTTP
# error into exit 22 with nothing written. Without -f a real curl saves the
# error page and exits 0, which is exactly the case under test.
_FAKE_CURL = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
routes = json.load(open(os.environ["FAKE_CURL_ROUTES"]))
fail = any(a.startswith("-") and not a.startswith("--") and "f" in a for a in args)
out = args[args.index("-o") + 1] if "-o" in args else None
url = [a for a in args if a.startswith("http")][-1]
status, body = routes[url]
if status >= 400 and fail:
    sys.stderr.write(f"curl: (22) The requested URL returned error: {status}\\n")
    sys.exit(22)
# latin-1 so a zip survives the trip through the JSON route table byte for byte.
data = body.encode("latin-1")
if out:
    open(out, "wb").write(data)
else:
    sys.stdout.buffer.write(data)
"""

_TAG_OLD = "ios-build-1085"
_TAG_NEW = "ios-build-1086"


def _ipa_bytes(marker: str) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        archive.writestr("Payload/Runner.app/marker", marker)
    return buf.getvalue()


def _run_fetch(tmp_path: Path, meta: tuple[int, str]) -> subprocess.CompletedProcess:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    _stub(bin_dir, "curl", _FAKE_CURL)
    new_ipa = tmp_path / "new.ipa"
    new_ipa.write_bytes(_ipa_bytes("1086"))
    release = {
        "tag_name": _TAG_NEW,
        "assets": [
            {"name": "ManhwaManiacs.ipa", "browser_download_url": "https://dl/ipa"},
            {"name": "ios-build.json", "browser_download_url": "https://dl/meta"},
        ],
    }
    routes = {
        "https://api.github.com/repos/o/r/releases/latest": [200, json.dumps(release)],
        "https://dl/ipa": [200, new_ipa.read_bytes().decode("latin-1")],
        "https://dl/meta": list(meta),
    }
    routes_file = tmp_path / "routes.json"
    routes_file.write_text(json.dumps(routes), encoding="utf-8")

    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HOME": str(home),
        "TMPDIR": str(tmp_path),
        "GH_TOKEN": "",
        "GITHUB_TOKEN": "",
        "MM_IOS_REPO": "o/r",
        "FAKE_CURL_ROUTES": str(routes_file),
    }
    return subprocess.run(
        ["bash", str(OPS / "fetch-ios-build.sh"), str(tmp_path / "dest")],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )


def _published_release(tmp_path: Path) -> Path:
    dest = tmp_path / "dest"
    dest.mkdir()
    (dest / "ManhwaManiacs.ipa").write_bytes(_ipa_bytes("1085"))
    (dest / "ios-build.json").write_text(
        json.dumps({"version": "3.3.0", "buildVersion": "1085"}), encoding="utf-8"
    )
    (dest / ".published-run").write_text(_TAG_OLD + "\n", encoding="utf-8")
    return dest


def _ipa_marker(dest: Path) -> str:
    with zipfile.ZipFile(dest / "ManhwaManiacs.ipa") as archive:
        return archive.read("Payload/Runner.app/marker").decode()


def test_ios_release_is_not_published_when_its_metadata_fails(tmp_path: Path):
    # The asset host answers the metadata with an error page. Publishing the
    # .ipa anyway left 1085's ios-build.json describing 1086's binary, and the
    # stamp then marked 1086 done, so no run ever fetched its metadata again:
    # SideStore never offered the update until the next CI release.
    dest = _published_release(tmp_path)

    result = _run_fetch(tmp_path, (502, "<html>Bad gateway</html>"))

    assert result.returncode != 0, result.stdout + result.stderr
    assert (dest / ".published-run").read_text().strip() == _TAG_OLD
    assert _ipa_marker(dest) == "1085"
    assert json.loads((dest / "ios-build.json").read_text())["buildVersion"] == "1085"

    # ...and because nothing was stamped, the next run picks the release up.
    result = _run_fetch(
        tmp_path, (200, json.dumps({"version": "3.3.1", "buildVersion": "1086"}))
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (dest / ".published-run").read_text().strip() == _TAG_NEW
    assert _ipa_marker(dest) == "1086"
    assert json.loads((dest / "ios-build.json").read_text())["buildVersion"] == "1086"


# ── push.sh apk ──────────────────────────────────────────────────────────────

_RECORDER = """#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$PUSH_LOG"
"""


def test_push_apk_publishes_the_binary_before_the_pubspec(tmp_path: Path):
    # The pubspec names the release /app/version reports. Synced before the
    # upload, it named a release the box could not serve for as long as the
    # 43 MB scp took -- and for good if the scp then failed.
    repo = tmp_path / "repo"
    (repo / "ops" / "vps").mkdir(parents=True)
    shutil.copy(OPS / "vps" / "push.sh", repo / "ops" / "vps" / "push.sh")
    (repo / "mobile").mkdir()
    (repo / "mobile" / "pubspec.yaml").write_text(
        "name: manhwamaniacs\nversion: 3.3.1+53\n", encoding="utf-8"
    )
    apk_dir = repo / "mobile" / "build" / "app" / "outputs" / "flutter-apk"
    apk_dir.mkdir(parents=True)
    with zipfile.ZipFile(apk_dir / "app-release.apk", "w") as apk:
        for abi in ("arm64-v8a", "armeabi-v7a"):
            apk.writestr(f"lib/{abi}/libflutter.so", b"engine")
            apk.writestr(f"lib/{abi}/libapp.so", b"https://app.manhwamaniacs.xyz")

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in ("rsync", "scp", "ssh"):
        _stub(bin_dir, tool, _RECORDER)
    log = tmp_path / "push.log"
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HOME": str(tmp_path),
        # No aapt2 here: the version gate notes that and moves on.
        "ANDROID_HOME": str(tmp_path / "no-sdk"),
        "MM_APK_NO_BUILD": "1",
        "MM_VPS_HOST": "box",
        "PUSH_LOG": str(log),
    }

    result = subprocess.run(
        ["bash", str(repo / "ops" / "vps" / "push.sh"), "apk"],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    calls = log.read_text().splitlines()
    upload = next(i for i, c in enumerate(calls) if c.startswith("scp "))
    swap = next(i for i, c in enumerate(calls) if c.startswith("ssh ") and "mv -f" in c)
    pubspec = next(
        i for i, c in enumerate(calls) if c.startswith("rsync ") and "pubspec" in c
    )
    assert upload < swap < pubspec, calls
