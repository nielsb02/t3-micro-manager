# T3 Code integration research

Research date: 2026-09-06. Research only: no personal conversations were queried, credentials read, settings changed, or T3 processes started.

## Versions examined

The installed app reports version **0.0.38**. The corresponding official release tag is [`v0.0.38`, commit `c0995d2eaf8ec787b3318ed1169ae266ed1529f8`](https://github.com/pingdotgg/t3code/tree/c0995d2eaf8ec787b3318ed1169ae266ed1529f8). Current upstream `main` was also inspected at [`223ff4490f764a74ff911589e97b9bbcd595fee8`](https://github.com/pingdotgg/t3code/tree/223ff4490f764a74ff911589e97b9bbcd595fee8). Local source checkout: `/tmp/t3code-micro-research`.

The APIs below exist in the release tag matching the installed version. This is source verification, not an authenticated live compatibility test against the installed binary. These are internal application contracts, not a promised stable peripheral/plugin API.

## Confirmed status interface

T3 exposes an authenticated `GET /api/orchestration/shell` returning project and thread summaries. This is a particularly good fit: the bridge can obtain identifiers, titles and status without downloading conversation messages. The full snapshot and per-thread detail endpoints also exist but are unnecessary for LEDs. [HTTP contracts at v0.0.38](https://github.com/pingdotgg/t3code/blob/v0.0.38/packages/contracts/src/environmentHttp.ts)

A thread summary includes:

- `id`, `projectId`, `title`, `updatedAt`, `archivedAt`, pin/snooze/settled metadata.
- `session.status`: `idle`, `starting`, `running`, `ready`, `interrupted`, `stopped`, or `error`.
- `hasPendingApprovals`, `hasPendingUserInput`, `hasActionableProposedPlan`.
- `latestTurn`, optional `backgroundLiveness` (`working` / `monitoring`) and optional plan progress.

These fields already exist in **0.0.38**, not only current main. [Versioned orchestration schemas](https://github.com/pingdotgg/t3code/blob/v0.0.38/packages/contracts/src/orchestration.ts)

For push updates, `orchestration.subscribeShell` returns an initial snapshot followed by project/thread upserts and removals. Sequence numbers and `afterSequence` support reconnection. It uses T3's Effect RPC transport; it is not interchangeable with the Herdr protocol. For this local prototype, polling the small HTTP summary every 0.5–1 second is a reasonable proposed starting point. Add streaming only if latency or polling overhead warrants it.

Proposed LED interpretation: pending approval/input/plan first, then errors, then running/starting/background work, then ready/completed, otherwise idle. Keep disconnected/stale distinct from idle. `ready` alone does not mean an unseen completion; a briefly latched “finished” indicator requires observing a state transition. Upstream also has an awareness status projector that illustrates approval/input precedence, but its `/threads/...` links are for the awareness/mobile context, **not the web thread route**. [Current awareness projector](https://github.com/pingdotgg/t3code/blob/223ff4490f764a74ff911589e97b9bbcd595fee8/packages/shared/src/agentAwareness.ts)

## Connection and authentication

T3 supplies a public environment descriptor at `/.well-known/t3/environment`, bearer/cookie authentication, a pairing/bootstrap exchange at `POST /oauth/token`, and authenticated `POST /api/auth/websocket-ticket` for socket clients. A local bridge should use its own paired session and request `orchestration:read` where the issuance flow permits. Pairing grants and scope enforcement must be respected; do not assume localhost is unauthenticated. [Auth contracts](https://github.com/pingdotgg/t3code/blob/v0.0.38/packages/contracts/src/auth.ts), [HTTP endpoints](https://github.com/pingdotgg/t3code/blob/v0.0.38/packages/contracts/src/environmentHttp.ts), [authentication architecture](https://github.com/pingdotgg/t3code/blob/223ff4490f764a74ff911589e97b9bbcd595fee8/docs/internals/environment-auth.md)

The existing desktop app already manages a local server and has a loopback HTTP endpoint. Reuse that environment instead of starting a separate `npx t3` server, which could target different state or contend for a port. Configure the actual endpoint; do not hard-code a discovered port into the integration. Desktop bootstrap credentials are an internal handoff, not an integration setup UX. [Desktop server exposure](https://github.com/pingdotgg/t3code/blob/v0.0.38/apps/desktop/src/backend/DesktopServerExposure.ts), [desktop authentication](https://github.com/pingdotgg/t3code/blob/v0.0.38/apps/desktop/src/backend/DesktopLocalEnvironmentAuth.ts)

T3's user-facing connection controls are in **Settings → Connections**. Official documentation describes pairing links and `npx t3 pair` for an already-running server. The local desktop pairing flow and how the CLI finds the desktop environment need a live verification before committing to an automatic setup wizard. A loopback-only bridge should not need public network exposure. [Official connection guide](https://github.com/pingdotgg/t3code/blob/v0.0.38/docs/user/remote-access.md)

## Opening a particular session

**Confirmed web route:** `/<environmentId>/<threadId>`, with each identifier URL encoded. An authenticated browser client connected to that environment can navigate there. Use the T3 thread ID, not the underlying Codex provider session ID. [v0.0.38 route](https://github.com/pingdotgg/t3code/blob/v0.0.38/apps/web/src/routes/_chat.%24environmentId.%24threadId.tsx)

**Desktop exact-thread deep link: not confirmed.** The installed app registers `t3code` and `t3code-dev`, but registration alone does not establish a thread-opening contract. Source uses the scheme for the renderer and Clerk authentication callbacks. Its second-instance handler reveals the window; no arbitrary-thread OS URL handler was found in either inspected revision. Do not promise `open 't3code://...'` will navigate to a thread. [Desktop Clerk handler](https://github.com/pingdotgg/t3code/blob/v0.0.38/apps/desktop/src/app/DesktopClerk.ts), [desktop renderer protocol](https://github.com/pingdotgg/t3code/blob/v0.0.38/apps/desktop/src/electron/ElectronProtocol.ts)

Three implementation options:

1. **Browser target:** open the authenticated local web URL for a chosen thread. This has the clearest existing route contract. Browser focus/tab reuse is a separate small UX choice.
2. **Desktop keyboard shortcuts:** activate T3 and send `thread.jump.1`–`thread.jump.9`, `thread.next`, or `thread.previous`. These commands exist, but jump slots depend on the current client's sidebar order. An LED assignment based only on server ordering could select the wrong thread. This works only if mappings explicitly follow and validate that order.
3. **Desktop exact ID target:** first prove an existing entry point or add a narrow T3-side navigation hook. A small upstream/local desktop patch is more reliable than searching thread titles through the UI, but adds a second codebase to maintain.

T3 shortcuts are configurable in **Settings → Keybindings**, backed by `~/.t3/userdata/keybindings.json` by default. Commands also cover new chats, terminal, diff, preview and project scripts. These are optional mapping opportunities, not requirements for the status/open-thread MVP. [Keybinding commands at v0.0.38](https://github.com/pingdotgg/t3code/blob/v0.0.38/packages/contracts/src/keybindings.ts), [keybinding guide](https://github.com/pingdotgg/t3code/blob/v0.0.38/docs/user/keybindings.md)

## Recommended implementation boundary

### Follow-up: remote environments through the Mac client

The user requires Micro Manager to connect only to the Mac's T3 client, including when that client displays multiple remote environments. Source tracing confirms that polling the primary local environment alone does not satisfy this requirement:

- In v0.0.38, `fetchEnvironmentShellSnapshot` constructs the shell URL using the individual prepared connection's `httpBaseUrl` and its authorization. It does not ask the primary server to aggregate other environments. [Client HTTP loader](https://github.com/pingdotgg/t3code/blob/v0.0.38/packages/client-runtime/src/state/shellSnapshotHttp.ts).
- The server handler calls its own `ProjectionSnapshotQuery.getShellSnapshot()`, whose implementation queries project, thread, session, and turn projections from its database. [HTTP handler](https://github.com/pingdotgg/t3code/blob/v0.0.38/apps/server/src/orchestration/http.ts), [projection implementation](https://github.com/pingdotgg/t3code/blob/v0.0.38/apps/server/src/orchestration/Layers/ProjectionSnapshotQuery.ts).
- Client shell state and snapshots are keyed by environment ID. The client combines the environment states. [Shell state](https://github.com/pingdotgg/t3code/blob/v0.0.38/packages/client-runtime/src/state/shell.ts), [snapshot state](https://github.com/pingdotgg/t3code/blob/v0.0.38/packages/client-runtime/src/state/snapshots.ts).

Current main contains a local desktop control socket that was absent in v0.0.38. However, its request schema only accepts `open-workspace` with a path and platform. The renderer targets the primary local environment and opens a new thread for that project. It does not provide combined session status or accept an arbitrary environment/thread target. A thread ID in the response is not an exact-thread navigation input. [Activation contract](https://github.com/pingdotgg/t3code/blob/223ff4490f764a74ff911589e97b9bbcd595fee8/packages/contracts/src/desktopAppActivation.ts), [renderer handler](https://github.com/pingdotgg/t3code/blob/223ff4490f764a74ff911589e97b9bbcd595fee8/apps/web/src/desktopAppActivation.ts).

Conclusion: no suitable existing external desktop API was found in the inspected source. To meet both local-only integration and arbitrary exact-thread navigation, the smallest source-based approach appears to be extending the desktop control mechanism with session summaries and environment/thread navigation. This is a proposed T3 change, not existing support or a claim that every possible automation approach is ruled out. Reusing the client's existing state would avoid duplicating remote authentication and connection management. The earlier HTTP polling recommendation below applies to a single environment or to a bridge allowed to connect to each environment directly; it does not meet the user's clarified local-client-only requirement by itself.

Retain Herdr behind a provider adapter. Add a T3 adapter that reads the shell summary, normalizes status, and opens a provider-qualified thread reference `{provider, environmentId, threadId}`. Keep scene and key ownership in the hardware/mapping layer. Preserve microphone and other existing actions independently of the session provider.

For the first implementation, settle two acceptance checks before broad work: pair the bridge to the **existing** desktop environment and read its summary; prove the chosen **desktop or browser** exact-thread opening behavior. Status integration is well supported already. Exact desktop navigation is the principal unresolved product requirement, not LED data availability.
