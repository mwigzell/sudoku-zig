Status: ready-for-agent

# PRD — Sudoku Playable Game in Zig (WASM)

## Problem Statement

I want a web-based Sudoku game to exercise my programming skills in Zig (a new language for me), and to test what this agent/LLM can build. The code should follow SOLID design principles so that interfaces are clean from day one — even features not yet built have their slots wired in.

## Solution

A playable Sudoku game delivered as a Zig WASM module running in the browser, with a thin vanilla JS shell handling DOM rendering. Zig owns all domain state and **pushes** JSON event snapshots after each command. The first vertical slice proves the architecture by rendering a **TUI** (not a browser); once interfaces are validated, a second slice swaps in the WASM bridge + browser renderer through the same slots.

## User Stories

1. As a player, I want to see a 9×9 grid with some cells pre-filled, so that I know what puzzle I'm solving
2. As a player, I want to select an empty cell and enter a digit (1–9), so that I can make moves
3. As a player, I want conflicts highlighted visually (duplicate digits in the same row, column, or box shown as errors), so that I know when I've made a mistake
4. As a player, I want to load a new puzzle, so that I have fresh content to solve
5. As a player, I want notes/pencil marks support (candidate digits per cell), so that I can track possibilities
6. As a player, I want an undo action, so that I can back out of wrong moves
7. As a player, I want puzzles generated automatically (not just static hand-written ones), so that there's always something new to play
8. As a player, I want difficulty selection when generating a puzzle, so that I can control how hard the game is
9. As a player, I want a "solve it for me" button that runs a solver and reveals the completed grid, so that I can finish a stuck puzzle or verify my progress
10. As a player, I want highlighted row/column/box regions when I select a cell, so that I can focus on related cells more easily
11. As a player, I want a timer showing how long I've been working on it, so that I can track speed per puzzle
12. As a developer, I want the domain logic in Zig to be renderer-agnostic (behind interfaces), so that the TUI and WASM browser are interchangeable — but those interfaces are extracted only when duplication exists, not stubbed from day one.

## Implementation Decisions

### Modules & Layering

The Zig code is organized into modular layers that emerge iteratively. We do **not** front-load abstractions — we start from `main.zig` rendering to the terminal and pull interfaces out only when a second concrete implementation needs to share a seam.

1. **Domain Core** — `Board`, `Cell`, `Grid` struct models. Encapsulates a 9×9 puzzle state. Pure structs, no I/O.
2. **Validator** — conflict detection logic. Given a Board state, reports which cells are in error (duplicate digits in shared row/column/box).
3. **GameEngine** — orchestrates player turns. Receives commands (`fill_cell`, `clear_cell`, `toggle_note`), mutates Board state, runs Validation, and emits an event describing the new state.
4. **Renderer** — starts as a direct call to print-to-terminal from `main.zig`. When WASM browser renderer is needed, the rendering logic is factored behind an interface so TUI and DOM are interchangeable. Interface extracted only when duplication exists (TUI + browser), not stubbed upfront.
5. **Puzzle Repository** — starts as inline static puzzle data in `main.zig` or a simple array file. Extracted to a swappable repository slot only when auto-generation arrives. No empty interface stubs — the seam appears when a second source is needed.
6. **Solver Service** — not needed until user stories 9 (solve-for-me) and 7 (auto generation, which depends on a solver for verification). Built then, not stubbed earlier.

### WASM Boundary (slice 2 onward)

- Command/event style: JS sends command strings (`"fill_cell row col digit"`), Zig processes and pushes one or more JSON events describing state changes back through WASM exports.
- Zig owns the single source of truth for game state. The JS shell is a passive renderer — it receives events and re-renders DOM.

### First Slice: TUI

Vertical slice 1 renders entirely through a terminal UI (no WASM). This proves the interfaces work before any cross-language boundary complexity is introduced.

### Language

Zig (stable/0.13 or latest stable). Zig build system (`build.zig`) manages compilation for both native (TUI) and WASM targets.

## Testing Decisions

- Tests exercise **external behavior only**, not internal implementation details
- Domain Core: unit tests on `Board` mutations, `Validator` correctness against known conflict states
- GameEngine: integration tests through the command/event seam — send a command, assert emitted event matches expected state snapshot
- The single cross-cutting test seam is the **command → event** boundary. Tests feed commands into GameEngine and assert the pushed events are correct. No DOM/TUI assertions needed in tests — the renderer is behind an interface.

## Out of Scope

- Account system, leaderboards, persistence across sessions (localStorage persistence could be added later but is not MVP)
- Mobile-responsive layout optimisation (clean desktop-first responsive OK, but no pinch/zoom gesture handling)
- Multiple puzzle themes or variant Sudoku rules (Killer, Jigsaw, etc.)
- Multi-language/i18n

## Further Notes

- The goal is as much about clean architecture and SOLID principles in Zig as it is about a working Sudoku game. Abstractions are **earned by duplication** — we start with concrete code rendering to the TUI, and extract interfaces only when a second implementation (WASM renderer, auto-generator) needs them. No empty stubs or placeholder interfaces; every seam has two concrete consumers before it exists.
- Puzzle data for MVP: embed 3–5 hand-crafted puzzles (easy/medium/hard mix) as Zig arrays inline or in a simple data file.
