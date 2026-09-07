# Micro Manager for T3 Code

A standalone macOS menu-bar app for the Work Louder Creator Micro 2. Show session
status on buttons, then press a button to open that session. Supports local
[T3 Code](https://github.com/pingdotgg/t3code), Herdr, and a hardware-free demo.

This is a local proof of concept. T3 keys can open the exact session in the
**desktop app** using the included T3 source patch, or in its browser UI.
Desktop mode selects the session in the existing window and confirms its ID.
Stock T3 0.0.38 needs the patch; see [desktop setup](docs/desktop-opening.md).
Existing configurations retain browser mode until you select the desktop target.
In **Configure → Connection**, choose **T3 desktop app** and optionally select
the installation under **Desktop app → Choose…**. This can point to your
`T3 Code Dev.app` shortcut. Test **Open** beside a session, then **Save settings**;
no key remapping is required. A selected app is launched when needed, and Micro
Manager checks that the desktop connection belongs to that app.

## Start here

```bash
./scripts/bundle.sh --install
```

Choose **Configure** from the keyboard icon in the menu bar. For a quick preview,
choose **Try demo**. That starts a virtual Micro with changing session lights;
you can switch its active layer to check that the bridge pauses on other layers.
The demo does not change hardware or overwrite your saved T3 connection.

The app starts disabled on first launch. It does not install bindings on startup
or reconnect. A device setup requires **Save & apply controls**.

## Connect your local T3 instance

Keep the existing T3 desktop app running. There is no second T3 server to start.

For the shortest local setup, quit Micro Manager and run:

```bash
python3 scripts/connect-t3.py
```

The helper uses T3's version-matched CLI to create a pairing grant for the running
loopback server, exchanges it for Micro Manager's own read-only session, verifies
session listing, and saves the connection. It downloads the matching CLI through
`npx` if necessary. It does not enable LAN or public access and does not print
credentials. Reopen Micro Manager after running it.

Alternatively, in **Configure → Connection**, use **Discover**, paste a pairing
link from T3's **Settings → Connections**, and choose **Pair**. **Test connection**
shows session titles and states. Save the settings when the connection works.
Advanced users can supply a bearer token directly.

For **Browser** mode, pair the browser once too, using a separate T3 pairing link. The helper's
`--browser` option can create and open one. Session URLs contain environment and
thread IDs, never Micro Manager's bearer credential. An authenticated browser
can then open the exact session when you press its key. It may open a new tab on
each press, according to your browser's behavior.

T3 compatibility was checked against 0.0.38. The session API is internal and may
change. Expired/revoked credentials require pairing again. Remote environments
are deferred; this version lists the configured server's own sessions.

## Choose your buttons

1. Connect your Micro. In Configure, choose **Read layers from Micro**.
2. Grant **Input Monitoring** to Micro Manager if macOS asks. Quit and reopen the
   app after granting it, then read the layers again.
3. Select an existing profile/layer by its name. Leave your Codex layer alone.
4. Click the buttons you want to use as session keys. The initial selection is
   the top six buttons; every selection is configurable. Under **Spare button
   actions**, optionally assign T3 actions to other buttons.
5. Optionally enable **Use the dial and joystick down in T3** for the controls below.
6. Review the selected binding changes and choose **Save & apply controls**.
7. Enable Micro Manager and switch the pad to that layer.

Work Louder Input remains your hardware configurator. Keep the Control+Option
Wispr Flow shortcut there. The wide microphone key and other unselected buttons
retain their bindings. The dial and joystick keep their bindings unless you enable
the T3 controls. Choosing a microphone position as a
session key explicitly replaces that position's shortcut on the selected layer.

With **Use the dial and joystick down in T3** enabled, joystick down toggles
composer focus. When the composer is focused, turn the dial to select a setting
and press to edit or confirm it. Outside the composer, turn to scroll the
conversation and press to return to the latest message. These controls require
a [T3 desktop build with dial support](docs/desktop-opening.md) and act only while that T3 app is
frontmost. They never launch or raise it. Wispr Flow, Enter, and the other joystick
directions keep their Input bindings when their buttons remain unselected.

The option starts off for existing and new configurations. Applying it replaces
only the dial's clockwise, counterclockwise, and press bindings, plus joystick
down, alongside the selected session buttons. The selected layer must already
have three dial bindings and one radial joystick down sector. The four controls
use free AG06 through AG19 slots, excluding session slots and slots used elsewhere
on that layer. At most 10 session and action buttons in total fit alongside them; setup reports any
additional slot conflicts. Turn the option off and choose **Save & apply controls**
to return those four bindings to their saved values.

**Spare button actions** offers New chat, New project, Focus/unfocus input,
Latest message, Settle thread, Toggle terminal, and Command palette. Settle thread
uses T3's manual settle action for the current saved thread. These actions require
the T3 desktop connection and run only while the selected T3 app is frontmost.
They work independently of the dial option.

For project cleanup, T3 actions can opt into **Run when manually settling a
worktree**. The matching T3 build runs the command in that thread's worktree and
shows its status and output. GuestSpace's `workspace` project includes an
importable shutdown action that removes task runtime resources and test data
while preserving source worktrees. See the [settle setup](docs/desktop-opening.md#project-cleanup-on-settle).

Every spare button starts on **Keep Input binding**. A button can be assigned to
a session or a T3 action. Microphone and Enter shortcuts remain unchanged while
their buttons are unassigned. Review and choose **Save & apply controls** after
adding or removing button assignments. Removing an assignment restores its
saved Input binding, preserving later edits made in Input.

Individual status lighting requires the firmware's `KV_OAI_AG…` bindings. The
app installs those only on selected positions. It uses AG06–AG18, reserving
AG00–AG05 for Codex. Physical button numbers and firmware slot numbers differ. These keys report presses to the
bridge instead of typing ordinary shortcuts. Consequently, session keys need
the bridge enabled; other keys keep working through Input/the device.

The top row is **0, 1** from left to right, in both the controller and Input's
keymap matrix. Labels, colors, clicks, and physical presses use those same
position IDs. See the [top-row mapping check](docs/top-row-mapping.md).

All twenty AG slots (AG00–AG19) are shared across layers. A key event identifies
the slot, without identifying its layer. With the default six T3 buttons,
Codex uses AG00–AG05 and T3 session keys use AG06–AG11. Assigned action buttons
use their physical button number plus six. The optional dial and
joystick controls take four free slots in the remaining range. Selecting
additional session or action buttons uses more of that range.
Use separate slots for independent apps. Reusing slots between layers requires
every controller to check the active layer and coordinate the shared LEDs;
Micro Manager's layer check cannot control another app's behavior. The current
dashboard manages one provider/layer at a time.

**Restore controls** restores the previous values for bindings still owned by
Micro Manager. Later changes made in Input are kept. Restore before moving the
integration to a different layer. Full device exports and the restoration record
are saved before device writes; the dashboard can reveal the backup.

If you applied the first build, choose **Save & apply controls** once in the
updated app to migrate its conflicting AG00–AG05 bindings. The saved original
shortcuts are retained for restoration.

Lighting and hardware key handling are gated by the chosen active layer and a
matching applied mapping record. The underglow is optional and off by default.
Codex and Input can also write device lighting. The app reports detected competing
clients, but coexistence on physical hardware still needs verification. Layer
selection alone does not stop another app from writing global light state.

## Which sessions appear

- **Recent:** most recent session activity fills the selected buttons.
- **Pinned:** explicit per-button pins, then sessions pinned in T3.
- **Pinned + recent:** explicit pins, then T3 pins and recent sessions.

Running sessions and sessions needing input retain their current automatic slot
as the recent list changes. An explicit pin reserves its key when the session is
unavailable. The menu lists all sessions, including those beyond the selected
button count. Explicit pins are stored separately for each provider and restored
when you switch back. Existing pins migrate automatically on load. Review pins
when pointing the same provider at a different server.

| Color | State |
| --- | --- |
| Amber, pulsing | Approval, input, or plan review needed |
| Cyan, slow gentle pulse | Running or background work |
| Green, solid | Finished, waiting to be opened |
| Muted lavender, solid | Idle / completed response opened |
| Red, solid | Error |
| Gray, solid | Unknown or disconnected |

Working uses the firmware's shallow-breath effect at speed `0.25`; input or
approval uses full breathing at `0.5`. Settled states stay solid. The optional
ambient light follows the same palette and pulse settings. The menu uses matching
colors; its status dots and pad preview stay static.

The bridge polls session summaries once per cycle, with a one-second pause
between cycles. Device reads and network latency can extend the interval. It
never downloads conversation bodies. A failed connection marks retained sessions
unknown instead of leaving a stale working or idle color. Opening a completed
session through Micro Manager (a physical key or the menu) acknowledges it locally
and changes green to lavender. Reading it directly in T3 is not detected; this is
not T3's own seen/unseen state.
Acknowledgements track the completed turn, so a new result becomes green even
if the entire turn finishes between polls. Herdr retains its own native read state.

Herdr uses its local socket and raises Ghostty after focusing a pane.
`HERDR_SOCKET_PATH` and `WL_TERMINAL_BUNDLE_ID` still override those defaults.
The upstream GitButler, model-tuning, and text-macro controls are not assigned by
this session-focused dashboard. Their source remains available in the fork.

## Configuration and development

Settings live in `~/.config/micromanager/bridge.json`, honoring
`XDG_CONFIG_HOME`. The file contains the paired token and is written with owner-only
permissions. Do not share it with colleagues. Each colleague pairs their own app.
The old `config.json` macro file is retained and is not overwritten.

Providers implement a shared `SessionProvider` interface for session listing and
opening. `SessionInputProvider` optionally adds text input and named actions;
unsupported inputs are rejected. T3 currently exposes read/open operations, while
Herdr supports inserting text without submitting it. Custom input bindings are
an API extension point, with no dashboard controls assigned yet. See
[adding a provider](docs/provider-architecture.md) for the contract and examples.

```bash
swift build
swift test                           # requires Xcode's XCTest framework
./scripts/verify-mapping.sh           # also works with Command Line Tools only
./scripts/verify-t3.sh
./scripts/verify-desktop.sh           # real local sockets; no running T3 needed
./scripts/verify-micro-controls.sh    # dial mapping, restoration, routing and event order
python3 scripts/verify-signing.py      # temporary certificate + two distinct builds
./scripts/verify-emulator.sh
./scripts/verify-bridge.sh            # isolated config + emulator; no hardware
./scripts/verify-providers.sh         # provider lifecycle, inputs, pins, connection races
./scripts/verify-bridge.sh --inspect-device  # optional read-only physical probe
```

`bundle.sh` creates `build/T3MicroManager.app` with the protocol Inspector nested
inside it. `--install` quits Micro Manager, installs it in
`/Applications/T3MicroManager.app`, and reopens it. Use this location for everyday
use and future updates. The fork has its own bundle IDs, so it does not replace
Work Louder Input or an upstream Micro Manager installation.

Local builds create a signing certificate once, then reuse it automatically.
This keeps the app's identity stable across updates so Input Monitoring can
retain its grant. The private key lives in a dedicated Keychain under
`~/Library/Application Support/T3MicroManager/Signing`, alongside an owner-only
password file. Keep this directory private and preserve it between builds.
The helper locks the keychain after signing and does not add certificate trust
or change the login keychain. A missing or broken identity fails the build
instead of silently replacing it. Each colleague building locally gets their
own identity. No paid Apple developer account is needed for this local setup.

**Switching from an earlier ad-hoc build requires one final grant.** Quit Micro
Manager, remove its old entry from **System Settings → Privacy & Security →
Input Monitoring**, and add `/Applications/T3MicroManager.app`. Enable it and
reopen the app. The old switch may look enabled even when the signature no
longer matches. Settings and device mappings are preserved.

For distribution, explicitly set `WL_SIGN_IDENTITY` to an Apple signing identity.
Local certificates do not provide notarization or Gatekeeper approval. Setting
`WL_SIGN_IDENTITY=-` opts into ad-hoc signing; unsigned CI also uses ad-hoc signing
rather than creating a new local certificate on every runner. Those builds will
again need permission after updates. See Apple's explanation of
[code requirements and app identity](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

The original [hardware protocol guide](docs/hacking.md) is retained. Its automatic
first-layer examples describe the upstream implementation; use the dashboard's
explicit layer selection in this fork. Background research is in
[port-investigation.md](docs/port-investigation.md) and
[t3-integration-research.md](docs/t3-integration-research.md).
