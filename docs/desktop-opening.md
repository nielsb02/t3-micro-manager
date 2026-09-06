# Open sessions in T3 desktop

Desktop mode brings T3 forward and selects the assigned session in its existing
window. It uses the environment ID and T3 thread ID, so duplicate titles and
sidebar ordering do not affect the destination. It does not open browser tabs.

## Local setup

1. Build T3 with `patches/t3code-open-thread.patch`, or use the supplied custom
   desktop build. Quit the stock T3 app before opening the custom build. They
   use the same T3 application identity and normal data directory.
2. Open the updated Micro Manager. In **Configure → Connection**, select
   **Open sessions in → T3 desktop app**.
3. Optionally choose **Desktop app → Choose…** and select your patched build,
   for example `/Applications/T3 Code Dev.app`. Micro Manager opens this exact
   installation when needed. Leave it blank to use the already running desktop.
4. Choose **Test connection**, then **Open** beside a session to test navigation
   before pressing a hardware key. Save the settings.

The app picker selects the installation to launch; the server URL still selects
the sessions to list. If another copy with the same T3 app identity is running,
Micro Manager reports its location instead of starting a conflicting copy.
When an app is selected, the navigation socket's owning process must match that
app before any session request is sent. Applications shortcuts and symlinks work.
Choosing an unpatched app does not add navigation support to it.

Status still uses the existing paired local HTTP connection. Browser pairing
is unnecessary for desktop navigation. The target environment must already be
connected in the desktop app. Unknown, archived, or disconnected targets report
an error; the bridge does not create a replacement session or fall back to a
browser. Keep **Browser** selected when using an unpatched T3 release.

Local Micro Manager builds reuse a persistent signing certificate so Input
Monitoring survives updates. See the README for the one-time transition from
older ad-hoc builds. Changing the desktop target does not require applying new
key bindings.

## Build the T3 patch

The patch targets upstream commit
`223ff4490f764a74ff911589e97b9bbcd595fee8` (T3 version 0.0.38 plus subsequent
upstream changes, including its desktop control socket). It is not a binary
patch for the installed 0.0.38 app.

```bash
git clone https://github.com/pingdotgg/t3code.git t3code-micro
cd t3code-micro
git checkout 223ff4490f764a74ff911589e97b9bbcd595fee8
git apply /path/to/t3-micro-manage/patches/t3code-open-thread.patch
```

Use T3's build requirements: Node 24.13.1 or compatible Node 24, its pinned pnpm
11.10.0, Apple's Command Line Tools, and Rust with the `aarch64-apple-darwin`
target for an Apple Silicon app. Install dependencies, then build:

```bash
pnpm install --frozen-lockfile
pnpm exec vp run build:desktop
node scripts/build-desktop-artifact.ts \
  --platform mac --arch arm64 --target zip --build-version 0.0.38-micro.1 \
  --skip-build --output-dir ./micro-artifacts
```

Extract the ZIP before opening the app. For a local build without an Apple
signing certificate, sign the extracted app with
`codesign --force --deep --sign - "T3 Code (Alpha).app"`, then verify it with
`codesign --verify --deep --strict "T3 Code (Alpha).app"`. The supplied local
build is already ad-hoc signed. It is not notarized.

Run the focused T3 checks with `pnpm exec vp test run
apps/web/src/desktopAppActivation.test.ts
apps/desktop/src/app/DesktopAppActivation.test.ts
apps/desktop/src/app/DesktopAppActivationBroker.test.ts`. The Swift client has
its own real-socket checks in `scripts/verify-desktop.sh`.

## Local interface

The patch extends T3's existing desktop control socket with a newline-delimited
JSON request:

```json
{"version":1,"requestId":"unique-id","type":"open-thread","environmentId":"environment-id","threadId":"thread-id"}
```

T3 reveals its window, validates the connected environment and existing thread,
then calls its normal client router. A successful reply includes the same
request, environment, and thread IDs. Micro Manager checks all three before
acknowledging the session locally. The existing `open-workspace` request remains
available.

The default socket is under the current user's temporary directory at
`t3code-<uid>/<hash>.sock`, where `hash` is the first 24 hexadecimal characters
of SHA-256 of the absolute T3 state-directory path (normally `~/.t3/userdata`).
The socket directory is private to the user. No browser endpoint or debugging
port is enabled. **Advanced connection settings → Desktop socket** can target
a custom T3 home; leave it blank for the default installation.
Selecting an app does not automatically select its custom data directory;
configure this socket override if that app uses a different T3 home.

This change adds desktop navigation. It does not add remote status aggregation
to Micro Manager. Status still comes from the configured local environment.

## Verified locally

On 2026-09-06, the patched desktop opened two isolated test sessions with the
same title by their distinct IDs. Both direct socket requests and the production
Swift client received matching confirmations from the real desktop renderer.
The test used a separate T3 home and created no agent turns. The focused T3
tests, type checks, Swift socket checks, provider checks, and emulator bridge
checks also passed. A physical key press after switching the real T3 app remains
the final user check.

Version 0.1.5 also verified selecting the local `T3 Code Dev.app` shortcut and
opening the real current session through the production Swift client, including
socket-process verification. Selecting the stock app while the patched copy was
running produced a conflict error without launching or quitting either T3 app.
The socket tests additionally launch a temporary fixture application through
NSWorkspace and verify startup waiting, exact replies, and rejection of a socket
owned by a different process. This test uses no T3 data or hardware.
