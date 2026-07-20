## Parent

`.scratch/sudoku/prd.md`

## What to build

Region highlighting and session timer: visual focus aid when selecting cells, and elapsed-time display.

- **Region highlight**: New command `select_cell <row> <col>` — read-only, does not mutate board state. GameEngine emits event with the selected cell's coordinates in its metadata. On render, TUI and browser highlight all cells sharing the same row, column, and/or 3×3 box as the selected cell (with distinct emphasis from conflict highlighting — e.g., background shading vs. red text).
- **Timer**: Start counting on puzzle load (`new_puzzle`). Track elapsed time in GameEngine state include with each event snapshot. TUI shows elapsed time above or below the grid; browser shows it as a readable display element. Pause/resume/stop behavior is your call (keep it simple — just accumulate seconds since last `new_puzzle` or similar reset).

Tests exercise `select_cell` command through the command→event seam, asserting correct selection metadata in emitted events. Timer accuracy verified by checking elapsed seconds against known durations in tests.

## Acceptance criteria

- [ ] `select_cell <row> <col>` emits selection coordinates without mutating board state
- [ ] TUI highlights row, column, and 3×3 box of the selected cell (visually distinct from conflict errors)
- [ ] Browser also highlights the selected cell's regions on click or equivalent interaction
- [ ] Timer starts on puzzle load and accumulates elapsed time
- [ ] Elapsed time displayed in both TUI and browser renderers
- [ ] Timer resets on `new_puzzle` command
- [ ] Integration tests exercise select_cell and timer reset through the command→event seam

## Blocked by

(none)
