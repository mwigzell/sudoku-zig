# Cross-entry parity matrix

Native and web front ends call core differently, but must produce the same **semantic** outcomes. Each scenario in the fixture `src/test/fixtures/parity_scenarios.json` runs through the real entry paths on both sides and is checked against one shared set of expectations. Each runner is a test in the module it drives:

- **Native:** the `parity scenarios` test in `src/native/shell/shell.zig` drives `Sudoku` (`runStartupFlow`, then `turn()` per step) with a scripted renderer and an in-memory transport.
- **Web:** the parity block at the end of `src/wasm/shell.test.mjs` drives the real wasm through `shell.js` (`runStartupFlow`), `board.js` (`handlePlayKey`), `menu.js` (`handleEditAction`) and `file_menu.js` (the File menu listeners) against a fake host.

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

Steps are player actions: `fill`, `clear`, `fill_first_empty`, `undo`, `redo`, `hint`, `solve` (Edit menu items), `paste` (clipboard text), `open` (a saved game picked by name), `import` (a picked puzzle file's text), `save`, `copy` (File and Edit menu items), `toggle_auto_save`, `toggle_region` (View menu items), `set_theme` (View theme item).

Write context (core's `continuation` / `detached`) is checked by what follows it: under `continuation` the next autosave writes the working file without asking; under `detached` it asks before overwriting an existing file.

## Scenarios

| Scenario | Required outcomes | Native test | Web test |
|---|---|---|---|
| `restore_solved_keep` | 1 question; solved after startup; next autosave writes `startup.sud` without asking (`continuation`); cleared cell empty, not given | `parity scenarios: native shell meets every shared scenario expectation` | parity block in `shell.test.mjs` |
| `restore_solved_new_game` | 2 questions (restore choice, then replace); unsolved after startup; nothing written after declining replace (`detached`) | same | same |
| `auto_save_toggle_then_autosave` | `auto_save: true` persisted; next move writes `sudoku.sud` without asking and makes it the working file; filled cell not given | same | same |
| `restore_unsolved_moves` | No question; moves restored as non-givens, givens intact; Undo offered | same | same |
| `autosave_then_relaunch_restores_moves` | Three autosaved moves write `sudoku.sud`; the next launch restores them as non-givens, givens intact; Undo offered | relaunch: new `Sudoku` on the same transport, startup on the last written path | relaunch: new game and session, startup on the host's last written file |
| `history_branch_discards_redo` | A move after Undo discards the undone move; Redo not offered | same | same |
| `paste_valid_resets_history` | Pasted line becomes the givens; status `paste: puzzle loaded`; Undo not offered | same | same |
| `paste_invalid_keeps_board` | One error; board and Undo unchanged | same | same |
| `settings_change_does_not_autosave` | With Auto Save on, Region and Theme changes persist settings and write no game file; the status line keeps the last message | same | same |
| `hint_reports_and_autosaves` | Status shows the hint text; the hint autosaves `sudoku.sud` without asking | same | same |
| `solve_then_rejected_fill` | Status `You win!`; a fill on a given cell shows one error and leaves the board solved | same | same |
| `open_then_move_continues_file` | Open and the next move both write `game.sud` without asking; saved moves stay non-givens | same | same |
| `import_starts_unsaved_game` | Imported line becomes the givens; status `import: puzzle loaded`; autosave writes `sudoku.sud`; Undo not offered | same | same |
| `import_invalid_keeps_board` | One error; board and Undo unchanged | same | same |
| `save_names_default_then_continues` | First Save writes `sudoku.sud` without asking; the next Save continues it; status `saved to: sudoku.sud` | same (full path, compared relative to the data folder) | same |
| `copy_reports_and_writes_nothing` | Status `copy: puzzle line copied`; no file written | prints the line | same |
| `new_after_open_asks_before_replacing` | New replaces the opened board; the next autosave asks once, then overwrites `game.sud` | puzzle line carried by the command | scripted `generate` answer |
| `export_names_default_and_reports` | Export writes `puzzle.txt` and reports `exported to: puzzle.txt`; the game file is written only by autosave | same (full path, compared relative to its folder) | export writer faked; counts as a write |

## Adding a scenario

Add it to `parity_scenarios.json` and a row here. Both runners pick it up; a step kind a runner does not know fails that runner. If one entry cannot run it yet, add `"skip": { "entry": "native" | "web", "gap": "<what is missing>", "issue": <open issue number> }` — the drift check fails once that issue is closed.
