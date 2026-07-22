# Steps 5 & 6 Plan for Issue #20

## Current State
✅ Steps 1-4: complete (Event union, naming, GameEngine non-generic)
⚠️ Step 5 partial: many `exec()` tests still poke internals via `engine.board.isConflicting(index)`
⏳ Step 6: MockRenderer removed from game_engine.zig; needs cleanup verification

## Remaining Work

### A. Fix test at line 75-81: "GameEngine fill updates cell value"
Current: calls legacy `engine.fill()`, asserts on `engine.board.getCellValue()`
Fix: use `exec(Command)` and assert on `event.ok.board_view.get(0, 3)`

### B. Conflict tests (lines 163-237) still poke internal state
These test blocks call exec() but assert via `engine.board.isConflicting(idx)` — they should inspect BoardView from the returned Event instead, OR move to Board tests since conflict bits are a Board-level concern, not GameEngine responsibility.

Decision: keep in game_engine.zig as integration-level checks BUT update assertions to read through `event.ok.board_view` rather than engine internals.

### C. Verify Step 6
- Check mock_renderer usage across codebase
- Ensure Sudoku.init() doesn't pass renderer to engine anymore (already confirmed)
- Run full suite + coverage

## Execution Order
1. Convert line 75 test to exec-based
2. Update conflict tests to assert via BoardView
3. Verify MockRenderer status everywhere
4. Full test + coverage run
5. Commit & update issue file properly
