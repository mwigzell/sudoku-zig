# Session state — Issue #156 Step 1 (TDD)

## Cycle 1 (red → green) — DONE

**Goal:** toggling `warn_solvability` ON over an already-dead board immediately appends the no-solution sentence.

**Red test** (`src/core/flow/command.zig`):
- `test "toggling warn_solvability on over a dead board appends the no-solution sentence"`
- Builds a dead board via `board.fromFlat`, seeds the scratch buffer with `"existing message"` via `engine.appendEventMsg`, runs `set_config warn_solvability on`, asserts status == `"existing message There is no solution from here. Try Undo."`.

**Green implementation:**
- `src/core/flow/command.zig` `setConfig`: after `useConfig`, when field is `warn_solvability` and value is on, `return self.show(self.engine.solvabilityWarningOn())`.
- `src/core/engine/game_engine.zig`: new public method `solvabilityWarningOn()` — idempotent (returns `unchanged()` if `no_solution_msg` already in scratch), probes `.move`, appends `no_solution_msg` to scratch via `hint_command.appendNoSolutionMsg`, folds via `finishOkEvent`.

**Gate:** `zig build verify` PASSED.

## KEY MECHANISM (learned the hard way — do not repeat)

The status buffer is `event_msg` (scratch) on `GameEngine`, NOT `state.status`.

- Commands append to scratch via `appendEventMsg` / `appendNoSolutionMsg`.
- `finishOkEvent` is the ONLY thing that writes to `state.status` (reset + copy from scratch).
- Never write to `state.status` directly. Always append to `event_msg` and fold.

`set_config` does NOT go through `exec()` (which calls `beginEventMsg`), so the scratch buffer is NOT cleared for it — it already holds the prior command's message. So "append, don't clobber" = just append to scratch and fold; no seeding from `state.status` needed.

## Remaining ACs (not yet done — next cycles)

- AC 2 (move-context sentence) — covered by using `no_solution_msg`.
- AC 3 (preserve existing message, append) — covered by the red test.
- AC 4 (idempotent — no duplicate on re-toggle) — NOT yet tested; needs a second test.

## Notes

- `probeSolvability(.move)` returns `null` both when warnings disabled AND on conflict (catches `error.Conflict`). Since the toggle only runs when warnings are on, a `null` here means conflict — the `.none` case is what we append for. (No `conflict_bits` check needed in the final version; the probe's `.none` covers unsolvable, and conflict → probe returns null → no append, matching the cell-edit path's `else if`.)
- Temp test root `src/_one_test.zig` created and deleted (used to run the single test since `command.zig` tests are only discovered via a running test).
