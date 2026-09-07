# Micro Manager for T3 Code

A standalone macOS menu-bar app for the Work Louder Creator Micro 2. Show session
status on buttons, then press a button to open that session. Supports local
[T3 Code](https://github.com/pingdotgg/t3code), [cmux](https://cmux.com), Herdr, and a hardware-free demo.

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
or reconnect. A device setup requires **Save & apply this layer**.

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

## Connect cmux

cmux **0.64.22 or newer** is required. Older versions are rejected with an
update message. The bridge also checks that the running server has the required
control methods, so updating only a CLI binary is not enough.

1. In cmux, choose **Settings → Automation → Socket Control Mode → Automation mode**.
   The default **cmux processes only** mode cannot accept a separate Micro Manager
   app. Password mode also works with the bundled CLI's saved credential.
2. Enable **Claude Code Integration** and **Codex Integration** in cmux Settings,
   then start new agent sessions. For a custom Codex launcher that bypasses
   cmux's wrapper, run `cmux hooks setup --agent codex` once in a cmux terminal.
   This is separate from the Codex desktop controller setting.
3. In Micro Manager's **Configure**, choose **Add layer → Add cmux layer**.
4. Choose **Test connection**, select a Micro layer and your buttons, then
   **Save & apply this layer**.

The default view shows workspaces, with each light combining the workspace's
agent states. Pressing it focuses an agent needing attention, otherwise the
selected terminal. Choose **Within workspace** and a workspace to fill the keys
with its recent terminal and browser tabs. Both Configure and the menu have this
quick switch; changing the view does not rewrite device bindings. Pins are kept
separately for the workspace view and for each selected workspace.

Agent status comes from cmux's hook records matched to currently open surfaces.
Codex records are verified against cmux's live process and current conversation
binding; they do not require Claude's active-session index. This also follows a
Codex session whose saved terminal identifiers changed after a cmux restart.
The structured cmux activity feed reconciles completed turns with older hook state.
A parent Stop ends the response even if a background shell or abandoned Codex turn
still exists. Claude's ordinary idle reminder does not mean an approval is needed.
Real pending permissions and questions remain amber until resolved.
Without hooks, a terminal is shown as unknown. A completed turn with an unread
completion notification is green; a pending approval remains amber even after
its notification is read. Ordinary unread notifications and checklist items do
not imply completion. cmux's native notification read state is used.

Micro Manager uses the installed cmux CLI with explicit argument arrays. Advanced
connection fields let you select a CLI or socket path. It does not install hooks,
change cmux's access settings, or fall back to older status protocols.

## cmux controls and dictation

In Configure, select a cmux layer and open **cmux controls & voice**. Choose
**Use navigation preset**, review the bindings, then **Save & apply this layer**.
The preset uses six session keys and eight controls, fitting the 14 slots available
while Codex desktop buttons are enabled.

| Control | Preset action |
| --- | --- |
| Dial clockwise / counterclockwise | Next / previous terminal or browser tab in the focused pane |
| Dial press | Switch the dial between tabs and workspaces |
| Joystick directions | Focus the adjacent split pane |
| Key 7 | Submit / Enter in the focused terminal |
| Wide microphone key | Retain the existing Wispr Flow shortcut from Input |

Every action can be changed per layer. Options include next agent needing
attention, Escape, interrupt, literal prompt text without submission, and the
voice command panel. The panel is also available in the menu. Dictate a command
with your existing voice key, then use Submit or **Run command**. For example,
`next workspace`, `previous terminal`, `left`, `attention`, or `open StaffPortal`.
Opening by name requires one exact, case-insensitive match. Ambiguous names and
unknown commands show an error. The panel does not interpret terminal prompts
as navigation commands, and a panel submission does not also send Enter to cmux.

The configuration shows the slot budget. Remove a control or session key if it
exceeds that budget. Joystick directions require corresponding radial sectors
in that Input layer; missing controls produce an error before writing. Applying
and restoring cover keys, the dial and selected joystick sectors, and preserve
later edits made in Input. A native Input shortcut remains the way to change
physical hardware layers.

## Choose your buttons

1. Connect your Micro. In Configure, choose **Read layers from Micro**.
2. Grant **Input Monitoring** to Micro Manager if macOS asks. Quit and reopen the
   app after granting it, then read the layers again.
3. Select a saved configuration in the sidebar, or add a layer for another provider.
   Choose an existing Micro profile/layer by name; each device layer has one provider.
4. Click the buttons you want to use as session keys. The initial selection is
   the top six buttons; every selection is configurable.
5. Review the selected binding changes and choose **Save & apply this layer**.
6. Enable Micro Manager and switch the pad to that layer.

Work Louder Input remains your hardware configurator. Keep the Control+Option
Wispr Flow shortcut there. Controls without an action in Micro Manager retain
their existing bindings, including the wide microphone key. Choosing a microphone position as a
session key explicitly replaces that position's shortcut on the selected layer.

Individual status lighting requires the firmware's `KV_OAI_AG…` bindings. The
app installs those only on selected session positions and configured controls. With **Use Codex desktop buttons**
enabled, it uses AG06–AG18 and reserves AG00–AG05 for Codex. With that setting
disabled, it uses AG00–AG12. Dial and joystick bindings use the remaining slots
through AG19, excluding slots reserved for Codex. Physical button numbers and firmware slot numbers
differ. These keys report presses to the
bridge instead of typing ordinary shortcuts. Consequently, session keys need
the bridge enabled; other keys keep working through Input/the device.

The top row is **0, 1** from left to right, in both the controller and Input's
keymap matrix. Labels, colors, clicks, and physical presses use those same
position IDs. See the [top-row mapping check](docs/top-row-mapping.md).

All twenty AG slots (AG00–AG19) are shared across layers. **Use Codex desktop
buttons** is a prominent setting in Configure. It defaults on when the Codex app
is detected; existing configurations retain their previous six-slot reservation.
Your saved choice is respected on later launches. After changing it, apply each
configured layer again to update its bindings.

T3, cmux and Herdr layers can share Micro Manager's slots. One bridge follows the
active physical layer, routes presses to its provider, and keeps assignments and
read state separate. It checks the active layer again on a press. Unconfigured
layers receive no bridge lighting or actions. The panel reports detected slot
reuse on other layers; independent controllers must also respect the active layer.
Keep the Codex reservation enabled while its desktop controller is in use.

**Restore buttons** restores the previous values for bindings still owned by
Micro Manager. Later changes made in Input are kept. Restore before moving or
removing an applied layer configuration. Adding another provider layer keeps the
existing layer and its restoration record intact. Full device exports and the
restoration record are saved before device writes; the dashboard can reveal the
backup. An interrupted slot change retains recovery information for both the
previous and attempted bindings until the device confirms the change.

If you applied the first build, choose **Save & apply this layer** once in the
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
- **T3 sidebar order:** T3's pinned section, then its active section, including
  positions you arrange by dragging in T3. Settled and snoozed threads do not
  occupy keys. This follows all projects on the configured connection; T3's
  temporary project filters and other connected environments are not mirrored.

Choose the mode in **Configure → Session assignments**, then **Save settings**;
there is no need to apply the hardware mapping again. In T3 sidebar order, the
menu and keys follow the same order, and dragging a running thread also moves its
key on the next refresh. Micro Manager's per-key pins are ignored in this mode
and remain saved for the other modes. New and un-settled threads move up as they
do in T3. Snoozed threads return when T3's wake rules make them active again.

In the other modes, running sessions and sessions needing input retain their current automatic slot
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
python3 scripts/verify-signing.py      # temporary certificate + two distinct builds
./scripts/verify-emulator.sh
./scripts/verify-bridge.sh            # isolated config + emulator; no hardware
./scripts/verify-providers.sh         # provider lifecycle, inputs, pins, connection races
./scripts/verify-layers.sh            # multi-layer routing, shared slots, Codex reservation
./scripts/verify-cmux.sh              # cmux protocol/status fixtures; no live input
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
