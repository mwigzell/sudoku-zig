# Core e2e cases

The authoritative use-case suite for core. Each case is a player story, driven through the
terminal — the vanilla lingua franca of core — as a precise command sequence with an asserted
outcome. The tests live in `src/test/slow/core_e2e.zig` and run in `zig build verify-slow` (see
`docs/agents/verify-slow.md` for the gate's timing and operating rules).

A case is **not** one test per command. It is one test per story: the commands a player actually
types to do something, and the outcome that proves the story held. Unit tests prove the parts;
these prove the parts are wired together and behave as the player experiences them.

## The mnemonic list

The mnemonic is the primary index. It is Gherkin form — `given_<state>_when_<action>_then_<outcome>` —
and names the story, not the command. A fixture, an issue or a review cites the mnemonic; the
explanation below says why each command is in the case.

| Mnemonic | Story |
| --- | --- |
| [`given_empty_cell_when_filled_then_digit_lands`](#given_empty_cell_when_filled_then_digit_lands) | A fill lands the digit in the named cell. |
| [`given_auto_pencil_on_when_pencil_toggled_then_candidates_draw_and_back`](#given_auto_pencil_on_when_pencil_toggled_then_candidates_draw_and_back) | Auto Pencil on: P shows the board's candidates, P again shows digits only. |
| [`given_a_save_when_reopened_then_snapshot_restores`](#given_a_save_when_reopened_then_snapshot_restores) | Save As then Open restores the saved board. |
| [`given_open_file_when_saved_then_same_path_reused`](#given_open_file_when_saved_then_same_path_reused) | Open a file, then Save writes back to that path without asking. |
| [`given_save_as_when_written_then_file_and_board_agree`](#given_save_as_when_written_then_file_and_board_agree) | Save As writes the file and re-renders. |
| [`given_save_as_failure_when_attempted_then_current_file_kept`](#given_save_as_failure_when_attempted_then_current_file_kept) | A failed Save As does not lose the current-file pointer. |
| [`given_a_game_when_new_then_board_and_history_reset`](#given_a_game_when_new_then_board_and_history_reset) | New replaces the board and clears history. |
| [`given_import_when_valid_then_board_loads_and_history_clears`](#given_import_when_valid_then_board_loads_and_history_clears) | Importing a valid puzzle loads it and clears history. |
| [`given_import_when_invalid_then_board_and_history_intact`](#given_import_when_invalid_then_board_and_history_intact) | A failed import leaves the board and history as they were. |
| [`given_export_when_run_then_one_line_file_written`](#given_export_when_run_then_one_line_file_written) | Export writes the one-line puzzle. |
| [`given_export_failure_when_attempted_then_board_intact`](#given_export_failure_when_attempted_then_board_intact) | A failed export leaves the board intact. |
| [`given_copy_when_run_then_puzzle_printed_history_untouched`](#given_copy_when_run_then_puzzle_printed_history_untouched) | Copy prints the one-line puzzle and leaves history alone. |
| [`given_show_region_off_when_filled_then_no_shading`](#given_show_region_off_when_filled_then_no_shading) | A fill shades no region until Show Region is on. |
| [`given_settings_when_difficulty_changed_then_config_persists`](#given_settings_when_difficulty_changed_then_config_persists) | Settings difficulty change persists to config.json. |
| [`given_settings_when_warning_changed_then_config_persists`](#given_settings_when_warning_changed_then_config_persists) | Settings solvability-warning change persists. |
| [`given_settings_when_auto_flags_changed_then_config_persists`](#given_settings_when_auto_flags_changed_then_config_persists) | Settings auto startup/save flags persist. |
| [`given_import_when_exported_then_round_trip_matches`](#given_import_when_exported_then_round_trip_matches) | Import then Export writes back the same one-line puzzle. |
| [`given_a_game_when_new_with_puzzle_then_board_replaced_history_cleared`](#given_a_game_when_new_with_puzzle_then_board_replaced_history_cleared) | New with an explicit puzzle replaces the board and clears history. |
| [`given_a_game_when_new_without_puzzle_then_generates_at_difficulty`](#given_a_game_when_new_without_puzzle_then_generates_at_difficulty) | New without a puzzle generates one at the chosen difficulty. |
| [`given_open_when_ok_status_then_non_blocking_next_line_is_command`](#given_open_when_ok_status_then_non_blocking_next_line_is_command) | An ok status is non-blocking; the next line is read as a command. |
| [`given_bare_fill_when_error_status_then_enter_is_ack_not_command`](#given_bare_fill_when_error_status_then_enter_is_ack_not_command) | An error status acks; Enter is consumed as the ack, not a command. |

## The cases, with their commands

### `given_empty_cell_when_filled_then_digit_lands`

```
fill A3 4
quit
```

`fill` is the whole story: name the cell, name the digit, and the engine lands it. `quit` ends the
loop so the test can assert the board after the turn. The assertion is the digit at A3, read from
the engine — the outcome, not the command echo.

### `given_auto_pencil_on_when_pencil_toggled_then_candidates_draw_and_back`

```
menu
14
8
P
P
quit
```

`menu` opens the terminal's own menu; `14` is Settings; `8` is the Auto Pencil row, which turns the
setting on. `P` is the Pencil button — the first `P` turns the switch on so every empty cell draws
its candidates, the second turns it off so only digits draw. `quit` ends the loop. The assertions
are the engine's `is_pencil` flag and the frame's `drawnMarks()` after each `P`: candidates drawn,
then none. This is the case that would have caught the missing `P` wiring.

### `given_a_save_when_reopened_then_snapshot_restores`

```
save_as <path>
open <path>
quit
```

`save_as` writes the current board to a named file; `open` reads it back. The assertion is the
board after `open` equals the board before `save_as`. Two commands, one story: a save survives a
reopen.

### `given_open_file_when_saved_then_same_path_reused`

```
menu
2
<path>
menu
1
quit
```

`menu` `2` opens a file at the typed path; `menu` `1` saves. The story is that Save, after an Open,
writes back to the opened path without asking for a filename again. The assertion is no filename
prompt on the second save.

### `given_save_as_when_written_then_file_and_board_agree`

```
menu
6
<name>
quit
```

`menu` `6` is Save As; the typed name is the target. The assertion is the file exists and the board
re-rendered.

### `given_save_as_failure_when_attempted_then_current_file_kept`

```
menu
6
quit
```

`menu` `6` is Save As, pointed at a path that cannot be written. The story is the failure does not
drop the current-file pointer. The assertion is the pointer still names the prior file.

### `given_a_game_when_new_then_board_and_history_reset`

```
fill A3 7
menu
5
2
quit
```

`fill` makes a move so there is history to clear; `menu` `5` is New; `2` picks the difficulty in
the dialog. The story is New replaces the board and clears history. The assertion is the board no
longer holds the fill and the history is empty.

### `given_import_when_valid_then_board_loads_and_history_clears`

```
fill A3 7
menu
3
quit
```

`fill` makes history; `menu` `3` is Import, which reads a one-line puzzle. The story is a valid
import loads the puzzle and clears history. The assertion is the imported board and empty history.

### `given_import_when_invalid_then_board_and_history_intact`

```
fill A3 7
menu
3
quit
```

`menu` `3` is Import, pointed at a file that is no puzzle. The story is the failure leaves the
board and history as they were. The assertion is the board still holds the fill and the history is
unchanged.

### `given_export_when_run_then_one_line_file_written`

```
fill A3 7
menu
4
quit
```

`menu` `4` is Export. The story is the current grid is written as a one-line puzzle. The assertion
is the written file matches the board's one-line form.

### `given_export_failure_when_attempted_then_board_intact`

```
fill A3 7
menu
4
quit
```

`menu` `4` is Export, pointed at a path that cannot be written. The story is the failure leaves the
board intact. The assertion is the board still holds the fill.

### `given_copy_when_run_then_puzzle_printed_history_untouched`

```
fill A3 7
menu
12
quit
```

`menu` `12` is Copy. The story is the one-line puzzle is printed and history is untouched. The
assertion is the printed line and the unchanged history.

### `given_show_region_off_when_filled_then_no_shading`

```
fill <cell>
menu
7
quit
```

`fill` selects a cell; `menu` `7` toggles Show Region. The story is a fill shades no region until
Show Region is on. The assertion is the frame's region is null before the toggle and set after.

### `given_settings_when_difficulty_changed_then_config_persists`

```
menu
14
<difficulty row>
quit
```

`menu` `14` is Settings; the difficulty row changes the default. The story is the change persists
to config.json. The assertion is the stored difficulty.

### `given_settings_when_warning_changed_then_config_persists`

```
menu
14
<warning row>
quit
```

`menu` `14` is Settings; the solvability-warning row toggles. The assertion is the stored flag.

### `given_settings_when_auto_flags_changed_then_config_persists`

```
menu
14
<auto row>
quit
```

`menu` `14` is Settings; the auto startup/save rows toggle. The assertion is the stored flags.

### `given_import_when_exported_then_round_trip_matches`

```
import <in>
export <out>
quit
```

`import` reads a one-line puzzle from a file; `export` writes the current grid back out. The story is
the round-trip preserves the puzzle exactly. The assertion is the exported file equals the imported
line.

### `given_a_game_when_new_with_puzzle_then_board_replaced_history_cleared`

```
fill A3 7
new <puzzle>
quit
```

`fill` makes a move so there is history to clear; `new` with an explicit puzzle replaces the board.
The story is the explicit puzzle becomes the board and history is emptied. The assertion is the
board equals the given puzzle and history is empty.

### `given_a_game_when_new_without_puzzle_then_generates_at_difficulty`

```
fill A3 7
new <difficulty>
quit
```

`fill` makes history; `new` with only a difficulty (no puzzle) generates one. The story is the
generated puzzle lands at the chosen difficulty and history clears. The assertion is the difficulty
is set, history is empty, and the new-game status is spoken.

### `given_open_when_ok_status_then_non_blocking_next_line_is_command`

```
menu
2
<path>
fill <cell> 7
quit
```

`menu` `2` opens a file, which speaks an ok status; `fill` is the next line. The story is the ok
status is non-blocking — no ack prompt — and the line after it is read as the next command. The
assertion is the status is framed (not an ack), and the fill lands.

### `given_bare_fill_when_error_status_then_enter_is_ack_not_command`

```
fill

quit
```

A bare `fill` speaks an error status; the empty line is the user's ack Enter; `quit` ends the loop.
The story is the error status acks — Enter is consumed by the ack and does not leak back to the
parser as a command. The assertion is the ack is consumed and the loop ends cleanly.

## Not use cases

Renderer smoke tests — the ANSI facade builds and quits, the ASCII renderer draws an unstyled
grid, the prodBranch writes into the session buffer — are not use cases. They prove the renderer
builds and renders, not that a player story holds. They stay in the fast core suite and are not
listed here.
