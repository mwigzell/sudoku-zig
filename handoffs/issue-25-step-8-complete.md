# Handoff — Issue 25: Step 8 Complete

## Summary
Step 8 (`Board.equal()`) is complete. Commit `2a6fd59`.

## What was done
1. **Added `Board.equal(other: Board) bool`** in `src/board.zig`
   - Compares `given_bits` first (fast path for different givens)
   - Then iterates all 81 cells comparing `Cell.value`
   - Returns `true` only when both match completely

2. **3 new unit tests** in `src/board.zig`:
   - `Board: equal returns true for identical boards` — same flat data → equal
   - `Board: equal returns false when cell values differ` — mutated non-given cell → not equal
   - `Board: equal returns false when given_bits differ` — same cells, different givens mask → not equal

3. **Refactored two duplicated round-trip tests** in `src/game_engine.zig`:
   - `saveGame then openGame: full state round-trip equals original` (line ~965): replaced 14-line cell-by-cell loop + given_bits assert with single `Board.equal()` call
   - `fromSaveFormat round-trip: board state given_bits history` (line ~1178): same replacement, removed unused `orig_view`/`load_view` variables

## Test results
- **167/167 tests pass** (up from 164 — added 3 new Board.equal tests)
- **Coverage: 98.52%** (board.zig at 100%)
- `zig build run` produces normal sudoku grid output

## Remaining Steps
| Step | Status | Notes |
|------|--------|-------|
| 1–8 | ✅ Done | All save/restore steps complete |
| No more steps | — | Issue 25 is fully implemented |

## Acceptance Criteria (from issue)
- [x] Command.save and Command.open defined and parseable
- [x] Board exposes toFlat() seam
- [x] Loading restores state perfectly, including undo/redo
- [x] Integration tests exercise save/open through command→event seam
- [x] File errors gracefully return .error_msg
