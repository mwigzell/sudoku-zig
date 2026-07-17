Status: superseded (see ADR-0006)
Date: 2026-07-11

Superseded by ADR-0006 — during Issue 15 we moved from Box-owned topology to flat `[81]Cell` storage with computed views, as justified by renderer indirection, cache locality for row/col scans, and adding bitmask cache for solver work.

# ADR-0005 — Grid topology as Box-with-lens-row-column

**Decision**: The Board owns a Grid whose canonical storage is `box[3][3]`, each owning `cell[3][3]`. Rows and Columns are not owned structures but computed views (RowView, ColView) that assemble cell references across the Boxes they traverse.

**Rationale**: Sudoku constraints apply along three axes — row, column, and Box. A 2D array `cell[9][9]` or flat `[81]Cell` makes rows trivial but forces stride/index-arithmetic for columns and scattering math for boxes. By making Box the owner:
- Constraint checking iterates a Box's owned `Cell[3][3]` directly
- RowView/ColView are lenses assembled from three Boxes, no duplication of 81 cells
- The Solver/Generator can naturally union row ∪ col ∪ box candidates via identical `.cells()` surfaces
- Both TuiRenderer (draw dividers at Box boundaries) and WasmRenderer (iterate all cells with coordinates) share the same topology without the Renderer needing to know about constraint logic

## Considered Options
- **Flat `[81]Cell`**: Simplest allocation; requires `row * 9 + col` everywhere; box iteration is ugly modulo math. Cheap to start, expensive to reason about for constraint axes other than rows.
- **2D `Cell[9][9]`**: Clean row access; columns still require striding a loop (cell[c][0], cell[c][1]...); box membership needs index ranges. Better ergonomics but wrong shape conceptually — the 3×3 Box is the natural Sudoku unit, not 9 independent rows.
- **Box-with-RoyView/ColView** (chosen): Boxes own cells canonically. Derived views answer "which 9 cells belong to this row/col?" without duplicating storage. Matches how humans think about Sudoku and makes all three constraint axes symmetry.

## Consequences
- Initial rendering code has slightly more indirection than a flat array (`box[br][bc].cells[r][c]` instead of `cell[row*9+col]`) — but this is hidden behind Grid iteration helpers
- Board reconstruction (e.g., after loading puzzle data) writes through Box ownership, not a flat slice
- Future ADR may revisit if WASM FFI requires linear memory layout; views can then map onto contiguous storage without changing the domain logic
