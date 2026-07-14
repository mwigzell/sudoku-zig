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

## StdoutRenderer Design

ASCII box grid with column labels (A–I), row labels (1–9), three-by-three box separators, and per-cell indicators:
```
  A   B   C
+-------+-------+-------+
1|     |     |     |
 _|_ _ |_ _ _ |_ _ _ |
  |     |     |     |
 _|_ _ |_ _ _ |_ _ _ |
2|     |     |     |
 _|_ _ |_ _ _ |_ _ _ |
  |     |     |     |
 _|_ _ |_ _ _ |_ _ _ |
3|     |     |     |
+-------+-------+-------+
```

Cell rendering (based on `RenderCell` struct):
- Locked/given: `[X]`
- User-filled, no conflict: ` X `
- User-filled, conflicting: `✗X ✗` (Unicode strike indicator)
- Empty: `   `

Methods:
```zig
/// Main public entry — draws full 9×9 grid from a snapshot.
pub fn render(self: *StdoutRenderer, snap: renderer.RenderSnapshot) anyerror!void {
    // delegates to helpers below
}

/// Format one cell as `[]u3` ("[7]", " 7 ", or " ✗7 ✗")
fn renderCell(cell: renderer.RenderCell) [4]u8

/// Build a single row line with horizontal box separators.
/// Called for each of the 3 sub-bands per row (top border, cells, bottom separator).
fn renderRowLine(
    self: *StdoutRenderer,
    snap: renderer.RenderSnapshot,
    row_idx: usize,
) anyerror!void
```

Render flow:
1. Print column header line (`  A   B   C`)
2. For each row (0–8):
   a. Horizontal top border (`+-------+-------+-------+`)
   b. Cells prefixed with row label (`1| ... | ... | ... |`)
   c. After every third row, replace bottom separator with final grid close
3. Flush — writes to internal `Io.Writer` over the provided buffer.

### Error handling for `try` in render()

Change `render` return type from `void` to `anyerror!void`. Io.Writer always has an error set (`WriteFailed`) — propagating it is the only correct option.

- **GameEngine.renderOnce()**: propagate via `try` and bubble out. If stdout dies, the game loop terminates — appropriate behaviour.
- **StdoutRenderer test**: use `_ = r.render(snap) catch unreachable;` — fixed buffer won't overflow under test conditions.

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

(none)

### Dependencies resolved
- ✅ Issue 09: renderer interface exists, StdoutRenderer implemented, conflict marking shape in place

## Comments

### 2026-07-13 — Dep blocked cleared
Issue 09 (Renderer interface) completed. Dependency satisfied:
- `renderer.zig`: `RenderSnapshot` + `RenderCell{ value, locked, conflicting }` contract in place
- `StdoutRenderer.init()` now takes no writer dependency; handles its own stdout
- All 18 tests passing at 99.67% coverage

Issue 02 is free to build the Validator and interactive game loop next.

### 2026-07-13 — Session resume, StdoutRenderer test fix
- Fixed `StdoutRenderer` smoke test: `[9][9]RenderCell` literal was only 1 element (81 expected). Replaced with `{.cells = undefined}` — the placeholder render body ignores cell contents anyway so all-zero or all-undefined is equivalent.
- Kept `try self.w.print(...)` bug (void return vs `!void`) per user direction. Design plan added above under "Error plan" section.
- Tests won't compile until that `try` / return-type mismatch is addressed.
