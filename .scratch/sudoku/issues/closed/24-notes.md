Status: closed

## Parent
`.scratch/sudoku/prd.md` — User Story #11

## What to build
Pencil marks / candidate digits per cell — allow a player to annotate empty cells with one or more possible values before committing. Notes are toggled per-digit via `N5` (note 5).

---

## Context
- Classic Sudoku mechanic: mark candidates in cells you haven't solved yet. On paper, these are small handwritten digits in the corners of a cell. In TUI, we need to decide how to render them without breaking ASCII grid alignment.

### Rendering note
Current renderer uses exactly **one character per cell**. Showing multiple candidates requires either:
1. Expanding each slot (e.g., 3-char wide) and printing a digit string like `257` — changes every styler, test assertion, buffer sizes across the board.
2. Side panel / callouts (keep grid unchanged).

This is a larger refactor than undo — defer until after simpler features land.

---

## Steps

### Step 1: Extend Cell model to hold candidate set
- Add `notes: [9]bool` (indexed `true → digit 5 is a candidate; index == CellValue.five - 1`. Main value (`CellValue`) remains separate and takes precedence when set.

### Step 2: Define toggle_note command
- New Command variant `.toggle_note = struct { row: u4, col: u4, digit: cell.CellValue }`
- Parse `"N<row><col><digit>"` (e.g., `N471`) → toggles note for that digit in that cell. Given/locked cells reject mutation. Only permitted on empty cells.

### Step 3: Wire toggle_note into exec()
- Toggle note mutates board's notes array, refreshes conflicts (no change — candidates don't affect conflicts unless full). Return `Event.ok`.

### Step 4: BoardView exposes per-cell notes data
- `BoardView` gains `.getNotes(row, col) []` or `.hasNote(row, col, digit) bool so renderer can query candidate state. Both TUI and browser get the same source.

### Step 5: Renderer displays notes
- Choose a rendering approach (multi-line cells with 3x9 sub-grid per slot, or side-panel callouts). Implement in `AsciiRenderer` + `AnsiStyler`. Browser renderer to follow same pattern when it lands.

---

## Acceptance criteria

- [ ] Cell model supports a set of candidate digits independent from its main value
- [ ] `toggle_note` command adds/removes a note digit for an empty cell via GameEngine exec
- [ ] Notes cannot be placed on given/locked cells
- [ ] Event snapshot includes per-cell notes data so both renderers can draw them
- [ ] TUI renders notes visibly (decision: multi-line or side-panel)

## Blocked by
_(none — but deferred until after undo, solver, etc. are landing)_
