Status: ready-for-agent

## Parent
`.scratch/sudoku/prd.md`

## What to build
A history stack inside `GameEngine` that records every successful mutation (fill, clear) and exposes both an `undo` command through the existing `exec(Command)` seam. One undo = one mutation reverted. Multiple undos walk backwards sequentially. Redo re-applies the last undone mutation by advancing a forward pointer.

History follows standard undo/redo semantics: **new moves after undo truncate the future redo path.** You cannot recover branches you abandoned.

Renderer requires zero changes — `Event.ok { board_view, msg }` already carries the full board state after each turn, so `Sudoku.run()` re-renders unchanged on an undo event.

---

## Context
- Undo/redo is a single-command feature: user sends `"U"` or `"R"` (or equivalent), GameEngine pops last action from history, restores state, returns new `Event.ok` with updated BoardView snapshot.
- History lives entirely inside `GameEngine`. No persistence across puzzle loads. When `Sudoku.init()` rebuilds the engine, history empties.

---

## Steps (vertical slice)

### Step 1: Define Command.undo and Command.redo variants
**File:** `src/command.zig`
- Add `.undo = struct {}` and `.redo = struct {}` to the `Command` union enum.
- Parse `"U"` or `"u"` → returns `ParseCommandResult{ .valid = .{ .undo = .{} } }.
- Parse `"R"` or `"r"` → returns `ParseCommandResult{ .valid = .{ .redo = .{} } `.

### Step 2: Add MutationHistory struct with forward pointer to GameEngine
**File:** `src/game_engine.zig`
- New `MutationHistory` struct with a fixed-size circular buffer or array list. Each entry captures enough data to roll back one mutation:
  - `row: u4`, `col: u4`, `old_value: cell.CellValue`.
  - Stack depth of ~100 should be more than enough for a play session.
- `pointer: usize` tracks the *current position* in history (points just past the last committed mutation). Initially at `history.items.len` after every new mutation.

### Step 3: Wire .undo command in exec() to walk pointer backwards
**File:** `src/game_engine.zig` (`exec`)
- On `.undo`: if `pointer == 0` → return `Event.error_msg("nothing to undo")`. Otherwise decrement pointer and apply *that* history entry (which restores the board cell to its state before that mutation happened — "old_value" was recorded as what it was *before* the move). Refresh conflicts for that cell, return `Event.ok { .board_view = self.board.asView(), .msg = null }`.

### Step 4: Wire .redo command in exec() to walk pointer forward
**File:** `src/game_engine.zig` (`exec`)
- On `.redo`: if `pointer + 1 < history.items.len` → return `Event.error_msg("nothing to redo")`. Otherwise increment pointer and apply *that* history entry (which re-applies the "new_value" of that past mutation). Refresh conflicts for that cell, return `Event.ok { .board_view = self.board.asView(), .msg = null }`.

### Step 5: Update tryFill() to truncate redo path on new mutations
**File:** `src/game_engine.zig` (`exec`)
- In `tryFill()` and `tryClear()`, **before calling `board.setCell(...)`**, record the (row, col, old_value) into history. But *also*: if `pointer + 1 < history.items.len`, truncate everything after pointer (they are stale future states from a different branch), then append new entry, and advance pointer to end. If mutation fails, don't push (nothing changed).

### Step 6: Integration tests through command→event seam
**File:** `src/game_engine.zig` test block (co-located)
- `test "undo fill reverts to pre-fill state"` — fill a cell with seven, then undo, assert `Event.ok.board_view` shows zero again.
- `test "undo clear restores previous value"` — same pattern but for clear command.
- `test "multiple undo walks history backwards"` — perform 3 fills, call undo twice in sequence, pointer moves backward each time), assert state after each step matches expected snapshot through Event events.
- `test "redo re-applies undone move"` — fill a cell with seven, then undo to empty it again. Then redo → `Event.ok.board_view` shows seven at that cell again.
- `test "redo on empty future returns .error_msg"` — make some fills, then try redo (nothing to redo yet). Expect `.error_msg`.
- `test "multiple undo walks forwards correctly"` — same as above but with 3 undos and redos.
- `test "undo on empty history returns .error_msg"` — fresh engine, immediately undo → `.error_msg`.
- `test "new fill after undo truncates redo path"` — make 3 fills (A,B,C), undo twice back to A. Make new fill D. The future [B,C] is truncated. Redo should *not* re-apply C or B!

### Step 7: Update Sudoku main loop to handle undo/redo input
**File:** `src/sudoku.zig` (`run`)
- Add `"U"` / `"u"` and `"R"` / `"r"` keystroke parsing in the input dispatch so the player can actually trigger them from TUI.

---

## Acceptance criteria

- [ ] `Command.undo = struct {}` defined and parseable as `"U"` (or `"u"`)
- [ ] `Command.redo = struct {}` defined and parseable as `"R"` (or `"r"`, `"redo"`)
- [ ] History stack tracks fill/clear mutations inside GameEngine with a pointer that moves back/forward
- [ ] Single undo reverts the most recent mutation (fill, clear) through `exec(Command{ .undo }) → Event.ok { ... }`
- [ ] Single redo re-applies the last undone mutation through `exec(Command{ .redo }) → Event.ok { ... }`
- [ ] Multiple sequential undos walk back correctly through history
- [ ] Multiple sequential redos walk forward correctly through future
- [ ] Undo on empty past returns `.error_msg("nothing to undo")`; redo on empty future returns `.error_msg("nothing to redo")`
- [ ] New mutation after undo truncates the redo path (futures from branches are destroyed)

## Blocked by
_(none)_
