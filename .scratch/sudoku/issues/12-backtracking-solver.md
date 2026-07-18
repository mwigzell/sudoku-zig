Status: needs-triage

## Parent

`.scratch/sudoku/prd.md`

## What to build

A backtracking solver for Sudoku puzzles, exposed through a `solve_for_me` command in GameEngine. Takes any valid partial or complete grid and produces a full solution (or returns an error if unsolvable).

### Concretely

- Create `src/solver.zig` with backtracking algorithm
- Accept board state (`u8[81]` flat input) and return solved grid or appropriate error
- Wire `solve_for_me` command into GameEngine — runs solver against current board, fills empty cells
- Emits event(s) for both renderers to re-render completed grid

### Backtracking requirements

- Standard backtracking with constraint propagation (check row/column/box uniqueness before placing candidates)
- Try digits 1–9 in valid positions per cell; backtrack on conflict
- Return meaningful error if no solution exists

## Acceptance criteria

- [ ] Solver solves a completed grid correctly (idempotent — returns the same grid)
- [ ] Solver solves partial grids via backtracking (tested against known puzzles/solutions)
- [ ] Solver returns an error for provably unsolvable boards
- [ ] `solve_for_me` command fills current puzzle to valid complete solution
- [ ] Integration test: GameEngine processes solve, final board state is valid and fully filled

## Blocked by

06 — needs generator module for canned puzzles to exercise solver against known solvable/unsolvable grids in tests.
