#!/usr/bin/env python3
"""Sign local builds with one persistent certificate, without changing trust settings."""

import argparse
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import tempfile


class LocalSigner:
    def __init__(self, directory):
        self.directory = directory
        self.keychain = directory / "micromanager.keychain-db"
        self.password_file = directory / "keychain-password"
        self.certificate = directory / "certificate.pem"
        self.identity_file = directory / "identity.sha1"
        self.secrets = []

    def run(self, *args):
        result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
        if result.returncode:
            message = result.stderr.strip() or result.stdout.strip() or "Command failed"
            for secret in self.secrets:
                message = message.replace(secret, "<redacted>")
            raise RuntimeError(message)
        return result.stdout.strip()

    def keychains(self):
        return shlex.split(self.run("/usr/bin/security", "list-keychains", "-d", "user"))

    @contextmanager
    def discoverable(self):
        # codesign also needs the chain in the search list, even with --keychain.
        already_listed = str(self.keychain) in self.keychains()
        try:
            yield
        finally:
            if not already_listed:
                current = self.keychains()
                if str(self.keychain) in current:
                    self.run("/usr/bin/security", "list-keychains", "-d", "user", "-s",
                             *(item for item in current if item != str(self.keychain)))

    def create_identity(self):
        if any(item.name != ".lock" for item in self.directory.iterdir()):
            raise RuntimeError(f"Incomplete signing setup in {self.directory}. Restore its original "
                               "identity; refusing to silently replace it and invalidate permissions.")
        password = secrets.token_urlsafe(36)
        self.secrets.append(password)
        self.password_file.write_text(password)
        self.run("/usr/bin/security", "create-keychain", "-p", password, self.keychain)
        self.run("/usr/bin/security", "set-keychain-settings", "-lut", "3600", self.keychain)
        name = "Micro Manager Local " + secrets.token_hex(6)
        with tempfile.TemporaryDirectory(dir=self.directory) as temporary:
            temporary = Path(temporary)
            config = temporary / "openssl.cnf"
            config.write_text(
                "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=codesign\n"
                f"[dn]\nCN={name}\n[codesign]\nbasicConstraints=critical,CA:false\n"
                "keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n"
                "subjectKeyIdentifier=hash\n"
            )
            key = temporary / "key.pem"
            self.run("/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes",
                     "-sha256", "-days", "3650", "-config", config, "-keyout", key,
                     "-out", self.certificate)
            export_password = secrets.token_urlsafe(36)
            self.secrets.append(export_password)
            password_file = temporary / "export-password"
            password_file.write_text(export_password)
            archive = temporary / "identity.p12"
            # Keychain's PKCS#12 importer needs the older PBE format.
            self.run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", key,
                     "-in", self.certificate, "-name", name, "-out", archive,
                     "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                     "-macalg", "sha1", "-passout", "file:" + str(password_file))
            self.run("/usr/bin/security", "import", archive, "-k", self.keychain,
                     "-P", export_password, "-T", "/usr/bin/codesign", "-x")
        # This keychain contains only our key; never alter the login keychain ACLs.
        self.run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:",
                 "-s", "-k", password, self.keychain)
        self.identity_file.write_text(self.fingerprint() + "\n")

    def fingerprint(self):
        return self.run("/usr/bin/openssl", "x509", "-in", self.certificate,
                        "-noout", "-fingerprint", "-sha1").split("=")[1].replace(":", "")

    def sign(self, bundles):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.directory.chmod(0o700)
        with (self.directory / ".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.discoverable():
                try:
                    if not self.identity_file.exists():
                        self.create_identity()
                    identity = self.identity_file.read_text().strip()
                    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity) or identity != self.fingerprint():
                        raise RuntimeError("Saved signing certificate and identity do not match.")
                    password = self.password_file.read_text()
                    self.secrets.append(password)
                    self.run("/usr/bin/security", "unlock-keychain", "-p", password, self.keychain)
                    current = self.keychains()
                    if str(self.keychain) not in current:
                        self.run("/usr/bin/security", "list-keychains", "-d", "user", "-s",
                                 *current, self.keychain)
                    print(f"    local identity: {identity}", flush=True)
                    for bundle in bundles:
                        self.run("/usr/bin/codesign", "--force", "--timestamp=none", "--sign", identity,
                                 "--keychain", self.keychain, bundle)
                        self.run("/usr/bin/codesign", "--verify", "--strict", bundle)
                finally:
                    if self.keychain.exists():
                        self.run("/usr/bin/security", "lock-keychain", self.keychain)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundles", type=Path, nargs="+", help="Bundles to sign, inside out")
    args = parser.parse_args()
    for bundle in args.bundles:
        if not bundle.exists():
            parser.error(f"Bundle does not exist: {bundle}")
    os.umask(0o077)
    directory = Path(os.environ.get("WL_LOCAL_SIGNING_DIR",
                         str(Path.home() / "Library/Application Support/T3MicroManager/Signing"))).resolve()
    try:
        LocalSigner(directory).sign(args.bundles)
    except (RuntimeError, OSError) as error:
        print(f"Local signing failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
