#!/usr/bin/env python3
"""Exercise Sparkle's actual installer on an isolated A→B app in a macOS GUI session."""

import argparse
import base64
import functools
import http.server
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Tests" / "SparkleRoundTrip"
APP_NAME = "DualDock Update Test.app"


def run(*args, stdin=None):
    result = subprocess.run(args, input=stdin, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stdout} {result.stderr}")
    return result.stdout.strip()


def version(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]


def make_app(parent, number, tools, public_key, feed_url, log_directory, identifier):
    app = parent / APP_NAME
    contents = app / "Contents"
    for name in ("MacOS", "Frameworks", "Resources"):
        (contents / name).mkdir(parents=True, exist_ok=True)
    run(
        "xcrun",
        "clang",
        "-mmacosx-version-min=14",
        "-fobjc-arc",
        "-Werror",
        "-framework",
        "Cocoa",
        "-F",
        tools,
        "-framework",
        "Sparkle",
        "-Wl,-rpath,@executable_path/../Frameworks",
        f"-DFIXTURE_BUILD={number}",
        FIXTURE / "Driver.m",
        "-o",
        contents / "MacOS/Fixture",
    )
    run("ditto", tools / "Sparkle.framework", contents / "Frameworks/Sparkle.framework")
    info = {
        "CFBundleName": "DualDock Update Test",
        "CFBundlePackageType": "APPL",
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": "Fixture",
        "CFBundleVersion": str(number),
        "CFBundleShortVersionString": f"{number}.0",
        "LSUIElement": True,
        "LSMinimumSystemVersion": "14.0",
        "NSPrincipalClass": "NSApplication",
        "SUFeedURL": feed_url,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUPublicEDKey": public_key,
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        "FixtureOutputDirectory": str(log_directory),
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    run(
        "codesign",
        "--force",
        "--sign",
        "-",
        "--identifier",
        identifier,
        "--requirements",
        f'=designated => identifier "{identifier}"',
        app,
    )
    run("codesign", "--verify", "--strict", "--deep", app)
    return app


def write_feed(archive, base_url, sign, archive_signature, tamper=False, build="2", marketing="2.0"):
    xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Fixture</title><item><title>Fixture {marketing}</title>
<sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{marketing}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{base_url}/release.dmg" sparkle:edSignature="{archive_signature}" length="{archive.stat().st_size}" type="application/octet-stream"/>
</item></channel></rss>'''
    path = archive.with_name("next.xml")
    path.write_text(xml)
    sign(path)
    if tamper:
        path.write_bytes(path.read_bytes().replace(b"Fixture 2.0", b"Fixture 3.0"))
    path.replace(archive.with_name("appcast.xml"))


def await_event(log_file, expected, timeout=60):
    deadline = time.monotonic() + timeout
    events = ""
    while time.monotonic() < deadline:
        events = log_file.read_text() if log_file.exists() else ""
        if expected in events:
            return events
        if (
            "start-error" in events
            or "executable-version-mismatch" in events
            or "not-found" in events
            or "missing-target" in events
            or (expected in {"updated-executable-ran", "updated-target-verified"} and "error " in events)
        ):
            break
        time.sleep(0.1)
    raise RuntimeError(f"Expected {expected!r}. Fixture events:\n{events}")


def exercise(root, tools, server, web, previous=None, candidate=None):
    seed = base64.b64encode(os.urandom(32)).decode() + "\n"
    run(
        "xcrun",
        "swiftc",
        FIXTURE / "PublicKey.swift",
        "-module-cache-path",
        root / "modules",
        "-o",
        root / "PublicKey",
    )
    public_key = run(root / "PublicKey", stdin=seed)

    def sign(path):
        return run(
            tools / "bin/sign_update", "--ed-key-file", "-", "-p", path, stdin=seed
        )

    base_url = f"http://127.0.0.1:{server.server_port}"
    identifier = "local.dualdock.updatefixture." + uuid.uuid4().hex
    if previous is not None:
        exercise_artifact_update(root, web, tools, base_url, sign, public_key, identifier, previous, candidate)
        return
    parameters = (tools, public_key, base_url + "/appcast.xml", root, identifier)
    installed = make_app(root / "installed", 1, *parameters)
    staged = make_app(root / "stage", 2, *parameters)
    (root / "stage/Applications").symlink_to("/Applications")
    (root / "stage/安装说明.txt").write_text("Test installation guide")
    (root / "stage/LICENSE.txt").write_text("Test fixture")
    archive = web / "release.dmg"
    run(
        "hdiutil",
        "create",
        "-volname",
        "DualDock Update Test",
        "-srcfolder",
        root / "stage",
        "-fs",
        "HFS+",
        "-format",
        "UDZO",
        archive,
    )
    archive_signature = sign(archive)
    log = root / "events.txt"

    def start():
        run("open", "-g", "-n", installed)

    def assert_unchanged():
        assert version(installed) == "1"
        assert "install-confirmed" not in log.read_text()
        assert "updated-executable-ran" not in log.read_text()
        run("codesign", "--verify", "--strict", "--deep", installed)
        # Allow the asynchronous termination initiated by the user driver to finish.
        time.sleep(0.8)
        log.unlink()

    write_feed(archive, base_url, sign, archive_signature, tamper=True)
    start()
    tampered = await_event(log, "error ")
    assert "offered 2" not in tampered and "downloading" not in tampered
    assert_unchanged()
    print("PASS altered feed rejected before update offer")

    write_feed(archive, base_url, sign, base64.b64encode(bytes(64)).decode())
    start()
    rejected = await_event(log, "signature-rejected")
    assert "offered 2" in rejected and "downloading" in rejected
    assert_unchanged()
    print("PASS signed feed with invalid DMG signature rejected; build 1 intact")

    write_feed(archive, base_url, sign, archive_signature)
    start()
    accepted = await_event(log, "updated-executable-ran")
    assert "install-confirmed" in accepted and version(installed) == "2"
    launch_events = [s for s in accepted.splitlines() if s.startswith("launched ")]
    assert len(launch_events) == 2
    assert launch_events[0].startswith(f"launched 1 {installed} ")
    assert launch_events[1].startswith(f"launched 2 {installed} ")
    assert launch_events[0].split()[-1] != launch_events[1].split()[-1]
    assert (installed / "Contents/MacOS/Fixture").read_bytes() == (
        staged / "Contents/MacOS/Fixture"
    ).read_bytes()
    run("codesign", "--verify", "--strict", "--deep", installed)
    print(
        "PASS valid signed update installed; build 2 executable relaunched at original path"
    )


def exercise_artifact_update(root, web, tools, base_url, sign, public_key, identifier, previous, candidate):
    """Test real app binaries with isolated identities; only our driver launches."""
    metadata = "Contents/Info.plist"
    originals = []
    for path in (previous, candidate):
        if path.name != "DualDock.app":
            raise ValueError(f"Expected a production DualDock.app: {path}")
        run("codesign", "--verify", "--strict", "--deep", path)
        originals.append(plistlib.loads((path / metadata).read_bytes()))
    old, new = originals
    # Exercise the exact designated requirement trusted by existing installs,
    # including the code identity macOS uses when tracking application access.
    sig = subprocess.run(["codesign", "-d", "-r-", previous], capture_output=True, text=True, check=True)
    requirement = next(line[len("designated => "):] for line in (sig.stdout + sig.stderr).splitlines()
                       if line.startswith("designated => "))
    run("codesign", "--verify", "--strict", "-R=" + requirement, candidate)
    expected_feed = "https://raw.githubusercontent.com/autumncry/DualDock/main/updates/appcast.xml"
    assert old["CFBundleIdentifier"] == new["CFBundleIdentifier"] == "local.ronny.DualDock"
    assert old["SUFeedURL"] == new["SUFeedURL"] == expected_feed
    assert old["SUPublicEDKey"] == new["SUPublicEDKey"]
    assert old["CFBundleExecutable"] == new["CFBundleExecutable"] == "DualDock"
    assert old["SURequireSignedFeed"] and new["SURequireSignedFeed"]
    assert old["SUVerifyUpdateBeforeExtraction"] and new["SUVerifyUpdateBeforeExtraction"]
    assert int(old["CFBundleVersion"]) < int(new["CFBundleVersion"])
    target = root / "installed" / previous.name
    staged = root / "stage" / candidate.name
    for source, app, info in zip((previous, candidate), (target, staged), originals):
        app.parent.mkdir()
        run("ditto", source, app)
        manifest = dict(info, CFBundleIdentifier=identifier, SUPublicEDKey=public_key, SUFeedURL=base_url + "/appcast.xml")
        (app / metadata).write_bytes(plistlib.dumps(manifest))
        run("codesign", "--force", "--sign", "-", "--identifier", identifier, "--requirements",
            f'=designated => identifier "{identifier}"', app)
        run("codesign", "--verify", "--strict", "--deep", app)
    controller = make_app(root / "controller", 1, tools, public_key, base_url + "/appcast.xml",
                          root, identifier + ".controller")
    control_info = plistlib.loads((controller / metadata).read_bytes())
    control_info.update(FixtureExpectedBuild=new["CFBundleVersion"], FixtureTargetPath=str(target))
    (controller / metadata).write_bytes(plistlib.dumps(control_info))
    run("codesign", "--force", "--sign", "-", controller)
    (staged.parent / "Applications").symlink_to("/Applications")
    archive = web / "release.dmg"
    run("hdiutil", "create", "-volname", "DualDock", "-srcfolder", staged.parent, "-fs", "HFS+", "-format", "UDZO", archive)
    write_feed(archive, base_url, sign, sign(archive), build=new["CFBundleVersion"],
               marketing=new["CFBundleShortVersionString"])
    run("open", "-g", "-n", controller)
    events = await_event(root / "events.txt", "updated-target-verified", timeout=120)
    assert "offered " + new["CFBundleVersion"] in events and "install-confirmed" in events
    assert (target / metadata).read_bytes() == (staged / metadata).read_bytes()
    executable = "Contents/MacOS/DualDock"
    assert (target / executable).read_bytes() == (staged / executable).read_bytes()
    run("codesign", "--verify", "--strict", "--deep", target)
    print(f"PASS real {old['CFBundleShortVersionString']} (build {old['CFBundleVersion']}) → "
          f"{new['CFBundleShortVersionString']} (build {new['CFBundleVersion']}) payload installed by Sparkle. "
          "The installer targeted only temporary copies and relaunched only the isolated controller.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-app", type=Path, help="read-only source of a previous production DualDock.app")
    parser.add_argument("--to-app", type=Path, help="read-only current packaged DualDock.app")
    args = parser.parse_args()
    if bool(args.from_app) != bool(args.to_app):
        parser.error("provide both --from-app and --to-app")
    tools = Path(run("bash", ROOT / "script/sparkle_tools.sh"))
    with tempfile.TemporaryDirectory(
        prefix="dualdock-sparkle-test-", dir="/private/tmp"
    ) as directory:
        root = Path(directory)
        web = root / "web"
        web.mkdir()
        handler = functools.partial(
            http.server.SimpleHTTPRequestHandler, directory=str(web)
        )
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                exercise(root, tools, server, web, args.from_app, args.to_app)
            finally:
                server.shutdown()
                # A failed or interrupted test can leave its own fixture process alive.
                location = "controller" if args.from_app else "installed"
                fixture = str(root / location / APP_NAME / "Contents/MacOS/Fixture")
                for line in run("ps", "-axo", "pid=,comm=").splitlines():
                    fields = line.strip().split(None, 1)
                    if len(fields) == 2 and fields[1] == fixture:
                        try:
                            os.kill(int(fields[0]), signal.SIGTERM)
                        except ProcessLookupError:
                            pass


if __name__ == "__main__":
    main()
