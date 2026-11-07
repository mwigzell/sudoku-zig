# Cross-front-end parity matrix

Native, web and Android drive core's flows through different adapters, but must issue and answer the same steps and end in the same state. Every scenario in `src/test/fixtures/parity_scenarios.json` runs through each front end's real entry points:

- **Native:** `src/test/parity/native.zig` drives `Sudoku` (`runStartupFlow`, then `turn()` per step) with a scripted renderer and `MemoryTransport`. The shell's `step_observer` records every step core issues and the answer it gets, and the run writes them as transcripts to `.zig-cache/parity/native.json`.
- **Web and Android:** `src/wasm/flows/parity.test.mjs` drives the real wasm through `startup.js`, `board.js`, `menu.js`, `file_menu.js`, `region.js`, `marks.js`, `theme.js`, `settings.js` and `autosave.js`, with the browser's step handlers (`web_steps.js`) over fake pickers and host, and Android's (`android_steps.js`) over a fake Java file bridge. It records the same transcript and compares it with native's, field for field. A scenario that native does not run is compared between web and Android.

Core's sentences are never copied into the fixture: the transcripts compare the text core issued on each front end.

`zig build glue` runs the native tests first, then the JS runner. `zig build parity` (part of `zig build verify`) fails when a scenario is missing from this table, a `not_on` entry gives no reason, or a skip names no open issue.

## Transcript

Each event is one step core issued, with the fields that matter for it, and the platform's answer:

