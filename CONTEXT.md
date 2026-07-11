# CONTEXT — Sudoku in Zig (WASM)

## Project Goal

A playable Sudoku game as a WASM module compiled from Zig, running in the browser with a thin vanilla JS renderer. A TUI front-end proves the architecture first; both renderers share the same GameEngine domain layer behind an interface.

See `.scratch/sudoku/prd.md` for full PRD and user stories.

## Coding Standards
See `.coding-standards.md` for all coding, testing, TDD methodology, and project architecture guidelines.

## Domain Glossary

| Term | Meaning |
|------|---------|
| **Board** | The canonical state container: 9×9 grid of cells (81 total), their values, locked status, note candidates, and derived data (conflicts, timer). |
| **Cell** | A single position on the board holding a value (empty or digit 1–9), locked/given flag, optional notes/candidates set, and per-cell conflict flags. Total: 81 cells. |
| **Box** (also: region, square) | A 3×3 block of cells. The board contains 9 boxes arranged in a 3×3 grid — this is the recursive structure: 3×3 boxes, each containing 3×3 cells. Box boundaries are visually distinct in renderings. |
| **Grid** | The full 9×9 layout model defining rows (9), columns (9), and box membership (9 boxes × 9 cells). Provides lookup helpers for row/col/box membership. Renders with top/bottom horizontal borders, left/right vertical borders, and internal dividers between boxes. |
| **GameEngine** | Orchestrates player turns: receives commands, mutates Board state, runs validation, emits full-state events to the Renderer. |
| **Validator** | Given a Board state, reports which cells conflict with the digit in their row, column, or 3×3 box (duplicates flagged as errors). Rules enforced at command time after every mutation. |
| **Renderer** | Interface for outputting the Board snapshot. Concrete implementations: TUI prints to terminal, WASM browser renders DOM from JSON events. |
| **Command** | Player action sent to GameEngine (e.g., `fill_cell <row> <col> <digit>`). Carries intent, not state — GameEngine decides what to mutate and validates. |
| **Event** | Full-state snapshot emitted by GameEngine after each command. Contains everything a Renderer needs to draw the current board. |
| **Puzzle Repository** | Source of Sudoku puzzle data. Starts as inline hand-crafted arrays; extracts behind an interface when a second source (auto-generator) is added. |
| **Solver Service** | Backtracking solver that completes or verifies puzzles. Extracted behind an interface when both "generate" and "solve-for-me" features need it. |

## Architectural Decisions

See `docs/adr/` for numbered ADRs as cross-cutting decisions are recorded (e.g., WASM ABI shape, command schema, difficulty thresholds).
