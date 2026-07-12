Status: ready-for-agent

## Working mode
HITL (Human In The Loop). One TDD cycle per session. Agent enumerates its plan, does one iteration, pauses for explicit direction before proceeding. See `.coding-standards.md` → "TDD methodology (HITL)".

## Parent

`.scratch/sudoku/prd.md`

## What to build

Player interactivity: accept Commands to fill/clear cells, validate board state after each move via the Validator, and re-render through the Renderer interface. Introduce **GameEngine** as the Command→Event orchestrator — receives a Command, mutates Board state through its Grid topology, runs constraint validation across RowView/ColView/Box axes, and emits an Event snapshot. Renderer consumes Events and draws the updated grid.

### GameEngine
- Commands (stdin): e.g., `fill 3 5 7`, `clear 3 5`. Input format via line-based reader for now.
- On mutation, queries Grid topology: row(n).cells + col(n).cells + box at that coordinate → detect conflicts.
- Given/prefilled cells are immutable (filling a given cell is rejected).
- Emits full-state Event after each command; Renderer calls render(Event) to re-draw.

### Validator
- Iterates row(n), col(n), and box-owned cells for uniqueness checks.
- Marks conflicting cells on the Board; Renderer visualizes conflicts distinctly (red/unicode highlight — implementation choice).

### Game loop in main.zig
1. Load embedded puzzle → construct Board with Grid topology
2. Renderer renders initial Board to stdout
3. stdin line reader loops: parse Command → GameEngine.execute(Command, &board) → Event emitted → Renderer.renderEvent(Event)

### Test seams
- No TUI assertions. Tests feed Commands into GameEngine and assert emitted Event snapshots match expected state.
- Validator tested in isolation: construct Board with known conflicts → assert which cells are flagged.
- RowView/ColView constraint queries verified by unit tests (correct 9-cell membership).

## Acceptance criteria

- [ ] Player can fill an empty cell with a digit 1–9 via stdin input
- [ ] Player can clear a filled cell back to empty
- [ ] Given/prefilled cells cannot be altered
- [ ] Validator detects conflicts (duplicate digits across row, column, or Box) using Grid topology views
- [ ] Conflicting cells are visually highlighted in the rendered grid
- [ ] GameEngine runs validation after each mutation and emits a full-state Event
- [ ] Integration tests exercise Command→Event seam for fill, clear, and conflict detection

## Blocked by

01 — requires Box/Grid/Board domain model with row-view and col-view lenses
09 — requires renderer interface/contract

## Comments
