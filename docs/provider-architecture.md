# Providers and the bridge

`SessionProvider` is the boundary between an agent application and Micro Manager.
A provider lists sessions and opens an exact session. It receives application
connection settings, never a device handle or a physical key mapping.

| Component | Responsibility |
| --- | --- |
| `AgentSession` / `SessionStatus` | Common session identity, activity, completion revision and status |
| `SessionProvider` | List and open sessions on one connection |
| `SessionInputProvider` | Optional text insertion and advertised custom actions |
| `SessionAssignments` | Recent, pinned, mixed and provider order; stable slots during work in recency modes |
| `SessionAcknowledgements` | Local acknowledgement of a particular completed response |
| `SessionAppearance` | Shared colours, effects and pulse speeds |
| `BridgeController` | Polling, provider lifecycle, dispatch, layer checks and hardware lighting |
| `LayerMapping` | Selective bindings, AG slots, backups and restoration |

The bridge keeps a provider instance for each visited layer configuration and polls
the active layer. Physical layer changes select the corresponding provider and restore
its assignments and completion acknowledgements. A provider/connection change
invalidates that layer's cached instance. Testing an
unsaved connection uses a separate instance, shared by Test and Open while the
draft connection settings remain the same. A provider or connection change
replaces the active instance; changing session selection or physical keys reuses
it. Stopping cancels and drains an outstanding refresh before clearing lights or
changing settings. A result from an old opening request cannot acknowledge a
session or report an error on its replacement connection.

## Adding a provider

Implement the two operations on the main actor. Network and socket work must be
asynchronous, have a finite timeout and cooperate with task cancellation where
possible. `listSessions` must not start an unowned background polling task; the
bridge owns polling.

```swift
@MainActor final class ExampleProvider: SessionProvider {
    private let client: ExampleClient

    init(client: ExampleClient) { self.client = client }

    func listSessions() async throws -> [AgentSession] {
        try await client.sessions().map { item in
            AgentSession(id: item.id, title: item.title, status: item.normalizedStatus,
                         updatedAt: item.activityTimestamp, completionID: item.turnID)
        }
    }

    func openSession(_ session: AgentSession) async throws {
        try await client.focus(id: session.id)
    }
}
```

`ExampleClient` represents the new integration's own transport. The existing
adapters are `T3SessionProvider`, `CmuxSessionProvider`, `HerdrSessionProvider` and `DemoSessionProvider`.
Register a new built-in in `SessionProviderKind` and `SessionProviders.make`, add
any Codable connection settings and its configuration fields, and update
`SessionConfiguration.hasSameConnection` to compare those settings. Session
selection, the menu list and hardware routing need no provider-specific branches.
This is a compiled Swift interface, not a runtime plugin loader.

Provider snapshots must use unique, nonempty IDs and nonempty titles. IDs must
stay stable across polls and identify sessions within the connection; never
generate them from list position. Invalid snapshots fail visibly and retain the
previous sessions as disconnected. Empty valid snapshots clear assignments.
Normalize application states to `SessionStatus`; unfamiliar states become
`.unknown`. Supply activity timestamps in a consistent sortable format.

For app ordering, supply `AgentSession.providerOrder` as the position in the
provider's active list and include `.providerOrder` in its available selection
modes. A nil position excludes a session from that mode. The adapter owns the
app's sorting and visibility rules; the bridge uses the resulting order for both
the menu and keys, without local pins or retention of working slots. T3 supplies
its pinned and active sidebar positions, including snooze wake rules.

By default, the bridge acknowledges a `.done` session after successfully opening
it. Supply a stable `completionID` that changes for each new completed response,
such as a turn ID. If unavailable, the bridge falls back to `updatedAt`; metadata
changes can then count as a new completion. T3 uses its turn ID, with timestamps
as a fallback. It does not infer that the user has read a response directly in T3.

A provider with native seen/unseen tracking sets
`acknowledgementMode = .provider`. Its reported state is authoritative; Herdr
uses this mode. A simulation sets `requiresEmulator = true` so its sample
sessions cannot drive physical hardware.

## Optional inputs

Conform to `SessionInputProvider` only if the integration can accept inputs.
Its `inputCapabilities` advertises text support and a list of `SessionAction`
IDs with user-facing titles. `sendInput` implements the supported operations.

- `.text(String)` inserts text without implicitly submitting it. Herdr uses
  `pane.send_text` against a pane from its latest snapshot.
- `.action(String)` selects an advertised, provider-defined action ID. The
  bridge does not interpret IDs as shell commands or simulated keystrokes.

`BridgeController.sendInput(_:to:)` dispatches only to a current session on a
running bridge, checks the provider's capabilities, and rejects unknown actions
or unsupported input. A provider must also validate its inputs and target IDs.
Inputs are sent only on an explicit caller request, never in response to status
changes. No input is automatically submitted, approved or retried by the bridge.

