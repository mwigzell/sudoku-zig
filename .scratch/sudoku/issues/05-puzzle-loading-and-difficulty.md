Status: ready-for-agent
Blocked By: Issue 15 — Board topology refactor (ADR-0006)

## Parent

`.scratch/sudoku/prd.md`

## What to build

Puzzle selection with difficulty levels: extract embedded puzzle data into a collection of 3–5 hand-crafted puzzles across easy, medium, and hard difficulties. Player can pick difficulty; a fresh puzzle from that pool loads and resets game state completely (clearing values, notes, undo history).

- New command: `new_puzzle <difficulty>` where difficulty is `easy`, `medium`, or `hard`.
- Puzzle data stored in a Zig array-of-puzzles structure (or simple file if more natural). Each puzzle records the initial grid plus which cells are locked/given.
- GameEngine resets full state on new puzzle load and emits event with fresh board snapshot and reset timer-ready state (timer not yet built — just reset whatever baseline exists).

Tests exercise new_puzzle command via the command→event seam, asserting correct board data for selected difficulty.

## Acceptance criteria

- [ ] 3–5 hand-crafted puzzles embedded across easy, medium, hard difficulties
- [ ] `new_puzzle <difficulty>` loads a fresh puzzle and resets all board state (values, notes, history)
- [ ] Given/locked cells are tracked so mutations on them remain rejected
- [ ] Integration tests exercise new_puzzle command for at least two difficulty levels
## Blocked by

(none)
