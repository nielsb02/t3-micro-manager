# cmux integration research

Research date: 2026-09-06. Source and documentation research; no application settings or agent hooks were changed. The intended product is the Ghostty-based macOS terminal [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux).


## Implementation baseline, 2026-09-07

The accepted implementation requires stock cmux 0.64.22 or newer and the required
running-server control capabilities. The earlier 0.62.2 fallback discussion below
is historical research, not supported behavior. cmux has been updated locally to
0.64.22. External socket access still requires Automation mode or authentication.

The implementation defaults to workspace keys, with a menu/configuration switch
to terminals and browser tabs in one selected workspace. Layer configurations
keep provider, view, keys and pins separately. T3/cmux/Herdr share bridge-owned
slots across hardware layers; the global visible Codex setting reserves AG00–05
when enabled. New settings infer that default from the installed Codex app, while
existing settings preserve their prior reservation. The bridge follows the live
hardware layer and backs up/restores each configured device layer separately.

See [current setup instructions](../README.md#connect-cmux) and
[provider/layer contract](provider-architecture.md#layer-configurations-and-cmux).

## Completed-turn and control verification, 2026-09-07

Live testing exposed two distinct cmux 0.64.22 states: Codex retained an older
active prompt after a newer turn completed, and Claude's idle reminder changed
its lifecycle to `needsInput`. The adapter now reconciles the hook snapshot with
`feed.list` parent Stop events and pending request records. The original live
reproduction changed from `working, blocked` to `idle, idle`, without restarting
cmux or the agents and without rewriting their hooks. Regression fixtures also
cover a new prompt after completion, true permission requests, native reads,
custom notification titles and unrelated or stale feed records.

The controls proposed below are now implemented as per-layer configurable actions,
including the dial, cardinal joystick sectors, explicit Submit/Escape/interrupt,
text macros, attention navigation and a dictation-compatible command panel.
The preset and slot limits are documented in the [current controls guide](../README.md#cmux-controls-and-dictation).
The remainder of this document preserves the original research context; its
references to unimplemented features describe the initial checkout.

## Versions examined

| Version | Revision | Significance |
| --- | --- | --- |
| v0.62.2 | `6c203b5144747729b5a96a9b60b7b612acc7ba63` | Matches the installed version identified during this investigation |
| v0.64.22 | `ddd4a01bc5d8ebac19643930f5fd7d40e85f1534` | Latest stable reported by the GitHub releases API; published 2026-08-03 |
| main | `c3216e922cf4eb89b063c3be2e5c2047daf56b50` | Current source inspected; do not assume these changes are installed |

[Installed-version source](https://github.com/manaflow-ai/cmux/tree/v0.62.2), [latest stable release](https://github.com/manaflow-ai/cmux/releases/tag/v0.64.22), [main revision](https://github.com/manaflow-ai/cmux/tree/c3216e922cf4eb89b063c3be2e5c2047daf56b50). The temporary research checkout is `/tmp/cmux-research-upstream`.

Local checks found `/Applications/cmux.app`, bundle ID `com.cmuxterm.app`. The bundled CLI reported `cmux 0.62.2 (77) [6c203b514]`. Its help lists hierarchy, focus, input, notification and Claude-hook commands. The running app's socket is `~/Library/Application Support/cmux/cmux.sock`. A read-only capability request failed; a direct connection returned `ERROR: Access denied — only processes started inside cmux can connect`. Consequently, this investigation verified installed command availability and the access restriction, but did not retrieve live sessions or test focus/input. No access setting was changed.

## Existing control interface

cmux already exposes a local Unix socket and CLI. The JSON protocol is newline-delimited requests shaped as `{ "id": "request-id", "method": "workspace.list", "params": {} }`, with success/error responses. Inspect `system.capabilities` to discover methods on the running version. The CLI resolves the socket path; do not assume the documentation's `/tmp/cmux.sock` example is the only possible location. [Official API reference](https://cmux.com/docs/api), [v0.62.2 CLI socket resolver](https://github.com/manaflow-ai/cmux/blob/v0.62.2/CLI/cmux.swift).

The following control operations already exist in v0.62.2:

| Need | Interface |
| --- | --- |
| Discover hierarchy | `window.list`, `workspace.list`, `pane.list`, `surface.list`; CLI `tree` |
| Open an exact target | `window.focus`, `workspace.select`, `surface.focus` |
| Change split focus | `pane.focus` by ID; cmux shortcuts provide directional navigation |
| Insert text | `surface.send_text`, targeting a surface UUID |
| Press a terminal key | `surface.send_key`, targeting a surface UUID |
| Read notifications | `notification.list` |
| Read sidebar status | Legacy socket `list_status --tab=<workspace UUID>` / CLI `list-status` |
| Read sidebar metadata | Legacy socket `sidebar_state --tab=<workspace UUID>` / CLI `sidebar-state` |

These are application-owned operations; ordinary navigation and targeted terminal input do not need a cmux fork. Use full UUIDs in persistent assignments. List indices and human-friendly refs are useful for presentation, but physical keys must not silently change their target when order changes. Workspace/surface list responses include UUIDs, titles and selection context. Iterate windows explicitly; `workspace.list` resolves one window's manager, not necessarily every window. [v0.62.2 server implementation and capabilities](https://github.com/manaflow-ai/cmux/blob/v0.62.2/Sources/TerminalController.swift#L3041).

Socket authorization is separate from API availability. v0.62.2 supports **cmux processes only**, **Automation mode** (external clients belonging to the same macOS user), and **Password mode**, in addition to Off and Full open access. Automation mode is the natural candidate for a separately running local Micro Manager. The live setting must be configured deliberately; do not replace it with unrestricted access. The current public API page omits modes present in this versioned source. [v0.62.2 socket settings](https://github.com/manaflow-ai/cmux/blob/v0.62.2/Sources/SocketControlSettings.swift#L7).

## Hierarchy and useful mapping unit

The app hierarchy is **window → workspace → pane → surface**. Workspaces are sidebar entries, sometimes called tabs. A pane is a split region. A surface is one terminal or browser tab within that pane. A working directory is metadata: multiple agents can share one folder, and a shell can change directories without becoming a new session. Current cmux also supports collapsible workspace groups; these are a grouping feature, not individual agent identity. [Official concepts](https://cmux.com/docs/concepts).

Proposed default: one lit key per workspace, aggregating its agents, with optional pins to an individual terminal surface. This keeps a project and its agent, server, logs and browser together. Use workspace groups as optional banks when the number of workspaces exceeds the available keys. A folder path can label or filter a bank, but must not identify the target.

Track `{ connection, workspaceID, surfaceID }` for an exact live terminal target, alongside its window ID and native agent session ID where available. Keep assignments stable while the app runs. Revalidate IDs after restart or restore; preserve an unavailable pin until a reliable identity match or explicit remapping exists. On v0.62.2, the available Claude status is workspace-scoped, so the reliable initial convention is one monitored agent per workspace. Do not copy the same workspace status onto several surface buttons as if it were separate evidence.

## What agent state is available

### Installed-version source: v0.62.2

The bundled Claude wrapper registers lifecycle hooks. `prompt-submit` writes a `claude_code` status of **Running**; `stop` writes **Idle** and can emit a completion notification; `notification` writes **Needs input**. `session-start` records the process/session mapping without immediately claiming Running. Those strings can be read through `list-status` or `sidebar-state`. The status entry is keyed by workspace and provider, so concurrent Claude terminals in one workspace can overwrite the same entry. [Claude wrapper](https://github.com/manaflow-ai/cmux/blob/v0.62.2/Resources/bin/claude), [v0.62.2 hook implementation](https://github.com/manaflow-ai/cmux/blob/v0.62.2/CLI/cmux.swift#L8454).

No `cmux sessions` command, `agent_lifecycle` / `runtime_status` read schema, or `events.stream` implementation was found in this tag. Native generic Codex hooks in newer releases must not be assumed present here. Ordinary arbitrary terminals have no trustworthy agent status simply because cmux can focus or read them.

### Stable v0.64.22: substantially better session metadata

`cmux sessions list --json` returns records including `agent`, `session_id`, `workspace_id`, `surface_id`, `updated_at`, `pid`, `runtime_status`, `agent_lifecycle`, `last_prompt_turn_id`, `active_prompt_turn_id`, `active_for_surface`, `active_for_workspace` and restorable-session metadata. [Versioned session-list implementation](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/CMUXCLI%2BSessionsList.swift#L156).

**This command reads local hook-session stores and performs transcript/index diagnostics; it is not a socket `agent.list` endpoint or a guaranteed snapshot of live surfaces.** Its default results can include restorable and historical sessions. A provider must join records to the current socket surface inventory and select the active record for each surface. Do not scrape or send transcripts merely to obtain LED state; evaluate this CLI's I/O and returned metadata before choosing its polling cadence. No narrower generic per-surface lifecycle socket read was confirmed in this bounded investigation. [Store loading](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/CMUXCLI%2BSessionsList.swift#L120), [visibility and output](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/CMUXCLI%2BSessionsList.swift#L248).

`runtime_status` distinguishes **running / idle / needsInput / error**. `agent_lifecycle` distinguishes **unknown / running / idle / needsInput** and also informs hibernation. They are related but separate state projections. Neither offers a universal `done`, pending-approval boolean, background-work count or completed-objective state. A process staying alive is not evidence it is working. [Runtime enum](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/cmux.swift#L61), [lifecycle enum](https://github.com/manaflow-ai/cmux/blob/v0.64.22/Sources/AgentHibernation/AgentHibernationLifecycleState.swift).

Stable v0.64.22 includes `cmux hooks setup` and agent-specific integration, including Codex. Hook delivery and agent support still determine accuracy. Turning on a generic terminal notification cannot provide missing start/stop/input events. [Stable hook setup commands](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/cmux.swift#L15786), [Codex hook injection](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/CMUXCLI%2BCodexFireAndForgetHooks.swift).

Treat **pending** according to its source. A pending approval/feed request, a manual checklist item, an unread notification and an agent waiting for input are different facts. Sidebar status/progress entries can also be written by arbitrary scripts. Do not classify a whole workspace as working because a build script set a pill or spinner. Notification classification distinguishes turn completion, permission and idle reminders, but some classification uses textual cues; `needsInput` alone does not distinguish a question from a permission request. [Notification classification](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/AgentHookNotificationPolicy.swift), [workspace checklist logic](https://github.com/manaflow-ai/cmux/blob/v0.64.22/Sources/Workspace%2BTodos.swift), [manual lifecycle exclusions](https://github.com/manaflow-ai/cmux/blob/v0.64.22/Sources/AgentHibernation/AgentHibernationLifecycleState.swift).

Proposed LED normalization: needs-input/error takes attention priority, running means observed running, and done requires an observed turn-completion event or a matching unread completion notification. Idle is merely idle. Unknown, stale and disconnected remain explicit. Do not infer durable objective completion from a turn ending, or clear a real waiting state just because its notification was read. Validate interruptions, permissions, multiple agents and background tasks against actual agent behavior before trusting this operationally.

## Notifications, acknowledgement and updates

v0.62.2 `notification.list` includes a notification UUID, workspace UUID, optional surface UUID, `is_read`, title, subtitle and body. Notification IDs can distinguish new unread events. Completion and approval notifications must be distinguished; an unread notification is not automatically a completed answer. This tag exposes list/clear, but not the later `notification.open` or `notification.mark_read` socket methods. Exact workspace/surface focus remains available. [v0.62.2 notification payload](https://github.com/manaflow-ai/cmux/blob/v0.62.2/Sources/TerminalController.swift#L5550).

Stable v0.64.22 adds `notification.mark_read` and `notification.open` (CLI `mark-notification-read` and `open-notification`), useful for a physical next-attention button that follows native read state. [Stable CLI notification operations](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/cmux.swift#L5421). The documented UI also offers notification navigation and custom notification commands, but those alone are not a complete lifecycle stream. [Official notification guide](https://cmux.com/docs/notifications).

Stable v0.64.22 has `events.stream` and `cmux events`, with event/category filters, `after_seq` replay, acknowledgement frames, heartbeats and reconnect support. Events cover workspace/pane/surface lifecycle, notification changes, sidebar metadata and received agent hooks. This is useful for triggering a fresh snapshot; it does not turn the hook-store CLI into an authoritative socket session snapshot. Handle reconnect/replay gaps with a full refresh and retain periodic reconciliation. v0.62.2 needs polling. [Stable stream server](https://github.com/manaflow-ai/cmux/blob/v0.64.22/Sources/CmuxEventStream.swift), [CLI stream](https://github.com/manaflow-ai/cmux/blob/v0.64.22/CLI/CMUXCLI%2BEvents.swift), [published hook and lifecycle events](https://github.com/manaflow-ai/cmux/blob/v0.64.22/Sources/CmuxEventPublishing.swift#L414), [sidebar event mapping](https://github.com/manaflow-ai/cmux/blob/v0.64.22/Sources/CmuxSocketEventMapper.swift#L190).

## Recommended implementation boundary

Add a `CmuxSessionProvider` using the existing provider boundary. Reuse assignment stability, acknowledgement, lighting and device mapping. Implement the optional input provider with explicit target IDs and separate insert/submit actions. Navigation should use cmux's API; a voice tool can provide text to the focused terminal or an explicitly selected surface.

Start by proving stock cmux connectivity and exact focus, then one agent's status transitions. On the installed release, offer a workspace-based Claude mode with clear limitations. For several agents per workspace and Codex, prefer a normal stable cmux upgrade and supported hook setup before considering a fork. A narrow supplemental hook adapter is another option for missing state. Consider an upstream addition only if testing establishes a required missing contract, such as a compact authoritative socket session snapshot. None of these findings requires replacing the existing hardware protocol.

## Fit with this repository

The existing terminal provider is Herdr. The active factory currently registers T3, Herdr and demo; cmux is not implemented. `SessionProvider` covers listing and exact opening. `SessionInputProvider` covers text insertion and advertised actions, but the dashboard does not assign those actions to hardware. The bridge owns its polling loop, so an initial cmux adapter should use that lifecycle. If event-triggered updates follow, the bridge should own and cancel that subscription too. [Provider contract](provider-architecture.md), [factory and optional inputs](../Sources/WLKit/SessionProvider.swift), [bridge](../Sources/WLKit/BridgeController.swift).

A workspace key should use the existing aggregation order: error, needs input, working, unknown, finished, idle. On press, select that workspace and focus its agent needing attention, otherwise its last selected terminal. This is proposed behavior; an individual surface pin always opens its exact surface. Reuse the current amber/cyan/green/lavender/red/gray palette. A completion ID or matching completion notification distinguishes a new result from an already acknowledged one. [Status aggregation](../Sources/WLKit/AgentSession.swift), [appearance](../Sources/WLKit/SessionAppearance.swift).

## Proposed controls

| Control | Default action |
| --- | --- |
| Six status keys | Pinned workspaces; optional individual agent pins |
| Dial rotation | Previous/next terminal tab in the focused pane |
| Navigation modifier + dial | Previous/next workspace, including those beyond the six keys |
| Joystick cardinal directions | Move focus between split panes |
| Dial press or spare button | Next agent needing attention, then unread completion |
| Wide microphone key | Existing voice dictation shortcut |
| Spare buttons | Explicit Submit, Escape, interrupt, and navigation modifier |
| Optional second bank/layer | Named prompt macros, new terminal/workspace, group selection |

The intended daily loop is workspace selection, terminal navigation, dictation, then explicit submission. Text insertion should not add Enter. Spoken navigation such as "open backend" needs a separate command mode that resolves names to current IDs; text replacements alone do not invoke cmux commands. Use a button to enter that mode so ordinary dictated prompts keep their meaning. During dictation, preserve the intended terminal target, either by keeping focus fixed or delivering a captured transcript to its recorded surface ID. These are design proposals, not installed bindings.

The firmware already supports discrete dial and joystick events and optional raw radial joystick data. Neither control has an LED. However, the old `AG13`–`AG18` dial/joystick examples are not safe to copy into the active mapping: selected physical keys now map to `AG06`–`AG18`, and Codex reserves `AG00`–`AG05`. All 20 slots are shared across layers. Allocate buttons and controls together; use ordinary cmux shortcuts for navigation controls where useful. Layer selection alone cannot isolate independent LED writers. The current dashboard manages one provider/layer, so automatic T3/cmux layer switching is a separate extension. [Hardware controls](hacking.md#10-the-dial-and-the-joystick), [current slot mapping](../Sources/WLKit/LayerMapping.swift), [coexistence notes](../README.md#choose-your-buttons).

Recommended sequence:

1. Target stock v0.64.22 and configure same-user Automation mode or authenticated socket access. Verify capabilities, exact focus and hooks before relying on status.
2. Add the cmux provider, workspace assignments and status normalization. Check multiple agents in one workspace, a completion between polls, missing hooks, native notification reads and reconnects in the emulator and then against cmux.
3. Add control bindings and voice command mode, with a coordinated firmware-slot allocation. Verify real dial/joystick routing and coexistence with the existing integrations.

This research added documentation only. Live focus, agent transitions and physical controls remain implementation acceptance checks.
