# Session state — Issue #154

## Status

Step 1 complete and committed (`44f5eab`). Step 2 complete (not committed — working tree).

## Done

- `src/test/slow/core_e2e.zig` — 17 raw-input e2e tests, named `core_e2e: <mnemonic>`.
- `src/entry_verify_slow.zig` — imports `core_e2e.zig`.
- `build.zig` — `verify-slow-e2e`, `verify-slow-puzzle-gen` steps; `verify-slow-run` runs both.
- Verified: e2e 17/17, puzzle-gen 3/3, fmt clean.

### Step 2 (done, uncommitted)
- Added 4 raw-input tests to `core_e2e.zig` (now 21 total):
  - `given_a_save_when_reopened_then_snapshot_restores`
  - `given_import_when_exported_then_round_trip_matches`
  - `given_a_game_when_new_with_puzzle_then_board_replaced_history_cleared`
  - `given_a_game_when_new_without_puzzle_then_generates_at_difficulty`
- All use `config.Config.default()` with no overrides.
- save/open: turns autosave off through the real UI (`menu → 14 → 7`, Settings → Auto Save) so the intermediate `fill A3 1` does not autosave over the saved snapshot; `open` then restores the saved seven over the divergent in-memory one.
- import/export: added `defer deleteFileAbsolute(io, "/tmp/sudoku.sud")` — the import's absolute path drifts the transport data dir to `/tmp`, so the import autosave writes `/tmp/sudoku.sud`; a stale copy from a prior run triggered a "Replace file?" prompt that ate the canned responses.
- Verified: `zig test src/entry_verify_slow.zig -lc --test-filter "core_e2e"` → 21/21 pass (twice, to confirm no stale-file flakiness), fmt clean.
- Originals remain in `shell.zig` (Step 4 removes them).

## Next

Step 3 — new e2e tests for the 6 commands with no coverage (redo, hint, solve_for_me, bookmark, rewind, pencil mark-toggle).
