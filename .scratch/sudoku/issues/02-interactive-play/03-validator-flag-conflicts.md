Status: closed
Type: task
Blocked by: (none — independent of exec path wiring)

## What to build

New file `src/validator.zig` — walk Board's RowView/ColView/BoxView scopes and flag cells whose digit is duplicated within any scope. Conflict state lives on Board as a new field (e.g. `conflict_bits: u128`) so it is captured in BoardView and flows through to Styler.

### Verify before code
Confirm no validator module exists; confirm Board has no conflict-tracking field yet.

### Test (write first)
- [x] `"validate empty board → all clear"` — 81 cells, zero conflicts
- [x] `"validate row conflict → both duplicate cells flagged"` — two cells in same row share digit, both marked
- [x] `"validate column conflict → duplicates flagged"`
- [x] `"validate box conflict → duplicates within 3×3 flagged"`
- [x] `"validate no false positives — unique digits across all scopes"`
### Code (write after test)
New `src/validator.zig`:
- Walk each RowView (9), ColView (9), BoxView (9)
- For each scope, scan 9 cells, detect any digit appearing more than once among non-empty cells
- Mark all conflicting positions (the cell and its peer(s))
- `pub fn flagConflicts(board: *Board) void` — modifies Board; always succeeds

Also modify `src/board.zig`:
- Add `conflict_bits: u128` field to Board struct for per-cell conflict tracking

### Verify after
`zig test src/validator.zig` passes. Coverage on validator logic > 90%.

### root.zig update
Add `const validator = @import("validator.zig");` and reference inside root `test {}` tuple.
