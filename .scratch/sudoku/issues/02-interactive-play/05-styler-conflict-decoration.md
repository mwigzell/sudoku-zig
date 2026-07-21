Status: needs-triage
Type: task
Blocked by: 04-exec-wires-validator

## What to build

Modify `styler.zig` — AnsiStyler decorations for conflicting cells. After wiring from T4, Board exposes conflict info via `isConflicting(idx)` but Styler only highlights givens with DIM_ON codes. Add reverse-video decoration for player-set cells in conflict; given cells take visual precedence (they can't be changed, so the dim wins even if flagged).

### Verify before code
After T4, confirm Board has `isConflicting(idx: usize)` but Styler only highlights givens.

### Test (write first)
- `"AnsiStyler: conflicting non-given cell gets distinct ANSI wrapping"` — format a row where one player-set cell is flagged; output should contain the conflict marker sequence, not just DIM_ON
- `"AnsiStyler: given cell takes precedence over conflict styling"`

### Code (write after test)
Modify `styler.zig`:
- Add ANSI escape constant for conflict decoration: `pub const CONFLICT_ON = "\x1b[7m"; // reverse-video`
- Update private `style_cell()` to accept a third parameter for conflict state
- In AnsiStyler, read conflict bits via BoardView and pass into `style_cell()`
- Prioritise given-style when cell is both given and flagged — visual hierarchy: given → dim, player conflict → highlight

### Verify after
`zig test src/styler.zig` passes. `zig build run` shows initial board identical to pre-issue output (no new conflicts on a valid starting puzzle).
