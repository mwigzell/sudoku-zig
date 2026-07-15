Status: ready-for-agent

## Parent

`.scratch/sudoku/prd.md`

## What to build

Replace `default_puzzle.zig` with a proper puzzle generator module. Extract the single embedded puzzle into a collection of canned puzzles organized by difficulty level, so that `main.zig` and GameEngine can select puzzles at run-time. (Phase 1 backer of what the original spec called auto-generation + solve.)

### Concretely

- Create `src/generator.zig`
- Define `Difficulty` enum: `{ easy, medium, hard }`
- Maintain a canned puzzle pool — at least one puzzle per difficulty level (current `default_puzzle` becomes the easy-level entry)
- `Generator.generate(difficulty)` returns puzzle data suitable for `Board.fromFlat(u8[81])` or equivalent loader
- Replace the import of `default_puzzle.zig` in `main.zig` (and any other consumer) with the new generator API
- Remove or retire `src/default_puzzle.zig` once wired through generator

### Puzzle data

Each canned puzzle should be a flat `u8[81]` string matching the existing ingestion format used by `Board.fromFlat()`. Store puzzles in a simple lookup table keyed by difficulty. Each entry records at least:
- The initial grid (`u8[81]`)
- Which cells are locked/given (derived from the grid structure — non-zero cells)

Difficulty → given cell guidelines for when you curate puzzles:
- Easy: ≈ 36+ given cells
- Medium: ≈ 28–35 given cells
- Hard: ≈ 20–27 given cells

## Acceptance criteria

- [ ] `src/generator.zig` exists with `Difficulty` enum and canned puzzle pool (≥1 per difficulty)
- [ ] Generator returns valid puzzle data for each difficulty level via a clean API
- [ ] Returned puzzles load into Board without errors (`Board.fromFlat()` or equivalent)
- [ ] `src/default_puzzle.zig` is retired — `main.zig` uses generator instead
- [ ] Number of given cells in each canned puzzle correlates with its difficulty tier
- [ ] Unit tests: each difficulty returns a valid, well-formed puzzle (passes board construction)
- [ ] Integration test: GameEngine receives a generated puzzle via the command/event seam

## Blocked by

_No thing. Works against current code state. Does not wait on WASM or solver._
