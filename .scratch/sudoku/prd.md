Status: ready-for-agent

# PRD — Sudoku Playable Game in Zig (WASM)

## Problem Statement

I want a web-based Sudoku game to exercise my programming skills in Zig (a new language for me), and to test what this agent/LLM can build. The code should follow SOLID design principles so that interfaces are clean from day one — even features not yet built have their slots wired in.

## Solution

A playable Sudoku game with two deployments sharing one portable core: **native terminal** (blocking AsciiRenderer loop today) and **browser** (vanilla JS DOM shell + Zig WASM). Zig owns domain state and the SUD0 save codec. The browser shell sends structured actions and receives JSON (`Event`, board state, legend, config) — not a terminal screen feed. Terminal-first proved the engine; slice B replaces the failed wasm REPL with structured exports (see ADR-0010).

## User Stories

1. As a player, I want to see a 9×9 grid with some cells pre-filled, so that I know what puzzle I'm solving
2. As a player, I want to select an empty cell and enter a digit (1–9), so that I can make moves
3. As a player, I want conflicts highlighted visually (duplicate digits in the same row, column, or box shown as errors), so that I know when I've made a mistake
4. As a player, I want to load a new puzzle, so that I have fresh content to solve
5. As a player, I want notes/pencil marks support (candidate digits per cell), so that I can track possibilities
6. As a player, I want an undo action, so that I can back out of wrong moves
7. As a player, I want to save my current game state to a file and restore it later, so that I can pause and resume with full undo/redo history intact
8. As a player, I want puzzles generated automatically (not just static hand-written ones), so that there's always something new to play
9. As a player, I want difficulty selection when generating a puzzle, so that I can control how hard the game is
10. As a player, I want a "solve it for me" button that runs a solver and reveals the completed grid, so that I can finish a stuck puzzle or verify my progress
11. As a player, I want highlighted row/column/box regions when I select a cell, so that I can focus on related cells more easily
12. As a player, I want a timer showing how long I've been working on it, so that I can track speed per puzzle
13. As a developer, I want the domain logic in Zig to be renderer-agnostic (behind interfaces), so that the TUI and WASM browser are interchangeable — but those interfaces are extracted only when duplication exists, not stubbed from day one.

## Implementation Decisions

### Modules & Layering

The Zig code is organized into modular layers that emerge iteratively. We do **not** front-load abstractions — we start from `main.zig` rendering to the terminal and pull interfaces out only when a second concrete implementation needs to share a seam.

1. **Domain Core** — `Board`, `Cell`, `Grid` struct models. Encapsulates a 9×9 puzzle state. Pure structs, no I/O.
2. **Validator** — conflict detection logic. Given a Board state, reports which cells are in error (duplicate digits in shared row/column/box).
3. **GameEngine** — portable orchestrator. Gameplay commands (`fill`, `clear`, `undo`, `redo`, `quit`) mutate Board state, run validation, and emit `Event`. Holds `State` and the SUD0 codec (`toSaveFormat` / `loadSaveFormat`). **No file I/O, no paths, no transport.**
4. **App shell** — native: `Sudoku` owns the command loop, `FileTransport`, session commands (save/open/new-from-file), and the blocking terminal facade. Web: JS owns DOM, file UX, and acknowledgement; wasm exports structured API only.
5. **Renderer** — native terminal facade (AsciiRenderer today). Web: JS renders from state JSON wasm returns — not an ASCII projector. Future TUI / Linux GUI are separate native shells (revisit blocking facade then).
6. **Puzzle Repository** — `PuzzleGen` fixtures in Zig today (by `Difficulty`); real generator later, same module. JS knows difficulty via `BootstrapConfig`; not puzzle strings.
7. **Solver Service** — not needed until user stories 10 (solve-for-me) and 8 (auto generation, which depends on a solver for verification). Built then, not stubbed earlier.
8. **Save/Restore** — SUD0 codec in Zig only. Native: `Sudoku` + `FileTransport` read/write bytes, then `loadSaveFormat` / `toSaveFormat` on engine. Web: JS reads/writes opaque files; wasm `serialize`/`deserialize` — no SaveFormat logic in JS.

### WASM Boundary (slice B onward — ADR-0010)

- **Not** command-line REPL (`step(line)` + ASCII screen). Retired.
- Exports: `init(BootstrapConfig)`, `exec(action_json)` → `Event` JSON, `getLegend()` → JSON, state for DOM, `serialize`/`deserialize` for files.
- JS is an active front-end (board, buttons, modals, file pickers); wasm never blocks for UI acknowledgement.
- Wire format slice B: JSON strings in linear memory; optimise later if needed.

### First Slice: TUI

Vertical slice 1 renders entirely through a terminal UI (no WASM). This proves the interfaces work before any cross-language boundary complexity is introduced.

### Language

Zig (stable/0.13 or latest stable). Zig build system (`build.zig`) manages compilation for both native (TUI) and WASM targets.

## Testing Decisions

- Tests exercise **external behavior only**, not internal implementation details
- Domain Core: unit tests on `Board` mutations, `Validator` correctness against known conflict states
- GameEngine: integration tests through the command/event seam — send a gameplay command, assert emitted event matches expected state snapshot
- Native: integrated e2e through `Sudoku` + MockSource (full terminal loop)
- Wasm: node contract test on real `artifact.wasm` + JSON exports (`glue.test.mjs`); browser DOM e2e optional
- The cross-cutting engine seam remains **command → event**; deployment shells are optional e2e layers (ADR-0002)

## Out of Scope

- Account system, leaderboards
- Implicit persistence (autosave, session-local storage) — explicit SAVE/LOAD commands are in scope; browser localStorage / cross-device sync is not
- Mobile-responsive layout optimisation (clean desktop-first responsive OK, but no pinch/zoom gesture handling)
- Multiple puzzle themes or variant Sudoku rules (Killer, Jigsaw, etc.)
- Multi-language/i18n

## Further Notes

- The goal is as much about clean architecture and SOLID principles in Zig as it is about a working Sudoku game. Abstractions are **earned by duplication** — we start with concrete code rendering to the TUI, and extract interfaces only when a second implementation (WASM renderer, auto-generator) needs them. No empty stubs or placeholder interfaces; every seam has two concrete consumers before it exists.
- Puzzle data for MVP: embed 3–5 hand-crafted puzzles (easy/medium/hard mix) as Zig arrays inline or in a simple data file.
