# T3 Code port investigation

Research date: 2026-09-06. Fork revision inspected: `32caf5a429cd0618dbb8c8354e34223d601ee235`.

Scope: inspect the existing bridge and propose a local T3 integration. No app was launched, no device configuration was written, and no live device tests were run. The connected pad's actual keymap and firmware remain unverified.

T3 API and navigation findings are in [t3-integration-research.md](t3-integration-research.md).

## How the existing mapping works

This is a native macOS Swift menu-bar app. `WLKit` contains the HID transport, firmware protocol, Herdr socket client, keymap writer, and bridge. The menu app and separate Inspector both reuse that library. There are no package dependencies in [Package.swift](../Package.swift).

The bridge reads `agent.list` from `~/.config/herdr/herdr.sock`, listens for pane lifecycle and status events, and polls every 2.5 seconds as a backstop. It assigns the first six agents in Herdr's returned order to six physical keys. A press calls `agent.focus` and raises the configured terminal, Ghostty by default. See [HerdrClient.swift](../Sources/WLKit/HerdrClient.swift) and [BridgeController.swift](../Sources/WLKit/BridgeController.swift).

There are two distinct mappings:

1. The device's `keymap.json` maps physical switches to keycodes on each profile/layer. `KV_OAI_AG00` and similar codes emit vendor HID notifications instead of ordinary keystrokes. The documented firmware requires these codes on the active layer for individual key lighting.
2. The running bridge maps those incoming AG numbers to sessions or actions. This mapping lives in Swift, with a limited JSON override for text macros.

The LED command `v.oai.thstatus` addresses AG slots with a color, brightness, and effect. Key presses arrive as `v.oai.hid` notifications. `v.oai.rgbcfg` controls whole-device lighting zones. Preserve [hacking.md](hacking.md), which documents framing, payloads, geometry, and firmware quirks. Its hardware observations were made on firmware `v0.6.0-rc.10`, not verified on this user's pad.

Physical layout, with firmware indices:

```text
       [1]        [0]
    [2] [3]    [4] [5]
    [6] [7]    [8] [9]
      [10 + 11]    [12]
```

| Control | Current bridge behavior |
| --- | --- |
| Keys 1, 0, 2, 3, 4, 5 | First six Herdr agents in reading order; press to focus |
| Key 6 | GitButler stack panel |
| Key 7 | Cycle Herdr tabs |
| Key 8 | Land GitButler branches |
| Keys 9 and 12 | Configurable prompt text macros |
| Wide key 10 + 11 | Synthesized right Command tap, unless a text macro overrides it |
| Dial rotation | Reasoning effort controls |
| Joystick cardinal directions | Model selection controls |

The dial click and joystick diagonals retain their existing bindings. All thirteen matrix key positions are currently rebound. See [OAIProtocol.swift](../Sources/WLKit/OAIProtocol.swift), [KeymapManager.swift](../Sources/WLKit/KeymapManager.swift), and [VoiceController.swift](../Sources/WLMicroManager/VoiceController.swift).

Existing colors are red/breathing for blocked, amber for working, blue for done/unseen, and green for idle/seen. The underglow aggregates all returned agents, including those beyond the six visible slots. The actual priority is `blocked > working > unknown > idle > done`, so idle can mask done in the underglow. See [StatusMapper.swift](../Sources/WLKit/StatusMapper.swift).

## Scenes and preserving the current setup

