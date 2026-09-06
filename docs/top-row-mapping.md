# Creator Micro 2 top-row mapping

Verified against the installed Work Louder Input 0.18.4 source on 2026-09-06,
after physical button behavior disagreed with Micro Manager's screen mirror.

| Physical position | Input keymap coordinate | Position ID / UI label | T3 binding |
| --- | --- | --- | --- |
| Top left | `[0][0]` | 0 | `KV_OAI_AG06` |
| Top right | `[0][1]` | 1 | `KV_OAI_AG07` |

Input's `dist/assets/App-C-Qfs6oi.js`, inside its installed `app.asar`, supplies
the Creator Micro V2 visual row as `["", "00", "01", ""]` (`wVA`). Its `NT`
renderer iterates the row in order and passes each column index directly to
the key handler. The `_line_fsqq5_62` style uses `flex-direction: row`.
`convertConfigToProfiles` reads `layout.keymap[row][column]` without reversing
the top row; `toDeviceConfigDto` writes the same order back.

Micro Manager inherited an incorrect reversed `displayRows` entry `[1, 0]`.
Version 0.1.6 swapped only the labels, leaving the left screen position attached
to position 1's session and light. Version 0.1.7 uses the keymap's actual row
order for the screen and removes the label translation. The label, displayed
color, click handler, and physical press now share the same position ID.

Existing mappings, saved selection order, pins, and backups require no migration.
Position 0 remains bound to AG06, and position 1 remains bound to AG07; no device
write is needed. New configurations and demo mode select the six default keys
in left-to-right order. Other rows and Codex's AG00–AG05 range are unchanged.

`testTopRowPositionsAgreeWithBindingsLightsAndPresses` checks the independently
identified coordinates, selected-layer bindings, different left/right LED
colors, and physical press events through the emulator. The bridge harness
also checks that an AG06 press acknowledges the session displayed at top left.
