Status: needs-triage
Type: task
Blocked by: 02-game-engine-exec, 03-validator-flag-conflicts

## What to build

Modify `game_engine.zig` — wire validator into the exec path. After every Board mutation (setCell/clearCell), call the incremental validator so conflict state is fresh before render copies BoardView and Styler accesses it.

### Verify before code
After 03-validator lands, confirm `validateBoard()` (full scan) and `refreshConflictsForCell(row, col)` (incremental) exist. Neither is called from exec yet.

### Test (write first)
- `"exec fill creates conflict → cell marked after render"` — fill a digit conflicting with existing row; MockRenderer snapshot should show conflict bit set on both cells
- `"exec clear resolves conflict → previously-conflicting peer now clean"` — remove one duplicate, the other is no longer flagged
- `"exec fill no conflict → no bits set"` — fill cell with unique digit

### Code (write after test)
Modify `game_engine.zig`:
- Import validator module
- In `init()`: after parsing the puzzle board, call `validator.validateBoard(&self.board)` so initial conflicts are detected before first render
- In `exec()` (fill/clear paths): after a successful Board mutation, call `validator.refreshConflictsForCell(&self.board, row, col)` — incremental update only touching affected row+col+box scopes
- This ensures conflict state is fresh before `render()` copies BoardView

### Verify after
`zig test src/game_engine.zig` passes. Integration test chain: exec → mutation → validator → render → MockRenderer captures conflict marks.
