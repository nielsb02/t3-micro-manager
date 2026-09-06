# Codex opening from the T3 layer

Investigated on 2026-09-06 after the user reported that pressing a session key on
layer 2 opened Codex.

The saved mapping identifies the Codex layer as profile 0 / layer ID 3 and the
T3 layer as profile 0 / layer ID 4. Both used `KV_OAI_AG00` through `KV_OAI_AG05`
on the top six buttons. The bridge checked the active layer before handling an
event, but the same HID notification also reached Codex. Layer gating in one
client cannot prevent another client from receiving the shared event.

The original implementation incorrectly treated a firmware AG slot number as a
physical switch number. The firmware supports independent slot assignments.
The [other implementation's hardware findings](https://github.com/okko/micro2-agent-keys/blob/51c45439abeb91f9c6b4a278379dc707c51c0057/docs/findings.md#L64-L68)
and [AG18/AG19 hardware test](https://github.com/okko/micro2-agent-keys/blob/51c45439abeb91f9c6b4a278379dc707c51c0057/src/research/ag1819test.ts#L13-L18)
confirm that the LED and input follow the bound slot, rather than the physical
position.

Static inspection of the installed Codex application, `/Applications/ChatGPT.app`,
bundle `com.openai.codex`, version 26.825.51511 build 7377, confirmed:

- Its bundled service HID handler recognizes session slots with `/^AG0([0-5])$/`.
- The main process returns before opening/focusing a session when the parsed slot is null.
- Its normal per-thread lighting list has six entries, numbered 0 through 5.

The relevant bundled files are `.vite/build/service-gV37mc1B.js` and
`.vite/build/main-OcJ5u9xL.js` inside `Contents/Resources/app.asar`. This is evidence
for the installed version, not a promise about future Codex releases.

## Correction

Physical switch `p` now maps to AG slot `p + 6`. The thirteen configurable
positions therefore use AG06–AG18; the default top six use AG06–AG11. Incoming
events translate back to physical positions, and outgoing lighting translates
to firmware slots. Codex slots 0–5 are excluded from both writes and input
handling. The emulator now models these two coordinate systems separately.

Backup records include the exact installed keycodes. Records from the first
build lack that field and are decoded using their original same-numbered slots.
Reapplying first restores those old bindings in memory, captures the original
values, and installs the separate slots. Restoration continues to preserve
later edits made in Input. Existing records do not authorize lighting until
their installed slot assignments match the corrected mapping.

Validation covers nonoverlapping slots, migration from a first-build backup,
unchanged Codex layer and microphone bindings, actual emulator press/release
routing, and preserving Codex slot lighting during repaint and stop.

This addresses session-opening collisions and per-thread lighting IDs. Whole-
device lighting zones remain shared between applications. Hardware behavior
must be checked after applying the corrected mapping on the real Micro.
