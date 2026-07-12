Status: ready-for-agent

## Parent

`.scratch/sudoku/prd.md`

## What to build

Pencil marks (notes) and undo: two new commands added to GameEngine, automatically working in both TUI and browser through the shared Renderer interface.

- Extend `Cell` to hold a set of candidate digits (1–9) separate from its main value.
- New command: `toggle_note <row> <col> <digit>` toggles that digit as a candidate for the cell. Only permitted on empty cells; given/locked cells reject mutations.
- New command: `undo` pops the last mutation from a history stack reverts to prior state. Undo must restore both main values and notes.
- Event snapshot emitted by GameEngine must include notes data per cell so both renderers can draw them.
- TUI renders notes small (lowercase or superscript-style, your call). Browser renders similarly within the cell div/span.

Tests exercise command→event seam for note toggling and undo with expected state snapshots.

## Acceptance criteria

- [ ] Cell model supports a set of candidate digits independent from its main value
- [ ] `toggle_note` command adds/removes a digit as a pencil mark for an empty cell
- [ ] Notes cannot be placed on given/locked cells
- [ ] `undo` reverts the last mutation (fill, clear, or note toggle) correctly, including both values and notes state
- [ ] Multiple undo calls restore earlier states sequentially
- [ ] Event snapshot includes per-cell notes data; both TUI and browser render notes visibly
- [ ] Integration tests exercise note and undo commands through the command→event seam

## Blocked by

03
