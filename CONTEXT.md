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
Orchestrator that receives Commands, mutates Board state, runs Validator checks after every mutation, and emits the resulting state for the Renderer. Owns the save/open domain logic (save/open through FileTransport). **Deploys in both targets: it carries no `std.Io` — file bytes cross through FileTransport, which the deployment supplies.** Single cross-cutting test seam: Command → GameEngine → Event.
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
### Deployments & Web Substrate (issue #4)

**RendererKind** (`-r`):
The user-facing renderer *place*: `ansi`, `ascii`, `tui`, `web`. `-r web` means the browser — WASM is the technology under it, a renderer name is not. `-r wasm` is rejected; no back-compat. Renderer selection is a **native-only** concept: the wasm deployment is web by construction and never reads it.
_Avoid_: calling the browser renderer "wasm"

**wasm_entry**: ("`wasm_entry.zig`")
Top-level entry for the wasm deployment: own `main()` + the JS imports. Not native `main.zig` (that pulls `std.process.Init`/stdin/stdout, which cannot exist in wasm32-freestanding).
_Avoid_: treating the wasm app as a second app — it is the same shared core, second entry

**WasmHost**:
The wasm substrate — the deployment half of Host. Owns the capabilities the module imports from the browser: line-in, bytes-out, **picker** (returns a file *name*), file read, file write (name+bytes). Mirrors native Host→IoSession.
_Avoid_: having WasmRenderer own these or call JS directly (destroys the substrate boundary and portability)

**WasmRenderer**:
Renderer that **borrows** WasmHost capabilities via `init` (mirror of `AsciiRendererAlloc.makeFacade(&session)`). Full facade surface; return types unchanged (`SaveFileResult{.FileName, .Cancelled}`, `ParseCommandResult`, …).
_Avoid_: "web renderer" (ambiguous with the place), DOM renderer (it's the facade over WasmHost, not a DOM library)

**Host**:
The interface/seam (facade/`Make` idiom) both deployments instantiate over their substrate — native over a terminal session (Host→IoSession→AsciiRenderer), wasm over WasmHost→WasmRenderer. Host selects a terminal facade; it never returns a WasmRenderer.
_Avoid_: Host as a concrete object (it's the seam), "session" (that's the native substrate under it)

**FileTransport**:
The fn-pointer vtable GameEngine drives file I/O through (the codebase's own facade/`Make` idiom). Two impl **arms in separate per-target files** — native = std.Io file ops, wasm = `(name, bytes)` via WasmHost imports. A dead native arm in the wasm closure drags std.Io in, which cannot be imported into wasm32-freestanding, so the arms must be separate files.
_Avoid_: "transport" alone, io (the point is GameEngine carries none)

**State**:
board (flat 81 incl. given bits) + mutation history. No io. The pure unit the save format and the wasm boundary deal in — GameEngine is State plus domain fields plus FileTransport.
_Avoid_: Engine (engine is a runtime object), snapshot (that's the old Event framing)

**Event** (historical):
Old full-state snapshot framing. Superseded — renderers get the board through the same facade the terminal uses; the cross-boundary byte payload is State in the save format.
_Avoid_: reintroducing as a distinct type

## Architectural Decisions

See `docs/adr/` for numbered ADRs as cross-cutting decisions are recorded (e.g., WASM ABI shape, command schema, difficulty thresholds).
