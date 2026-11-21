# E2E test map

The migration of terminal e2e tests from `src/native/shell/shell.zig` into the slow suite
`src/test/slow/core_e2e.zig` (run by `zig build verify-slow`). Each row maps a current test to its
target Gherkin mnemonic and the step that performs the move.

- **Step 1** — copy the raw-input use-case tests (already driven through `Host.createForTest`).
- **Step 2** — convert the facade tests (`DeterministicFacade`) to raw input.
- **Step 3** — new e2e tests for commands with no coverage (no current test; mnemonic only).

Renderer smoke tests are **not** use cases and stay in the fast `verify` cycle (out of scope here).

## Step 1 — copy raw-input use-case tests (17)

| Current test (in `shell.zig`) | Target mnemonic |
| --- | --- |
| `integrated e2e - full seam: fill command via prefix dispatch` | `given_empty_cell_when_filled_then_digit_lands` |
| `integrated e2e - auto pencil: P toggles candidates on and off` | `given_auto_pencil_on_when_pencil_toggled_then_candidates_draw_and_back` |
| `integrated e2e - run: open then save reuses opened path without filename prompt` | `given_open_file_when_saved_then_same_path_reused` |
| `integrated e2e - run: save_as writes file and re-renders` | `given_save_as_when_written_then_file_and_board_agree` |
| `integrated e2e - run: save_as failure does not persist current_file pointer` | `given_save_as_failure_when_attempted_then_current_file_kept` |
| `integrated e2e - run: new command resets board and history` | `given_a_game_when_new_then_board_and_history_reset` |
| `integrated e2e - run: import via menu loads puzzle and clears history` | `given_import_when_valid_then_board_loads_and_history_clears` |
| `integrated e2e - run: import failure leaves board and history intact` | `given_import_when_invalid_then_board_and_history_intact` |
| `integrated e2e - run: export via menu writes one-line file` | `given_export_when_run_then_one_line_file_written` |
| `integrated e2e - run: copy via menu prints one-line puzzle; history untouched` | `given_copy_when_run_then_puzzle_printed_history_untouched` |
| `integrated e2e - run: export failure leaves board and history intact` | `given_export_failure_when_attempted_then_board_intact` |
| `integrated e2e - .ok.msg status is non-blocking; next line is a command` | `given_open_when_ok_status_then_non_blocking_next_line_is_command` |
| `integrated e2e - .error_msg ack preserved: Enter is an ack, not a command` | `given_bare_fill_when_error_status_then_enter_is_ack_not_command` |
| `integrated e2e - fill does not shade region until show_region enabled` | `given_show_region_off_when_filled_then_no_shading` |
| `integrated e2e: menu Settings persists difficulty to config.json` | `given_settings_when_difficulty_changed_then_config_persists` |
| `integrated e2e: menu Settings persists warn_solvability to config.json` | `given_settings_when_warning_changed_then_config_persists` |
| `integrated e2e: menu Settings persists auto startup/save flags to config.json` | `given_settings_when_auto_flags_changed_then_config_persists` |

## Step 2 — convert facade tests to raw input (4)

| Current test (in `shell.zig`, uses `DeterministicFacade`) | Target mnemonic |
| --- | --- |
| `deterministic major path: save_as then open restores saved snapshot` | `given_a_save_when_reopened_then_snapshot_restores` |
| `deterministic major path: import then export round-trips through command loop` | `given_import_when_exported_then_round_trip_matches` |
| `deterministic major path: explicit new puzzle replaces board and clears history` | `given_a_game_when_new_with_puzzle_then_board_replaced_history_cleared` |
| `deterministic major path: new without a puzzle generates one at the chosen difficulty` | `given_a_game_when_new_without_puzzle_then_generates_at_difficulty` |

## Step 3 — new e2e tests for commands with no coverage (6)

| Current test | Target mnemonic |
| --- | --- |
| *(none — `redo` has no e2e)* | `given_a_fill_when_undone_and_redone_then_digit_returns` |
| *(none — `hint` has no e2e)* | `given_an_empty_cell_when_hinted_then_a_placement_is_reported` |
| *(none — `solve_for_me` has no e2e)* | `given_a_game_when_solved_then_board_is_complete` |
| *(none — `bookmark` has no e2e)* | `given_a_move_when_bookmarked_then_bookmark_is_set` |
| *(none — `rewind` has no e2e)* | `given_a_bookmark_when_rewound_then_board_returns` |
| *(none — `pencil A1 5` mark-toggle has no e2e)* | `given_a_cell_when_pencil_mark_toggled_then_mark_flips` |
