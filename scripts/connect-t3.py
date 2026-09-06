#!/usr/bin/env python3
"""Pair Micro Manager with the running local T3 server, without exposing it remotely."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
import webbrowser


class SetupError(Exception):
    pass


class HTTPFailure(SetupError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"Local T3 returned HTTP {status}.")


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SetupError("Local T3 redirected the request; no credentials were forwarded.")


def local_origin(raw, *, pairing=False):
    try:
        url = urlsplit(raw)
        if (url.scheme not in ("http", "https")
                or url.hostname not in ("127.0.0.1", "localhost", "::1")
                or url.username is not None or url.password is not None
                or not 1 <= (url.port or (443 if url.scheme == "https" else 80)) <= 65535):
            raise ValueError()
        if pairing:
            if url.path != "/pair":
                raise ValueError()
        elif url.path not in ("", "/") or url.query or url.fragment:
            raise ValueError()
        return urlunsplit((url.scheme, url.netloc, "", "", ""))
    except (ValueError, TypeError):
        raise SetupError("Expected a local T3 loopback address.") from None


def request_json(endpoint, path, *, token=None, form=None):
    endpoint = local_origin(endpoint)
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = None
    if form is not None:
        body = urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = Request(endpoint + path, data=body, headers=headers)
    # Loopback requests must not go through a configured remote HTTP proxy.
    opener = build_opener(ProxyHandler({}), NoRedirects())
    try:
        with opener.open(request, timeout=10) as response:
            data = response.read(32 * 1024 * 1024 + 1)
        if len(data) > 32 * 1024 * 1024:
            raise SetupError("Local T3's response exceeded the expected size.")
        value = json.loads(data)
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except HTTPError as error:
        raise HTTPFailure(error.code) from None
    except (URLError, TimeoutError, OSError):
        raise SetupError("Cannot reach the local T3 server. Keep T3 Code running and retry.") from None
    except (ValueError, UnicodeError):
        raise SetupError("Local T3 returned an unsupported response.") from None


def read_object(path, *, optional=False):
    try:
        with path.open() as handle:
            value = json.load(handle)
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except FileNotFoundError:
        if optional:
            return {}
        raise SetupError(f"Cannot find {path.name}. Start T3 Code first.") from None
    except (OSError, ValueError):
        raise SetupError(f"Cannot read a valid {path.name}; existing settings were preserved.") from None


def discover(base):
    runtime = read_object(base / "userdata/server-runtime.json")
    pid = runtime.get("pid")
    if runtime.get("version") != 1 or type(pid) is not int or pid <= 0:
        raise SetupError("T3 runtime metadata has an unsupported format.")
    try:
        os.kill(pid, 0)
    except OSError:
        raise SetupError("T3's recorded server is no longer running. Restart T3 Code.") from None
    origin = local_origin(runtime.get("origin"))
    endpoint = local_origin(runtime.get("devUrl") or origin)
    descriptor = request_json(endpoint, "/.well-known/t3/environment")
    if not isinstance(descriptor.get("environmentId"), str) or not descriptor["environmentId"]:
        raise SetupError("The local service did not identify itself as a T3 environment.")
    version = descriptor.get("serverVersion")
    if not version:
        for app in ("T3 Code (Alpha).app", "T3 Code.app"):
            try:
                with (Path("/Applications") / app / "Contents/Info.plist").open("rb") as handle:
                    version = plistlib.load(handle).get("CFBundleShortVersionString")
                if version:
                    break
            except (OSError, ValueError, plistlib.InvalidFileException):
                pass
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise SetupError("Cannot determine the installed T3 version for its pairing command.")
    return endpoint, descriptor["environmentId"], version


def mint_pairing_link(base, endpoint, version, label):
    npx = shutil.which("npx")
    if npx is None:
        raise SetupError("Install Node.js with npx to create a local T3 pairing link.")
    # The CLI writes its own auth records. Pin its version and home to the live server.
    command = [npx, "--yes", f"t3@{version}", "pair", "--base-dir", str(base), "--label", label]
    try:
        with tempfile.TemporaryDirectory(prefix="micromanager-t3-pair-") as directory:
            result = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        raise SetupError("The matching T3 pairing command could not finish. Check Node.js and network access, then retry.") from None
    if result.returncode != 0:
        raise SetupError("The matching T3 pairing command failed. Its output was hidden because it may contain credentials.")
    match = re.search(r"^\s*Pairing URL:\s*(\S+)", result.stdout, re.MULTILINE)
    if not match:
        raise SetupError("The T3 command did not return a recognized pairing link.")
    link = match.group(1)
    if local_origin(link, pairing=True) != endpoint:
        raise SetupError("T3's pairing link points at a different address; it was not used.")
    url = urlsplit(link)
    token = (parse_qs(url.fragment).get("token") or parse_qs(url.query).get("token") or [""])[0].strip()
    if not token:
        raise SetupError("T3's pairing link did not contain a token.")
    return link, token


def exchange(endpoint, credential):
    response = request_json(endpoint, "/oauth/token", form={
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token": credential,
        "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "scope": "orchestration:read",
        "client_label": "Micro Manager",
        "client_device_type": "desktop",
        "client_os": "macOS",
    })
    token = response.get("access_token")
    scope = response.get("scope")
    if (response.get("token_type") != "Bearer" or not isinstance(token, str) or not token
            or not isinstance(scope, str) or "orchestration:read" not in scope.split()):
        raise SetupError("T3 did not return a usable read-only credential.")
    return token


def session_count(endpoint, token):
    shell = request_json(endpoint, "/api/orchestration/shell", token=token)
    threads = shell.get("threads")
    if not isinstance(threads, list) or not all(isinstance(thread, dict) for thread in threads):
        raise SetupError("T3's session response has an unsupported format.")
    return sum(not thread.get("archivedAt") and not thread.get("deletedAt") for thread in threads)


def save_connection(path, endpoint, environment_id, token):
    # Reload after pairing so mapping edits made while npx ran are retained.
    configuration = {
        "provider": "t3", "t3": {}, "sessionKeys": [1, 0, 2, 3, 4, 5],
        "selection": "mixed", "pinnedSessions": {}, "driveAmbient": False,
    }
    configuration.update(read_object(path, optional=True))
    configuration["provider"] = "t3"
    previous = configuration.get("t3")
    configuration["t3"] = {
        **(previous if isinstance(previous, dict) else {}),
        "baseURL": endpoint, "environmentID": environment_id, "bearerToken": token,
    }
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".bridge-", delete=False) as handle:
            temporary = Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            json.dump(configuration, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check local discovery without creating credentials or changing settings")
    parser.add_argument("--browser", action="store_true", help="Create a separate pairing link and open it in your default browser")
    args = parser.parse_args()
    if args.check and args.browser:
        parser.error("--check cannot be combined with --browser")
    base = Path(os.environ.get("T3CODE_HOME", "").strip() or Path.home() / ".t3").expanduser().resolve()
    config_base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config").expanduser()
    config_path = config_base / "micromanager/bridge.json"
    existing = read_object(config_path, optional=True)
    endpoint, environment_id, version = discover(base)
    if args.check:
        print(f"Local T3 {version} is reachable. No credentials or settings were changed.")
        return 0

    token = None
    previous = existing.get("t3", {})
    if isinstance(previous, dict) and previous.get("environmentID") == environment_id:
        candidate = previous.get("bearerToken")
        if isinstance(candidate, str) and candidate:
            try:
                count = session_count(endpoint, candidate)
                token = candidate
            except HTTPFailure as error:
                if error.status not in (401, 403):
                    raise
    if token is None:
        _, credential = mint_pairing_link(base, endpoint, version, "Micro Manager")
        if request_json(endpoint, "/.well-known/t3/environment").get("environmentId") != environment_id:
            raise SetupError("The local T3 environment changed during pairing. Retry after it settles.")
        token = exchange(endpoint, credential)
        count = session_count(endpoint, token)
    save_connection(config_path, endpoint, environment_id, token)
    print(f"Connected to local T3. {count} sessions available.")
    if args.browser:
        link, _ = mint_pairing_link(base, endpoint, version, "Micro Manager browser")
        if not webbrowser.open(link):
            raise SetupError("Micro Manager is connected, but the browser pairing page could not be opened.")
        print("Opened separate local browser pairing.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SetupError as error:
        print(f"Setup failed: {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError):
        print("Setup failed while reading or saving local configuration. No credential details were logged.", file=sys.stderr)
        sys.exit(1)
