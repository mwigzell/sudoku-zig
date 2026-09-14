# CONTEXT — Sudoku in Zig (WASM)

## Project Goal

A playable Sudoku game as a WASM module compiled from Zig, running in the browser with a thin vanilla JS shell. A terminal front-end (AsciiRenderer) proves the architecture first; both deployments share the same portable GameEngine core. (Note: a true TUI is an ncurses front-end — not implemented yet.)

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

**Renderer** (native):
Interface for presenting Board state in the terminal. AsciiRenderer (ANSI or plain) is the concrete implementation today; it receives `Event` snapshots from the game loop and never reads Board internals directly. The browser does **not** use a Zig renderer — JS builds the DOM from wasm JSON (`GameSnapshot`).
_Avoid_: View (conflicts with RowView/ColView), UI, TUI (TUI = an ncurses front-end, not the current AsciiRenderer)

**Event**:
Output of `GameEngine.exec()` after a gameplay command — `.ok` carries a `BoardView`, optional message, and `is_quit`; `.error_msg` carries a reason string. Native `Sudoku` passes this to the renderer facade. The wasm boundary serializes the same semantics as JSON (`boundary.zig` / `glue.js`).
_Avoid_: Payload (ambiguous), State dump

**Command**:
Player action vocabulary (`fill`, `clear`, `undo`, `redo`, `quit`, plus session tags parsed but not executed in `GameEngine.exec`). Native: parsed from a terminal line. Wasm: JSON action payloads (`{"action":"fill","row":…}`). Carries intent, not state.
_Avoid_: Input action (framework term)

**GameEngine**:
Portable orchestrator. Gameplay `exec` (fill, clear, undo, redo, quit) mutates `State`, runs validation, and returns `Event`. Owns the SUD0 codec (`toSaveFormat` / `loadSaveFormat` on bytes). **No** `FileTransport`, paths, or `std.Io`. Session persistence is **not** in `exec`. Single cross-cutting native test seam: Command → GameEngine → Event.
_Avoid_: Engine alone (ambiguous — Solver Service also contains "engine" semantics), Controller (MVC framework term)

**Legend**:
State-aware command availability flags (`fill`, `clear`, `quit`, `undo`, `redo`, session commands). Native renderer formats these for the terminal; wasm exposes them as JSON via `getLegend()`.
_Avoid_: AvailableCommands (retired name)

### Validation & Solving

**Validator**:
Given a Board state, reports which cells conflict with the digit in their row (9-cell RowView), column (9-cell ColView), or Box (owned 3×3). Rules enforced at command time after every mutation.
_Avoid_: Checker (implies boolean only)

**PuzzleGen**:
Concrete puzzle source today — canned one-line strings keyed by `Difficulty` (`easy`, `medium`, `hard`, plus a legacy `default` fixture). Used by native `Config`, wasm `init`, and tests. Not a general generator yet.
_Avoid_: treating it as the final Puzzle Repository interface

**Puzzle Repository** (domain slot):
Where puzzle data comes from. **`PuzzleGen` is the only implementation shipped** — inline fixtures, no `PuzzleSource` trait yet. A real auto-generator (with solver verification) will extract behind this slot when user stories 8–10 need it. The wasm boundary passes **difficulty only** (`BootstrapConfig`); puzzle strings never cross to JS.
_Avoid_: Puzzle store, PuzzleSource (name reserved for a future interface)

**Solver Service**:
Backtracking solver that completes or verifies puzzles by iterating RowView, ColView, and Box cell sets to compute valid candidates. Extracted behind an interface when both "generate" and "solve-for-me" features need it.
_Avoid_: Engine (collides with GameEngine)

### App Shell & Deployments

**Sudoku** (`native/shell/sudoku.zig`, native app shell):
Owns the command loop, renderer facade, `FileTransport`, and session command routing (`save`, `open`, `save_as`, `new`) in `handleResult` before delegating gameplay to `GameEngine.exec`. This is the native integrated e2e seam.
_Avoid_: folding session I/O into GameEngine

**Web app shell** (`page.html`, `glue.js`, `wasm/shell.js`):
JS owns fetch, DOM, file UX, and user acknowledgement. Calls wasm exports; never parses SUD0 or projects a terminal screen. Session file intents (save/open/new) will live here (#35); gameplay goes through `exec(action_json)`.
_Avoid_: reintroducing a wasm REPL or ASCII screen feed

**RendererKind** (`-r`, native only):
The user-facing renderer *place*: `ansi`, `ascii`, `tui`, `web`. `-r web` serves embedded static assets and exits — no game loop in the native binary. Renderer selection is native-only; the wasm deployment is web by construction.
_Avoid_: calling the browser renderer "wasm"

**Host** (`native/host.zig`):
Native terminal substrate — builds `IoSession`, selects AsciiRenderer facade arms. Wasm has no Host analogue; the JS page is the substrate.
_Avoid_: Host as a concrete object (it's the seam), "session" (that's the native substrate under it)

**FileTransport** (`native/shell/file_transport.zig`, native arm):
Fn-pointer vtable for file read/write/resolve. **Owned by native `Sudoku`**, passed into session handlers — not by `GameEngine`. The wasm path uses `serialize`/`deserialize` on opaque bytes instead; no wasm transport arm.
_Avoid_: "transport" alone, io (the point is GameEngine carries none)

**State**:
Board (flat 81 incl. given bits) + mutation history. No I/O. The unit the SUD0 codec and wasm boundary deal in. `GameEngine` wraps `State` plus optional dialog metadata (`data_dir`, `last_save_msg`) used by native session handlers.
_Avoid_: Engine (engine is a runtime object)

### WASM Wire (`wasm/wire.zig`, `wasm/boundary.zig`, `wasm_entry.zig`)

**BootstrapConfig**:
Wasm `init` payload — `PlayerDifficulty` (wire values 1/2/3) and optional log level. Maps to native `Difficulty` for `PuzzleGen.generate`; JS never sees puzzle strings.
_Avoid_: passing puzzle bytes across the boundary at bootstrap

**GameSnapshot**:
JSON-serializable display twin of `BoardView` — per-cell `value`, `given`, `conflict`. Returned by `getState()` and embedded in successful `exec` responses. DOM shell renders from this shape.
_Avoid_: duplicating SaveFormat fields in JS

**wasm_entry**:
Second entry point (not `main.zig`). Exports structured API: `init`, `exec`, `getLegend`, `getState`, `serialize`, `deserialize`. JSON strings in linear memory (NUL-terminated); SUD0 bytes for save/load. Contract tested by `glue.test.mjs`.
_Avoid_: `step(line)`, `page_bytes_out`, or other REPL imports (removed — see ADR-0010)

**glue.js**:
Thin loader/instantiator — marshals JSON and byte buffers across the wasm export table. Shared by the served page and node contract tests.
_Avoid_: embedding game rules or SaveFormat parsing

## Architectural Decisions

See `docs/adr/` for numbered ADRs as cross-cutting decisions are recorded (e.g., ADR-0010 structured wasm boundary, command schema, difficulty thresholds).
