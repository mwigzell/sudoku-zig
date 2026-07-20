Status: needs-triage
Type: task
Blocked by: 02-game-engine-exec, 03-validator-flag-conflicts

## What to build

Modify `game_engine.zig` — wire `validator.flagConflicts()` into the exec path. After every Board mutation (setCell/clearCell), call the validator so conflict state is fresh before render copies BoardView and Styler accesses it.

### Verify before code
After T3 lands, confirm `flagConflicts()` exists and Board has conflict bits but they are not yet called from exec.

### Test (write first)
- `"exec fill creates conflict → cell marked after render"` — fill a digit conflicting with existing row; MockRenderer snapshot should show conflict bit set on both cells
- `"exec clear resolves conflict → previously-conflicting peer now clean"` — remove one duplicate, the other is no longer flagged
- `"exec fill no conflict → no bits set"` — fill cell with unique digit

### Code (write after test)
Modify `game_engine.zig`:
- Import validator module
- In `exec()`: after the Board mutation (`setCell`/`clearCell`), call `validator.flagConflicts(&self.board)`
- This ensures conflict state is fresh before `render()` copies BoardView

### Verify after
`zig test src/game_engine.zig` passes. Integration test chain: exec → mutation → validator → render → MockRenderer captures conflict marks.
