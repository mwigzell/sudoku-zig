Status: ready-for-agent

## Parent
`.scratch/sudoku/prd.md`

## What to build
A history stack inside `GameEngine` that records every successful mutation (fill, clear) and exposes an `undo` command through the existing `exec(Command)` seam. One undo = one mutation reverted. Multiple undos walk backwards sequentially.

Renderer requires zero changes — `Event.ok { board_view, msg }` already carries the full board state after each turn, so `Sudoku.run()` re-renders unchanged on an undo event.

---

## Context
- Undo is a single-command feature: user sends `"U"` (or equivalent), GameEngine pops last action from history, restores state, returns new `Event.ok` with updated BoardView snapshot.
- History lives entirely inside `GameEngine`. No persistence across puzzle loads. When `Sudoku.init()` rebuilds the engine, history empties.

---

## Steps (vertical slice)

### Step 1: Define Command.undo variant
**File:** `src/command.zig`
- Add `.undo = struct {}` to the `Command` union enum.
- Parse `"U"` or `"u"` in command parser → returns `ParseCommandResult{ .valid = .{ .undo = .{} } }`.

### Step 2: Add MutationHistory stack to GameEngine
**File:** `src/game_engine.zig`
- New `MutationHistory` struct with a fixed-size circular buffer or array list. Each entry captures enough data to roll back one mutation:
  - `row: u4`, `col: u4`, `old_value: cell.CellValue`.
  - Stack depth of ~100 should be more than enough for a play session.

### Step 3: Push pre-mutation snapshot into history on fill/clear
**File:** `src/game_engine.zig` (`exec`)
- In `tryFill()` and `tryClear()`, **before calling `board.setCell(...))`, record the (row, col, old_value) into history before mutating.
- If mutation fails, don't push (nothing changed).

### Step 4: Wire .undo command in exec()
**File:** `src/game_engine.zig` (`exec`)
- On `.undo`: if history is empty → return `Event.error_msg("nothing to undo")`. Otherwise pop last entry, call `board.setCell(row, col, old_value)` (safe — never rejects because we're restoring the exact previous value), refresh conflicts for that cell, return `Event.ok { .board_view = self.board.asView(), .msg = null }`.

### Step 5: Integration tests through command→event seam
**File:** `src/game_engine.zig` test block (co-located)
- `test "undo fill reverts to pre-fill state"` — fill a cell with seven, then undo, assert `Event.ok.board_view` shows zero again.
- `test "undo clear restores previous value"` — same pattern but for clear command.
- `test "multiple undo walks history backwards"` — perform 3 fills, call undo twice in sequence, assert state after each pop matches expected snapshot through Event events.
- `test "undo on empty history returns .error_msg"`.

### Step 6: Update Sudoku main loop to handle undo input
**File:** `src/sudoku.zig` (`run`)
- Add `"U"` / `"u"` keystroke parsing in the input dispatch so the player can actually trigger it from TUI.

---

## Acceptance criteria

- [ ] `Command.undo = struct {}` defined and parseable as `"U"` (or `"u"`)
- [ ] History stack tracks fill/clear mutations inside GameEngine
- [ ] Single undo reverts the most recent mutation (fill, clear) through `exec(Command{ .undo }) → Event.ok { ... }`
- [ ] Multiple sequential undos walk back correctly through history
- [ ] Undo on empty history returns `.error_msg`
- [ ] Tests exercise undo through command→event seam only (no internal state poking)

## Blocked by
_(none)_
