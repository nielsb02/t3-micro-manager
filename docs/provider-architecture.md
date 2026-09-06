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

The bridge keeps one provider instance for its configured connection. Testing an
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
adapters are `T3SessionProvider`, `HerdrSessionProvider` and `DemoSessionProvider`.
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

T3 does not implement this optional interface: its current pairing is read-only.
The configuration dashboard does not bind text or custom actions yet. A future
binding UI can use the advertised capabilities without changing the device
transport. Wispr Flow and ordinary shortcuts remain configured in Work Louder
Input.

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
