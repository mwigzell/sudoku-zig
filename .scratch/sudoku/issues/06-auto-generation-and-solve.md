Status: ready-for-agent

## Parent

`.scratch/sudoku/prd.md`

## What to build

Auto-generation and solve-for-me: backtracking solver and puzzle generator in Zig, replacing or augmenting the hand-crafted puzzle pool.

- **Solver**: given any valid Sudoku grid (complete or partial), finds a solution via backtracking with constraint propagation. New command: `solve_for_me` — runs the solver on current board state, fills all empty cells with solution digits, and emits event with completed board.
- **Generator**: produces fresh puzzles at the requested difficulty level by starting from a solved grid and removing cells. Difficulty maps to number of given cells (easy ≈ 36+, medium ≈ 28–35, hard ≈ 20–27 — these are guidelines, tune during implementation). Generator must verify uniqueness of solution (use solver for this).
- `new_puzzle <difficulty>` now optionally draws from generated puzzles instead of (or alongside) the hand-crafted pool. Extract puzzle source behind a seam if needed — no stubs, just a natural decision point when you have two sources to choose from.

Tests: integration tests on GameEngine `solve_for_me` command asserting final board is valid and complete. Unit tests on solver against known grids (including unsolvable boards returning error). Generator tests for difficulty distributions and solution uniqueness.

## Acceptance criteria

- [ ] Solver solves a completed or partial grid correctly via backtracking
- [ ] `solve_for_me` command fills the current puzzle to a valid, complete solution
- [ ] Puzzle generator produces fresh puzzles at easy/medium/hard difficulty levels
- [ ] Generated puzzles have unique solutions (verified by solver)
- [ ] Number of given cells correlates with difficulty (easy > medium > hard)
- [ ] `new_puzzle <difficulty>` can draw generated puzzles
- [ ] Both TUI and browser renderers handle the new commands transparently through existing interfaces
- [ ] Integration tests exercise solve_for_me and generator-produced puzzle loading

## Blocked by

05
