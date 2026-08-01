# Handoff — Issue 25 Step 7 Complete (OPEN command wired in sudoku.zig)

## What Changed

### `src/sudoku.zig`
1. **Replaced `.open` stub** at line ~94: Removed placeholder print ("open not yet implemented") and wired through to `self.engine.openGame(io, o_data.path)` with error handling identical to the `.save` handler pattern (catch → print "open failed: {errorName}" → return false).

2. **Added integration test** `"full seam: open loads saved game"` at line ~352: Tests the complete command dispatch path through `handleResult`:
   - Creates a save file on disk via a separate GameEngine (mutated + undone to exercise history)
   - Opens a fresh Sudoku instance, fills a cell with seven (diverges from saved state)
   - Dispatches the OPEN command via `command.parse()` → `handleResult()` seam
   - Asserts: no stub message in output · loop continues (isDone = false) · engine state restored (cell back to zero, not seven)

## Test Results

- **164/164 tests pass** (was 163/163 before)
- Coverage: **98.51%** (2051/2082 lines, up from 98.45%)
- `game_engine.zig` coverage unchanged at 97.95%

## TDD Cycle

**RED → GREEN**: Test written first (failed with "not yet implemented" present) → stub replaced with implementation → all assertions pass including behavioral (no stub message) and data-state (board restored to saved values).

## What's Left

| Step | Status | Description |
|------|--------|-------------|
| 7 | ✅ Done | Wire `.open` handler in sudoku.zig |
| 8 | ⏳ Needs work | Add `Board.equal(other: Board) bool` for test assertions |
