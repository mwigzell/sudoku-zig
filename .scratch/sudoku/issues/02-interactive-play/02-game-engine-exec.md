Status: closed
Type: task
Blocked by: 01-command-parser

## What to build

Modify `game_engine.zig` — add `exec(Command)` method returning `CommandResult`. Given-cell rejections that were silently swallowed via `catch {}` now surface as `.error_msg`. After mutation, `engine.render()` is called so the board reflects changes before the next render cycle.

### Verify before code
Confirm current `fill()` method silently swallows `setCell` errors via `catch {}`. Note the absence of `CommandResult` type and any `exec()` method.

### Test (write first)
- `"exec fill non-given cell → .ok"` — uses MockRenderer, fills empty cell, asserts `.ok`
- `"exec fill given cell → .error_msg"` — attempts to overwrite a given, asserts error message contains "given" or similar
- `"exec clear given cell → .error_msg"` — same guard for clear on locked cells
- `"exec quit → .ok"` — quit returns without mutating state

### Code (write after test)
- Define `pub const CommandResult = union(enum) { ok, error_msg: []const u8 };`
- Import `command.Command`
- New `exec(cmd: Command) !CommandResult` that switches on command variant:
  - `.fill` → call `Board.setCell()`, handle `error.NotGiven` return and convert to `.error_msg`
  - `.clear` → given-cell guard then `Board.clearCell()` 
  - `.quit` → returns immediately without mutating state
- After mutation: call `engine.render()` so next render reflects the change

### Verify after
`zig test src/game_engine.zig` passes. Existing tests still green. Confirm given-cell rejections are no longer silent.
