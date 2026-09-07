# Open sessions in T3 desktop

Desktop mode brings T3 forward and selects the assigned session in its existing
window. It uses the environment ID and T3 thread ID, so duplicate titles and
sidebar ordering do not affect the destination. It does not open browser tabs.

## Local setup

1. Download the Apple Silicon app from the
   [T3 Micro fork's releases](https://github.com/nielsb02/t3code/releases/latest),
   or build T3 with `patches/t3code-open-thread.patch`. Quit the stock T3 app before opening the custom build. They
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

On first launch, macOS may run a downloaded app from a temporary App Translocation
folder. Micro Manager resolves that folder to the original selected installation.
If the optional macOS origin lookup is unavailable, it validates both bundles and
compares their version-specific code signature hashes. The socket must still
belong to the matched app's process. Renaming the installed app is supported;
select its new name in the desktop app picker.

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

The maintained source is [nielsb02/t3code](https://github.com/nielsb02/t3code).
It checks published upstream releases daily and publishes a new desktop build
after merging and passing checks. Conflicts or failed checks leave the previous
download available. See its
[maintenance guide](https://github.com/nielsb02/t3code/blob/main/docs/operations/micro-fork.md)
for the schedule, installation, and update recovery. The standalone patch below
remains available to reproduce the original integration.

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

The optional dial and joystick controls use the same socket with a separate
request. They require a build that implements `micro-control`; the original
`open-thread` patch alone does not provide them.

The companion [controls patch](../patches/t3code-micro-controls.patch) targets the
maintained T3 fork at commit `179f7a2a`. Apply it to that checkout before running
the desktop build above. It includes the renderer's focus-aware settings
navigation, spare-button actions, project settle hooks, and the socket extension. Existing published builds may predate this
patch; use the matching locally built T3 app when enabling the dial controls.

In a new chat, the dial can choose the project, workspace, source branch, model,
reasoning, and permissions. Disabled or unavailable settings are skipped. On
narrow windows, model options and permissions are in the existing **More composer
controls** menu. Turning highlights an option; pressing confirms it. Joystick
down dismisses an open picker without applying its highlighted choice and returns
to scrolling. Confirmed settings and the draft are retained.

```json
{"version":1,"requestId":"unique-id","type":"micro-control","action":"dial-clockwise"}
```

The fixed dial/joystick actions are `dial-clockwise`, `dial-counterclockwise`,
`dial-press`, and `composer-toggle`. Spare physical buttons can be assigned
`new-thread`, `new-project`, `composer-toggle`, `latest-message`, `settle-thread`,
`terminal-toggle`, or `command-palette`. A successful response echoes the action
and request ID:

```json
{"version":1,"requestId":"unique-id","ok":true,"action":"dial-clockwise"}
```

Micro Manager checks both fields and version 1. Rejections use the existing
`ok: false`, `code`, and `message` format. Controls are sent in order, and stopping
the bridge or saving a configuration discards queued inputs. Every request verifies
the socket's owning process against the frontmost T3 application. When an app is
selected in Configuration, it must match that installation too. Controls never
start or activate a desktop app. The same checks apply to assigned button actions.

Micro Manager stores button assignments in `actionButtons`, keyed by physical
button number. For example, `{"actionButtons":{"6":"settle-thread","7":"new-thread"}}`
assigns two spare buttons. Existing configurations default to an empty assignment
map. Action buttons and session keys must be disjoint, and each assigned button
uses its existing physical-number-plus-six AG slot. With dial/joystick controls
enabled, their combined count must leave four slots free. Unassigned bindings,
including microphone and Enter shortcuts, remain with Input. The configuration
UI reviews these changes before Apply saves a backup and writes the mapping.

The virtual pad includes dial rotation, a **Press** button, and joystick down.
Its window stays nonactivating so clicking these controls can leave T3 frontmost.
Enable and apply the optional controls on an emulator layer with a radial joystick
before trying them. `scripts/verify-micro-controls.sh` checks mapping and event
ordering without hardware or live settings; `scripts/verify-desktop.sh` checks
every supported action over local sockets.

## Project cleanup on settle

T3 project actions have a **Run when manually settling a worktree** switch. It
runs an explicitly configured project command on a new manual settlement, with
`T3CODE_PROJECT_ROOT`, `T3CODE_WORKTREE_PATH`, and `T3CODE_THREAD_ID` available.
Automatic settlement and imported history do not trigger it. Primary checkouts,
active shared worktrees, and checkouts with another operation in progress are
skipped with a visible explanation. Commands time out after two minutes.

Cleanup runs in the background. Other threads remain usable; T3 prevents the
same worktree from being resumed or changed until cleanup finishes. The thread
shows started, completed, failed, or skipped status with expandable output. A
failure leaves the thread settled so its result can be inspected.

For GuestSpace, the companion [workspace patch](../patches/guestspace-workspace-settle.patch)
targets the workspace control plane at `233fbac`. These changes are also applied
locally in `/Users/niels/dev/guestspace/workspace`.

1. Use the matching T3 preview and open **Project settings** for `workspace`.
2. Under **Actions**, choose **Import scripts → Shut down workspace runtimes**.
3. Confirm **Run when manually settling a worktree** is enabled. If the action
   editor opens, choose **Save action**.
4. Assign **Settle thread** to a spare button in Micro Manager and apply the controls.

The imported command is:

```sh
"$T3CODE_PROJECT_ROOT/bin/guestspace" workspace shutdown "$T3CODE_WORKTREE_PATH" --json
```

It calls the primary control-plane CLI so older linked task workspaces can use
the new command. GuestSpace verifies the registered composite workspace and
its repository ownership before calling each repository's `runtime.shutdown`.
For staff-portal this removes task containers, test databases, the MinIO bucket,
and Redis data; guestspace-web stops its development server. Git worktrees and
source files remain. Each repository's success or failure is included in the result.

## Isolated controls verification

On 2026-09-07, the focused dial and catalog checks passed in a real T3 web UI,
including compact composer menus, scrolling, latest message, focus cancellation,
draft preservation, new chat/project, terminal toggle, and manual settlement.
Project action import and persistence, failed cleanup, successful GuestSpace CLI
shutdown through harmless adapters, and removal of disposable runtime test data
also passed. No provider prompts, live resource cleanup, or hardware mapping
changes were performed. Physical dial/button testing remains a separate check.

Status still comes from the configured local environment.

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
