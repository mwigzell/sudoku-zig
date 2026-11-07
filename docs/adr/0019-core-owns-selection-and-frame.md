# ADR-0019 — Core owns the selected cell; every front end draws core's frame

Status: accepted
Date: 2026-11-07
Supersedes: ADR-0011's "Cursor / selection memo" row

## Context

The selected cell was kept by each front end: the terminal remembered the last cell a fill or clear touched (`Sudoku.last_cell`), the page kept its own (`board.js` `selection`). Each decided on its own which actions move it, when it is dropped and what Hint targets. Show Region's shading was worked out three times: `cellsInRegion` in the page, `inPeerRegion` in the terminal styler, and core's `conflict.unitsMask`, which the validator and pencil-mark auto-clear use.

The terminal's `Facade.render(view, status, selection, marks_visible)` took one draw's state as separate arguments; each new piece added an argument and an edit to every implementation and caller.

## Decision

- **Core holds the selected cell** (`GameEngine.selected`, or none). It is session state: never saved, dropped on every load.
- **What sets it:** a select from the front end (web and Android: a tap or an arrow key); a fill, clear or pencil mark on a cell; Undo or Redo of a single-cell change, which selects the cell it changed.
- **What leaves it alone:** Hint, a refused move, Solve and its Undo or Redo, and settings and file commands other than loading.
- **What clears it:** a deselect from the front end (web and Android: tapping the selected cell again, Esc, Edit → Deselect Cell) and loading a game (New, Open, Import, Paste, restore).
- **`select` and `deselect` are commands.** They keep the status line and write nothing: no autosave, no settings.
- **Hint carries its own target;** core never takes it from the selection. The terminal's bare `hint` and Menu → Hint are board-wide, `hint E5` is about E5. Web and Android send the selected cell, read from core's frame.
- **The frame** (`src/core/frame.zig`) is one draw's state, from one builder, `frame.build(engine, status)`: the board, the status line, the selected cell, its region (`conflict.unitsMask` while Show Region is on), `marks_visible` and `pencil_mode`.
  - **Terminal:** `Facade.render(frame)` takes it as its only drawing argument.
  - **Web and Android:** the wasm snapshot is serialized from it (`GameSnapshot.fromFrame`), with `selected` and `region` (cell indices).

## Consequences

- No front end keeps or computes the selection or its region; each draws them from core. Every front end marks the selected cell whether Show Region is on or off; Show Region adds its row, column and box.
- The parity transcripts compare `selected` and `region` in every scenario's final state, so a front end that diverges fails.
- Renderers stay stateless painters (ADR-0011 rule 2); the memory between draws is core's, not the driver's or the page's.
- A new piece of drawing state is a frame field, not a new `render` argument.
- The selection is not in the game file; ADR-0018 is unchanged.
