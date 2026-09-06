# Local proof of concept verification

Verified on 2026-09-06 with macOS, Swift 6.0.3 Command Line Tools, and T3 Code 0.0.38.

Implemented a standalone native configuration window and menu-bar session viewer,
T3 and Herdr session sources, configurable profile/layer and button selection,
Pinned/Recent/Pinned + Recent assignment, optional ambient lighting, scoped
mapping backup/restoration, and a multi-layer emulator. Device mappings are
applied explicitly rather than automatically on startup. T3 session presses open
the exact environment/thread route in the browser. Desktop navigation and
combined remote environments remain outside this version.

Verification completed:

- `swift build --product WLMicroManager` and the release app/Inspector bundle build passed.
- `scripts/verify-mapping.sh`: all nine original mapping regression methods passed.
- `scripts/verify-t3.sh`: all nine original provider regression methods passed,
  including pairing, HTTP authorization, status precedence, URL encoding,
  malformed responses, and endpoint discovery.
- `scripts/verify-bridge.sh`: assignment modes, active slot retention, missing
  pins, layer gating, selected-key lighting, ambient preservation, scoped restore,
  unclaimed AG binding protection, and relinquishing ownership after restoring
  adopted AG bindings passed. Configuration and backup files were isolated in a
  temporary directory; only the emulator was used.
- `scripts/connect-t3.py`: paired a dedicated read-only client with the existing
  running T3 server. No additional T3 server or network exposure was configured.
- `scripts/verify-bridge.sh --check-t3`: the production Swift client loaded four
  live session summaries and generated their exact environment/thread URLs.
  Conversation bodies were not read.
- Native dashboard rendering was inspected at `build/dashboard.png`.
- The bundled app passed code-signature verification with an ad-hoc signature.

The Mac has Command Line Tools but no XCTest module, so ordinary `swift test`
could not run. The two focused test scripts execute the original XCTest method
bodies using limited assertion shims when XCTest is unavailable. The full
upstream test suite has not been claimed as passing.

The read-only physical probe was refused by macOS with `0xE00002E2`,
`kIOReturnNotPermitted`. No hardware keymap was read or written. The standalone
app needs Input Monitoring before the user can select a real layer and apply
the reviewed bindings. Physical LED colors, physical key presses, and coexistence
with Codex/Input remain unverified.

The local setup saved a read-only bearer credential in the owner's configuration
directory with mode `0600`. It is outside the repository and app bundle. A
separate browser pairing link was opened; browser pairing completion and visible
thread navigation were not observed by automation.

## Later verification: persistent signing (0.1.4)

The earlier notes above describe the initial browser POC. Subsequent desktop
navigation work and its checks are recorded in [desktop-opening.md](desktop-opening.md).

On 2026-09-06, replaced ad-hoc local signing with a persistent, private local
certificate. `python3 scripts/verify-signing.py` passed fresh identity creation,
nested bundle validation, matching certificate requirements across changed
build hashes, rejection of an ad-hoc replacement, and failure without identity
rotation after incomplete setup. The user's keychain search list was preserved.

Installed signed version 0.1.3 in `/Applications/T3MicroManager.app`. After the
user granted Input Monitoring, installed and relaunched version 0.1.4 with the
same certificate. The new process's `kTCCServiceListenEvent` preflight returned
`authValue=2, authReason=4` (allowed), without another permission reset or grant.
The installed bundle passed deep, strict signature verification. The login item
was also confirmed enabled and pointing to the Applications installation.