| Step | Recorded |
|---|---|
| `prompt_message` | `type`, `title`, `text`, `buttons`, `dismiss`; the button `pressed` |
| `save`, `autosave` | `name`, `replace`; `wrote` (`ok` with the file's name, `exists`, `cancelled`, `taken`, `failed`) |
| `save_as` | `replace`; the answer (the picked name differs by platform until it is written) |
| `flush`, `export_puzzle` | `name`; the answer |
| `show_game` | status text, the file core names, `loaded` |
| `generate_game` | difficulty; `generated` (`line`, `cancelled`, `failed`) |
| `open`, `import_puzzle`, `paste_puzzle`, `restore` | `read` (`file`, `cancelled`, `failed`) |
| `forget_current_file` | `delete` |
| `show_status` | `text` |

The final state is the board's cells and givens, whether Undo and Redo are offered, the session's file, the status bar and every setting.

Two steps differ only in how the terminal takes its input, so they are left out when comparing with native: `paste_puzzle` (the terminal's Paste carries its line) and the `resolve_default_target` before `save_as` (the terminal's Save As carries its file name).

## Expectations

Each scenario's `expect` is checked on every front end that runs it, on top of the transcript comparison:

| Field | Meaning |
|---|---|
| `questions` | Prompts with more than one button. |
| `errors` | Prompts with one button. |
| `solved_after_startup` | Board solved once the startup flow finished. |
| `written` | Player files written, in order, by bare name. |
| `settings` | Stored settings fields after the steps. |
| `legend` | Whether Undo / Redo are offered after the steps. |
| `probes` | Cell value and given flag after the steps. |

## Completeness

- Native fails when a `Command` reaches no scenario; `flowless_commands` lists those that never reach core, with the reason.
- The JS runner fails when a front end receives no scenario's step of some kind core can issue, unless `steps_not_received` lists that kind for that front end with the reason; a listed kind the front end does receive fails as stale. It also fails when no scenario shows an information, warning or error prompt.
- A front end a scenario cannot reach is named in `not_on` with the reason.

## Scenarios

| Scenario | What it shows | Runs on | Not on |
|---|---|---|---|
| `restore_solved_keep` | Restoring a solved game and keeping it continues the file: the next autosave writes it without asking. | native, web, android | — |
| `restore_solved_new_game` | Restoring a solved game and starting a new one detaches the file: the next autosave asks before overwriting it. | native, web, android | — |
| `auto_save_toggle_then_autosave` | Turning Auto Save on persists the setting; the next move writes the default file without asking and makes it the current file. | native, web, android | — |
| `restore_unsolved_moves` | Restoring an unfinished game brings back the player's moves and their undo history without asking. | native, web, android | — |
| `autosave_then_relaunch_restores_moves` | Moves autosaved with Auto Save on come back on the next launch: givens stay givens, the player's moves stay moves, an undone move stays undone, and both Undo and Redo are still offered. | native, web, android | — |
| `history_branch_discards_redo` | A move after Undo discards the undone branch: Redo is no longer offered and the undone move stays gone. | native, web, android | — |
| `paste_valid_resets_history` | Pasting a valid puzzle replaces the board with new givens and clears undo history. | native, web, android | — |
| `paste_invalid_keeps_board` | Pasting an invalid line shows an error and leaves the board and undo history as they were. | native, web, android | — |
| `settings_change_does_not_autosave` | With Auto Save on, View and Settings changes persist the settings but never write the game file. | native, web, android | — |
| `pencil_mark_replaces_digit_undo_restores` | In Pencil mode a digit on the player's digit replaces it with that mark and autosaves; Undo puts the digit back without the mark. | native, web, android | — |
| `pencil_command_toggles_mark` | The pencil command toggles one mark on and off in an empty cell; each toggle autosaves. | native | web: The page marks a cell through Pencil mode and a digit; it sends no pencil command.; android: The page marks a cell through Pencil mode and a digit; it sends no pencil command. |
| `pencil_mode_digit_marks_cell` | In Pencil mode a digit toggles that mark instead of filling the cell; each mark autosaves, the mode toggle does not. | native, web, android | — |
| `mark_undo_redo` | Each mark is one Undo and Redo step: undoing two marks removes both, and Redo brings back the first; each autosaves. | native, web, android | — |
| `fill_clears_peer_marks` | A fill replaces the cell's marks and removes its digit's marks from the cell's row, column and box; marks elsewhere stay. | native, web, android | — |
| `fill_undo_restores_marks` | Undo of a fill that cleared marks puts back the cell's own marks and its row, column and box marks. | native, web, android | — |
| `solve_clears_marks` | Solve fills every empty cell and clears every mark, as player fills would. | native, web, android | — |
| `solve_undo_restores_marks` | Undo of a Solve empties the cells it filled and puts back the marks it cleared. | native, web, android | — |
| `hint_leaves_marks` | A hint on a marked cell leaves its marks as they were. | native, web, android | — |
| `select_deselect_writes_nothing` | Selecting and deselecting a cell runs through core and never writes the game file, with Auto Save on. | native, web, android | — |
| `relaunch_restores_marks_and_their_undo` | Marks autosaved with Auto Save on come back on the next launch, and undoing a fill made before it puts back the marks the fill cleared. | native, web, android | — |
| `clear_removes_marks` | Clear on an empty cell with marks removes them all and autosaves. | native, web, android | — |
| `hint_reports_and_autosaves` | A hint shows its text in the status line, leaves the hinted cell empty, and autosaves like any other command. | native, web, android | — |
| `solve_then_rejected_fill` | Solve fills the board, reports the win and autosaves; a move on a given cell is then rejected with an error and changes and writes nothing. | native, web, android | — |
| `open_then_move_continues_file` | Opening a saved game with Auto Save on continues that file: the load and the next move both write it without asking. | native, web, android | — |
| `import_starts_unsaved_game` | Importing a puzzle file with Auto Save on makes its line the givens and autosaves to the default file. | native, web, android | — |
| `import_invalid_keeps_board` | Importing a file that is not a puzzle shows one error and leaves the board and its history alone. | native, web, android | — |
| `save_names_default_then_continues` | With Auto Save off, the first Save names the default file and writes it without asking; the next Save continues that file. | native, web, android | — |
| `copy_reports_and_writes_nothing` | Copy hands the puzzle over, reports it, and writes no file even with Auto Save on. | native, web, android | — |
| `new_after_open_asks_before_replacing` | New after Open replaces the board and detaches the opened file: the next autosave asks before overwriting it. | native, web, android | — |
| `export_names_default_and_reports` | Export writes the puzzle text to the default export file and reports it; the game file is only written by autosave. | native, web, android | — |
| `startup_idle` | With nothing to restore and Auto New off, startup shows the empty board and its idle status. | native, web, android | — |
| `startup_new_game` | With Auto New on and nothing to restore, startup generates a new game at the configured difficulty. | native, web, android | — |
| `startup_generation_failed` | When startup's generation fails, core shows its error and the empty board. | web, android | native: Terminal generation always produces a puzzle and has no cancel. |
| `startup_restore_failed_delete` | A current file that is no saved game: startup shows the empty board, asks, and deletes it on Delete. | native, web, android | — |
| `startup_restore_failed_keep` | A current file that is no saved game: startup asks, and Keep forgets it without deleting. | native, web, android | — |
| `startup_restore_missing` | A current file that is gone: startup reports the failed restore and asks whether to delete it. | native, web, android | — |
| `new_generated` | New generates a game at the chosen difficulty and replaces the board. | native, web, android | — |
| `new_puzzle_line` | New with a puzzle line typed on the command loads it without generating. | native | web: Web and Android New always generates; only the terminal can type a puzzle line.; android: Web and Android New always generates; only the terminal can type a puzzle line. |
| `new_cancelled` | Cancelling generation keeps the board as it was. | web, android | native: Terminal generation always produces a puzzle and has no cancel. |
| `new_failed` | A failed generation shows core's error and keeps the board. | web, android | native: Terminal generation always produces a puzzle and has no cancel. |
| `open_cancelled` | Backing out of Open's picker changes nothing. | web, android | native: The terminal types the file with the command; there is no picker to cancel. |
| `open_read_failed` | A saved game that cannot be read shows core's error and keeps the board. | native, web, android | — |
| `open_bad_content` | A file that is no saved game shows core's error and keeps the board. | native, web, android | — |
| `import_cancelled` | Backing out of Import's picker changes nothing. | web, android | native: The terminal types the file with the command; there is no picker to cancel. |
| `import_read_failed` | A puzzle file that cannot be read shows core's error and keeps the board. | native, web, android | — |
| `paste_read_failed` | A clipboard that cannot be read shows core's error and keeps the board. | web, android | native: The terminal has no clipboard: Paste takes its line with the command and Copy prints the puzzle. |
| `save_bound_file_continues` | Save after Open writes the opened file without asking. | native, web, android | — |
| `save_after_new_on_opened_file_asks` | After Open then New, Save names the opened file but asks before replacing it; Cancel writes nothing. | native, web, android | — |
| `save_default_exists_asks` | An unbound Save names the default file; when it is already there core asks first, and OK replaces it. | native | web: An unbound Save or a Save As opens a picker, which asks its own replace question; core's question is the terminal's.; android: An unbound Save or a Save As opens a picker, which asks its own replace question; core's question is the terminal's. |
| `save_default_exists_cancel` | An unbound Save onto an existing default file: Cancel writes nothing. | native | web: An unbound Save or a Save As opens a picker, which asks its own replace question; core's question is the terminal's.; android: An unbound Save or a Save As opens a picker, which asks its own replace question; core's question is the terminal's. |
| `save_refused_while_auto_save` | With Auto Save on, Save is refused with core's message and writes nothing. | native | web: The File menu greys Save out while Auto Save is on; only the terminal can type it.; android: The File menu greys Save out while Auto Save is on; only the terminal can type it. |
| `save_write_failed` | A Save whose write fails shows core's error. | native, web, android | — |
| `save_as_picked` | Save As writes the file the player names and makes it the current file. | native, web, android | — |
| `save_as_cancelled` | Backing out of Save As's picker writes nothing. | web, android | native: The terminal types the file with the command; there is no picker to cancel. |
| `save_as_exists_asks` | Save As onto a typed path that is already there: core asks first. | native | web: An unbound Save or a Save As opens a picker, which asks its own replace question; core's question is the terminal's.; android: An unbound Save or a Save As opens a picker, which asks its own replace question; core's question is the terminal's. |
| `save_as_failed` | A Save As whose write fails shows core's error. | native, web, android | — |
| `autosave_default_exists_asks` | Turning Auto Save on for a new game whose default file is already there: the next move asks before replacing it. | native, web, android | — |
| `autosave_default_exists_cancel` | Declining to replace the existing default file: the move stays and nothing is written. | native, web, android | — |
| `autosave_failed` | An autosave whose write fails shows core's error; the move stays. | native, web, android | — |
| `save_taken_reclaim` | Android: the restored game's file belongs to an earlier install; Save asks, and choosing the file lets this install write it again. | android | native: Only Android's file bridge reports a file this install may not write (taken).; web: Only Android's file bridge reports a file this install may not write (taken). |
| `save_taken_save_as` | Android: the restored game's file belongs to an earlier install; choosing a new name saves the game there. | android | native: Only Android's file bridge reports a file this install may not write (taken).; web: Only Android's file bridge reports a file this install may not write (taken). |
| `autosave_taken_reclaim` | Android: the default file belongs to an earlier install; core asks, and picking it lets this install write it again. | android | native: Only Android's file bridge reports a file this install may not write (taken).; web: Only Android's file bridge reports a file this install may not write (taken). |
| `autosave_taken_save_as` | Android: the default file belongs to an earlier install; choosing a new name saves the game there. | android | native: Only Android's file bridge reports a file this install may not write (taken).; web: Only Android's file bridge reports a file this install may not write (taken). |
| `flush_on_close` | With Auto Save on, closing the app writes the current file once more. | web, android | native: The terminal writes the game after every command; there is no closing write. |
| `export_cancelled` | Backing out of Export's picker writes nothing. | web, android | native: The terminal types the file with the command; there is no picker to cancel. |
| `export_failed` | An Export whose write fails shows core's error. | native, web, android | — |
| `copy_failed` | A clipboard that cannot be written shows core's error. | web, android | native: The terminal has no clipboard: Paste takes its line with the command and Copy prints the puzzle. |
| `undo_redo_and_targeted_hint` | Undo then Redo brings a move back; a hint on a chosen cell reports that cell. | native, web, android | — |
| `settings_dialog_changes` | Each Settings change runs through core and stores the settings. | native, web, android | — |
| `settings_persist_failed` | Settings that cannot be stored show core's error. | native, web, android | — |

## Adding a scenario

Add it to `parity_scenarios.json` and a row here. A step a runner does not know fails that runner. If a front end cannot reach the branch at all, name it in `not_on` with the reason. If it should but cannot yet, add `"skip": { "entry": "native" | "web" | "android", "gap": "<what is missing>", "issue": <open issue number> }`; the drift check fails once that issue is closed.
