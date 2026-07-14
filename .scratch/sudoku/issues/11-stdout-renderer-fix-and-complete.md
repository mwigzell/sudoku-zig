Status: ready-for-agent

## Working mode
HITL (Human In The Loop). One TDD cycle per session.

## Parent

`.scratch/sudoku/prd.md`

## What to build

Fix and complete `StdoutRenderer` so it produces visible output of the full 9×9 Sudoku board when run from `main.zig`. Currently it prints only a header border line and takes an externally-injected `Io.Writer` — both wrong.

### Current state (broken)
- `init(buf: []u8)` requires a caller-supplied buffer via `Io.Writer.fixed()` — violates the spirit of a *Std* renderer that should own its output destination
- Only writes `+-------+--------\n` border line; cells are not rendered at all
- Caller (`main.zig`) must manually manage stdout plumbing and dump the buffer contents after render completes
- Produces garbage output beyond the first line because uninitialised buffer bytes leak out

### What to fix

1. **Own its stdout.** `init()` should take no arguments — internally call `std.Io.File.stdout().writer(init.io, &.{})` (or whatever 0.17 Io path works) and store it in the struct. This simplifies main.zig back down to:
   ```zig
   var r = StdoutRenderer.init();
   // ... game engine init ...
   try engine.render();    // writes directly to terminal
   ```

2. **Render the full board.** Replace the placeholder print with loop that fills the snapshot from `RenderSnapshot.cells[row][col]`:
   - Row labels (1-9), column labels (A-I)
   - Box boundary characters (`+`, `-`, `|`), cell values, and empty cells
   - Locked cells rendered distinctly (e.g. `[X]`) vs user-filled (` X `) or empty (`   `)
   - Respects `RenderCell.conflicting: bool` for future conflict highlighting wire

### Acceptance criteria

- [ ] `StdoutRenderer.init()` takes no arguments and wires its own stdio
- [ ] `main.zig` returns to simple form with no manual buffer or stdout plumbing
- [ ] Running `zig build run` prints a complete 9×9 ASCII Sudoku board to terminal
- [ ] All 18+ existing tests still pass at comparable coverage
- [ ] Locked cells visually distinct from empty/user-filled cells in output
- [ ] Conflict flag field exercised in rendering (can be stub logic; data shape proves seam works)

## Blocked by

(none)
