#!/usr/bin/env python3
"""Exercise local certificate creation, reuse, and update identity on real app bundles."""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def fixture(root, version):
    bundle = root / "Manager.app"
    for app, identifier in [(bundle, "dev.t3micromanager.signing-test"),
                            (bundle / "Contents/Library/Inspector.app",
                             "dev.t3micromanager.signing-test.inspector")]:
        (app / "Contents/MacOS").mkdir(parents=True)
        executable = app / "Contents/MacOS/Fixture"
        shutil.copyfile("/usr/bin/true", executable)
        executable.chmod(0o755)
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                          "CFBundlePackageType": "APPL", "CFBundleVersion": version}, file)
    return bundle


def requirement(bundle):
    return run("codesign", "-d", "-r-", str(bundle)).stdout.strip().split("=> ", 1)[1]


search_list = run("security", "list-keychains", "-d", "user").stdout
script = Path(__file__).with_name("sign-local.py")
with tempfile.TemporaryDirectory(prefix="micromanager-signing-test-") as temporary:
    root = Path(temporary)
    state = root / "signing"
    environment = dict(os.environ, WL_LOCAL_SIGNING_DIR=str(state))
    try:
        first = fixture(root / "first", "1")
        second = fixture(root / "second", "2")
        for bundle in [first, second]:
            run("python3", str(script), str(bundle / "Contents/Library/Inspector.app"),
                str(bundle), env=environment)
            run("codesign", "--verify", "--deep", "--strict", str(bundle))
            assert run("security", "list-keychains", "-d", "user").stdout == search_list
        first_requirement = requirement(first)
        assert first_requirement == requirement(second)
        assert "certificate leaf" in first_requirement and "cdhash" not in first_requirement
        run("codesign", "--verify", "-R=" + first_requirement, str(second))
        hashes = []
        for bundle in [first, second]:
            details = run("codesign", "-d", "--verbose=4", str(bundle)).stderr
            hashes.append(next(line for line in details.splitlines() if line.startswith("CDHash=")))
        assert hashes[0] != hashes[1], "Fixture update must change the code directory hash"
        for name in ["keychain-password", "micromanager.keychain-db", "identity.sha1"]:
            assert (state / name).stat().st_mode & 0o077 == 0
        print("PASS: fresh setup, nested signatures, new build hash, same certificate requirement.")

        run("codesign", "--force", "--sign", "-", str(second))
        rejected = subprocess.run(["codesign", "--verify", "-R=" + first_requirement, str(second)],
                                  capture_output=True)
        assert rejected.returncode != 0, "An ad-hoc replacement must not match our identity"
        print("PASS: an ad-hoc replacement is rejected by the saved requirement.")

        original_certificate = (state / "certificate.pem").read_bytes()
        (state / "identity.sha1").unlink()
        failed = subprocess.run(["python3", str(script), str(second)], env=environment,
                                capture_output=True, text=True)
        assert failed.returncode != 0 and "refusing to silently replace" in failed.stderr
        assert (state / "certificate.pem").read_bytes() == original_certificate
        assert run("security", "list-keychains", "-d", "user").stdout == search_list
        print("PASS: incomplete setup fails without replacing its certificate; keychain list preserved.")
    finally:
        keychain = state / "micromanager.keychain-db"
        if keychain.exists():
            run("security", "delete-keychain", str(keychain))
