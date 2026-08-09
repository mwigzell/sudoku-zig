Status: closed
Type: task
Blocked by: 02-game-engine-exec, 03-validator-flag-conflicts

## What to build

Modify `game_engine.zig` — wire validator into the exec path. After every Board mutation (setCell/clearCell), call the incremental validator so conflict state is fresh before render copies BoardView and Styler accesses it.

### Verify before code
After 03-validator lands, confirm `board.validate()` (full scan) and `board.refreshConflictsForCell(row, col)` (incremental) exist as Board methods. Neither is called from exec yet.

### Test (write first)
- `"exec fill creates conflict → cell marked after render"` — fill a digit conflicting with existing row; MockRenderer snapshot should show conflict bit set on both cells
- `"exec clear resolves conflict → previously-conflicting peer now clean"` — remove one duplicate, the other is no longer flagged
- `"exec fill no conflict → no bits set"` — fill cell with unique digit

### Code (write after test)
Modify `game_engine.zig`:
- In `init()`: after parsing the puzzle board, call `self.board.validate()` so initial conflicts are detected before first render
- In `exec()` (fill/clean paths): after a successful Board mutation, call `self.board.refreshConflictsForCell(row, col)` — incremental update only touching affected row+col+box scopes
- This ensures conflict state is fresh before `render()` copies BoardView

### Verify after
`zig test src/game_engine.zig` passes. Integration test chain: exec → mutation → validator → render → MockRenderer captures conflict marks.
