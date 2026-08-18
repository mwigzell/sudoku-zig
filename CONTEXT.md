# CONTEXT — Sudoku in Zig (WASM)

## Project Goal

A playable Sudoku game as a WASM module compiled from Zig, running in the browser with a thin vanilla JS renderer. A terminal front-end (AsciiRenderer) proves the architecture first; both renderers share the same GameEngine domain layer behind an interface. (Note: a true TUI is an ncurses front-end — not implemented yet.)

See `.scratch/sudoku/prd.md` for full PRD and user stories.

## Coding Standards
See `.coding-standards.md` for all coding, testing, TDD methodology, and project architecture guidelines.

## Language

### Board Layer

**Board**:
The outermost domain object holding the mutable game state: grid topology, timer, and derived conflict marks. Owns a Grid.
_Avoid_: Puzzle (too overloaded), GameState (implies framework)

**Cell**:
A single position on the board holding a value (empty or digit 1–9), locked/given flag, optional notes/candidates set, and per-cell conflict flags. Total: 81 cells across the full board.
_Avoid_: Tile, space, slot

### Grid Topology

**Box**:
The canonical owner of Cell[3][3]. Each Box knows its (boxRow, boxCol) position in the 3×3 meta-grid, which determines global (row, col) for each of its cells. Boxes contain; other structures derive.
_Avoid_: Region, square, block (unless used alongside "Box" as synonym)

**Grid**:
Immutable topology engine defining how 81 cells relate to one another — which belong together as a row, column, or Box. Contains the authoritative box[3][3] arrangement and provides RowView and ColView lenses across that owned data. The Grid never mutates; Board does.
_Avoid_: Layout matrix (implies rendering concern), Table

**RowView**:
A computed lens across three Boxes sharing a horizontal band, yielding 9 cell references corresponding to a global row index 0–8. Not an owned array — it assembles references from the Boxes that own the cells.
_Avoid_: Row slice (implies copying)

**ColView**:
A computed lens across three Boxes sharing a vertical band, yielding 9 cell references corresponding to a global column index 0–8. Like RowView, not an owned array.
_Avoid_: Column slice (implies copying)

### Rendering & Interaction

**Renderer**:
Interface for presenting Board state. Concrete implementations: AsciiRenderer prints (ANSI) text to the terminal, WasmRenderer renders DOM or JSON events in the browser. The Renderer receives Event snapshots from GameEngine — it does not directly access internal Grid structures.
_Avoid_: View (conflicts with RowView/ColView), UI, TUI (TUI = an ncurses front-end, not the current AsciiRenderer)

**Event**:
Full-state snapshot of a Board emitted by the GameEngine after each command. Contains only presentation-relevant data; the Renderer consumes this, not the Board or Grid themselves.
_Avoid_: Payload (ambiguous), State dump

**Command**:
Player action sent to GameEngine (e.g., `fill_cell <row> <col> <digit>`). Carries intent, not state — GameEngine decides what to mutate and validates.
_Avoid_: Input action (framework term)

**GameEngine**:
Orchestrator that receives Commands, mutates Board state, runs Validator checks after every mutation, and emits an Event snapshot describing the resulting state. Owns the Board reference; does not import rendering details (dependency inversion). The single cross-cutting test seam is Command → GameEngine → Event.
_Avoid_: Engine alone (ambiguous — Solver Service also contains "engine" semantics), Controller (MVC framework term)

### Validation & Solving

**Validator**:
Given a Board state, reports which cells conflict with the digit in their row (9-cell RowView), column (9-cell ColView), or Box (owned 3×3). Rules enforced at command time after every mutation.
_Avoid_: Checker (implies boolean only)

**Puzzle Repository**:
Source of Sudoku puzzle data. Starts as inline hand-crafted arrays; extracts behind an interface when a second source (auto-generator) is added.
_Avoid_: Puzzle store

**Solver Service**:
Backtracking solver that completes or verifies puzzles by iterating RowView, ColView, and Box cell sets to compute valid candidates. Extracted behind an interface when both "generate" and "solve-for-me" features need it.
_Avoid_: Engine (collides with GameEngine)

## Architectural Decisions

See `docs/adr/` for numbered ADRs as cross-cutting decisions are recorded (e.g., WASM ABI shape, command schema, difficulty thresholds).