T3 does not implement this optional text-input interface: its HTTP pairing is read-only.
Its opt-in dial, joystick and spare-button actions use the separate desktop control
socket with request/reply validation and a frontmost-application check. Each T3
layer retains its own control settings. Both providers use the same bounded input
queue; layer changes, invalid mappings and stopping cancel stale events, and
stopping drains in-flight work before switching connections.
cmux also implements `SessionControlProvider` for current-pane navigation,
workspace navigation, explicit input and named voice commands. Layer-specific
`controlBindings` connect buttons, encoder events and joystick directions to
those operations. `LayerMapping.slotAssignments` allocates controls alongside
session keys within the shared 20-slot limit. Codex reservations reduce that to
14. Text macros insert without Enter. Wispr Flow stays configured in Input.

## Verification

Run `./scripts/verify-providers.sh` for the protocol contract and bridge lifecycle
checks. It injects fake providers and uses an emulator with temporary settings:
no physical keymap changes, external text delivery, or live application opens.
The checks cover connection reuse, completion revisions, native read state,
provider-specific pins and legacy migration, unsupported inputs, malformed
snapshots, ambient effects, delayed opens and delayed polls.

`./scripts/verify-t3.sh` uses the actual WLKit module and T3 parser/HTTP fixtures.
`./scripts/verify-desktop.sh` exercises real local socket exchanges and a
disposable app fixture. `./scripts/verify-bridge.sh` covers physical-position
routing, AG slot isolation, selective lighting and mapping restoration.

The original Herdr action panels and `StatusMapper` remain as upstream reference
code. The active bridge uses the provider interface and `SessionAppearance`;
legacy macro settings and colour defaults do not configure the active bridge.

## Layer configurations and cmux

`SessionConfiguration.layers` stores named provider/layer configurations. The
selected layer exposes the existing provider, connection, key and pin properties.
Legacy single-layer files migrate into one configuration without changing their
Codex reservation. A physical device layer may occur only once; separate device
layers may use the same firmware AG slots because the bridge checks the live
layer before routing or painting.

The global `reserveCodexSlots` setting chooses an offset of six or zero. Mapping
records remain independent per hardware layer, including their actual owned
codes, so changing the offset can restore old bindings before applying new ones.
An attempted mapping is persisted alongside prior recovery ownership until
readback verifies the write. Restore and retry can recover either state after
an interruption without adopting the bridge's previous AG code as an original.
Saved configuration changes do not silently remap keys. Each affected layer needs
explicit Apply. An applied layer must be restored before moving or removing its
configuration.

cmux requires 0.64.22 and the required running-server capabilities. The client
joins current `system.tree` UUIDs to active hook records and native notifications.
The 0.64.22 Codex handlers do not populate `active_for_surface`. For unindexed
Codex records, the client checks a live PID, resolves it through
`agent.resolve_delivery_target`, and requires `surface.resume.get` to name the
same Codex checkpoint. Only that verified current terminal receives the status;
dead processes, replaced conversations and unproven bindings stay unknown.
Its workspace view aggregates monitored agents. Its selected-workspace view
returns terminal/browser surfaces, including unknown surfaces without agent
hooks. Pins use separate namespaces for those views. `SessionInputProvider`
accepts text insertion and explicit submit/escape/interrupt actions; these are
also selectable as explicit hardware control bindings.

Use `verify-layers.sh` and `verify-cmux.sh` alongside the existing provider and
bridge checks. These use temporary configuration and fixtures, never live
terminal input or physical remapping. Layer regressions cover continued polling
after startup selects another layer, a first press during an old provider's
pending refresh, and restoration or retry after an interrupted slot change.

The `feed.list` response supplies typed parent Stop events and pending permissions,
questions and plan requests, keyed by agent and session. It corrects stale running
state in cmux 0.64.22's Codex prompt stack. Tool-result events, which also contain
subagent exits and idle reminders, cannot end a parent response. The newest
prompt/tool start supersedes an older Stop. A Claude Waiting notification matching
the hook update and a completed parent response is idle, not blocked. Error and
real pending approval states remain authoritative. Native unread notifications
still determine green completion lights; reading them in cmux clears green.

HID controls are serialized, checked against the actual hardware layer before
dispatch, and canceled and drained when the bridge stops. A voice command panel
keeps its layer identity and rejects submission after a layer change. Its Submit
and Escape actions are intercepted while the panel is open, so one physical press
cannot also reach a terminal. The optional controls remain disabled for saved
configurations until selected and applied.

`./scripts/verify-controls.sh` checks allocation, capacity, round-trip settings,
dial/joystick restoration, queued emulator HID events and panel interception.
`./scripts/verify-cmux.sh` covers native navigation and lifecycle reconciliation
through a real CLI fixture process. Live read-only checks are available with
`./scripts/verify-cmux.sh --live`. A full physical dial/joystick acceptance check
still requires using the configured hardware layer.
