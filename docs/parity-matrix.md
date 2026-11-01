# Cross-entry parity matrix

Native and web front ends call core differently, but must produce the same **semantic** outcomes. Each scenario in `src/test/parity/scenarios.json` runs through the real entry paths on both sides and is checked against one shared set of expectations:

- **Native:** `src/native/shell/parity_test.zig` drives `Sudoku` (`runStartupFlow`, then `turn()` per step) with a scripted renderer and an in-memory transport.
- **Web:** `src/wasm/parity.test.mjs` drives the real wasm through `shell.js` (`runStartupFlow`), `board.js` (`handlePlayKey`) and `file_menu.js` (the File menu listeners) against a fake host.

`zig build parity` (part of `zig build verify`) fails when a scenario is not run by both runners, is missing from this table, or skips an entry without naming the gap and an open issue.

## Outcome vocabulary

| Field | Meaning |
|---|---|
| `questions` | Questions the player was asked (restore choices, replace confirmations). |
| `solved_after_startup` | Board solved once the startup flow finished. |
| `written` | Game files written, in order, by bare name. Settings writes are not counted. |
| `status` | Status line after the last step; `null` means empty. |
| `errors` | Error dialogs shown (default 0). |
| `settings` | Persisted `settings.json` fields after the steps. |
| `legend` | Whether Undo / Redo are offered after the steps. |
| `probes` | Cell value and given flag after the steps. |

Steps are player actions: `fill`, `clear`, `fill_first_empty`, `undo`, `redo`, `paste` (clipboard text), `toggle_auto_save`, `toggle_region` (View menu items), `set_theme` (View theme item).

Write context (core's `continuation` / `detached`) is checked by what follows it: under `continuation` the next autosave writes the working file without asking; under `detached` it asks before overwriting an existing file.

## Scenarios

| Scenario | Required outcomes | Native test | Web test |
|---|---|---|---|
| `restore_solved_keep` | 1 question; solved after startup; next autosave writes `startup.sud` without asking (`continuation`); cleared cell empty, not given | `parity scenarios: native shell meets every shared scenario expectation` | `parity.test.mjs` |
| `restore_solved_new_game` | 2 questions (restore choice, then replace); unsolved after startup; nothing written after declining replace (`detached`) | same | same |
| `auto_save_toggle_then_autosave` | `auto_save: true` persisted; next move writes `sudoku.sud` without asking and makes it the working file; filled cell not given | same | same |
| `restore_unsolved_moves` | No question; moves restored as non-givens, givens intact; Undo offered | same | same |
| `history_branch_discards_redo` | A move after Undo discards the undone move; Redo not offered | same | same |
| `paste_valid_resets_history` | Pasted line becomes the givens; status `paste: puzzle loaded`; Undo not offered | same | same |
| `paste_invalid_keeps_board` | One error; board and Undo unchanged | same | same |
| `settings_change_does_not_autosave` | With Auto Save on, Region and Theme changes persist settings and write no game file; the status line keeps the last message | same | same |

## Adding a scenario

Add it to `scenarios.json` and a row here. Both runners pick it up; a step kind a runner does not know fails that runner. If one entry cannot run it yet, add `"skip": { "entry": "native" | "web", "gap": "<what is missing>", "issue": <open issue number> }` — the drift check fails once that issue is closed.