Work Louder calls these layers, supports up to six, and documents switching with the touch sensor. Its Input app can associate a layer with the foreground app using AppSense. The user's exact meaning of scene must be matched to the device's profile/layer values during read-only inspection. [Official setup guide](https://worklouder.cc/micro-setup).

The existing implementation is not ready for scene 2:

- It uses `activeProfileId` as an array index and always edits `layers[0]`.
- It reads `device.status` for battery information but does not use `layer_index` to select or gate its work.
- It consumes AG key events regardless of the active scene.
- It writes lighting without checking scene ownership. Its stop operation also clears lighting globally.
- It automatically rewrites bindings on startup/reconnect when they differ. There is readback verification, but no automatic persistent backup or restore flow.

These are source-code observations, not merely limitations of the README. A comment equating the active layer to the first layer is an assumption that must be removed. [KeymapManager.swift](../Sources/WLKit/KeymapManager.swift), [BridgeController.swift](../Sources/WLKit/BridgeController.swift).

Preserving scene 1's saved mapping and letting Codex and this bridge run together are separate requirements. The README documents competing writers from Codex and Input. Scene-gating our own writes and events is necessary, but does not prove the other applications will yield on scene 2. Coexistence needs an actual device check before claiming it works. [Existing contention documentation](../README.md#only-one-bridge-at-a-time).

For Wispr Flow, preserve the existing microphone mapping instead of inheriting the upstream right-Command assumption. If it is stored as a normal device shortcut, leave it intact and copy that mapping to the T3 layer when desired. If it is a host-app action, determine which app executes it and whether that app must remain running. An optional configurable shortcut action in the bridge can reproduce the trigger if necessary. The existing voice LED is only a local toggle, not a reading of actual dictation state.

## Where configuration and controls live

| Place | What it controls today |
| --- | --- |
| Work Louder Input | Device profiles/layers, ordinary shortcuts, actions, and app-linked layers |
| Device `keymap.json` | Stored physical bindings; this bridge reads and rewrites it directly |
| `~/.config/micromanager/config.json` | Text macros and Claude/Codex model/effort lists; honors `XDG_CONFIG_HOME` |
| Swift `BridgeConfig` | Colors, priorities, brightness, polling, and whether to manage the keymap; these are not exposed by the existing JSON parser |
| Micro Manager menu-bar panel | Live pad preview, agent list, enable switch, launch at login, emulator, Inspector |
| Inspector | Raw protocol log and manual device commands/lighting, not a normal mapping editor |

The JSON config reloads when the bridge starts, so toggling it off/on reloads it. It is not a general key-action editor: putting a string under arbitrary key numbers does not override the hardcoded session/stack/tab/land dispatch. Empty text removes a macro, but on the wide key it falls back to the voice action, so the README's general claim that an empty string unbinds a key is too broad. [KeyBindings.swift](../Sources/WLKit/KeyBindings.swift), [BridgeController.swift](../Sources/WLKit/BridgeController.swift).

Adding a T3 provider here will not automatically add a T3 integration panel inside Input or Codex. The practical control panel is the existing standalone menu-bar app, extended with provider selection, layer selection, session assignments, and a link to its config. Input remains useful for ordinary hardware customization. See [MenuPanelView.swift](../Sources/WLMicroManager/MenuPanelView.swift) and [official Input description](https://worklouder.cc/creator-micro-2).

## Proposed implementation

### Confirmed remote-environment requirement

The user plans to run execution on a dedicated Linux server while using T3 on the Mac as the client, potentially with multiple remote environments and local sessions. Micro Manager must connect locally to the Mac's T3 client rather than independently pairing with remote servers. The Micro remains attached to the Mac.

This changes the connection acceptance check: the local environment's shell endpoint cannot be assumed to aggregate all environments visible in the desktop UI. T3's web client uses environment-specific connection/runtime state. Verify a local desktop integration that can expose the client's combined session view and navigate by environment ID plus thread ID. If no such interface exists, a small T3-side bridge may be necessary. Do not silently substitute direct connections from Micro Manager to each remote server. See [versioned client orchestration state](https://github.com/pingdotgg/t3code/blob/v0.0.38/apps/web/src/state/orchestration.ts).

Keep the Swift app, HID transport, emulator, Inspector, and protocol guide. Separate Herdr-specific session fetching/focusing from the common bridge, with a small provider interface for session snapshots/updates and opening a session. Represent each session with a stable ID, title, normalized status, and navigation target. Keep provider-only actions behind explicit capabilities instead of assuming T3 supports Herdr's terminal controls.

Suggested first version:

1. Add a read-only device inspection/export operation. Identify the actual profile and layer IDs, export the complete keymap, and record the microphone binding before any modification.
2. Select the free second layer explicitly. Bind only the six session keys there; retain the microphone and other controls. Preserve every other layer and verify the write by reading it back. Keep the export for restoration.
3. Gate key handling and lighting on the selected profile/layer. Handle transitions without clearing or repainting another application's scene. Verify Codex and Input coexistence on the connected device.
4. Add a T3 provider using the connection and navigation method established in the companion research. Keep Herdr selectable. Prefer an explicit provider over silently changing providers when both run.
5. Keep six stable or pinned session assignments, with any overflow visible in the menu panel. Map working, needs-input, error, idle, and completed states from actual T3 evidence. A seen/unseen distinction needs reliable T3 data or clearly documented local semantics.
6. Extend the existing config and menu panel with provider, connection, target layer, and per-control actions such as session, shortcut, or preserve. These are proposed fields, not supported configuration today.

For the initial local tool, status LEDs and opening the exact session are the acceptance criteria. Model tuning, prompt injection, and GitButler actions can remain Herdr-specific until there is a reason to implement them for T3.

Verify pure mapping/status logic with fixtures and the emulator first. Hardware acceptance should include scene 1 unchanged, Wispr Flow still working, six session keys opening the intended sessions, working/attention/completed colors, reconnects, and scene switching while Codex is running. No build or runtime checks were needed for this research-only change.
