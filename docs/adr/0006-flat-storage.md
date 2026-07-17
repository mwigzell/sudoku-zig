# ADR-0006 — Flat `[81]Cell` storage with computed views

Status: accepted
Date: 2026-07-16
Supersedes: ADR-0005 (Grid topology, Box ownership)

## Context

Under ADR-0005, Box is the canonical owner of `Cell[3][3]` and Grid holds the authoritative `boxes[3][3]`. Rows and columns are lenses assembled across three Boxes each. This matched how we built things initially — constraint checking iterates naturally over a Box's owned cells.

But the project has evolved past the initial TUI phase:
- The renderer already flattens to row-major order via `RenderSnapshot` (a copy of 81 cells) just to draw ASCII lines
- Constraint checks for rows and columns require jumping across 3 Boxes, pulling 3 pointers each — poor cache locality
- Adding O(1) box-membership tests (bitmasks for candidate generation / solving) is awkward when Box owns individual cells scattered in separate memory regions
- `StdoutRenderer` takes **ownership** of a copy, making testing require the same copy path rather than lending views

We have hit the point where ADR-0005's convenience ("Box owns, views are derived") trades against practical ergonomics and testability.

## Decision

- **Board owns `cells: [81]Cell`** — single contiguous allocation indexed `[row][col]` → `row * 9 + col`.
- **Box is a computed view** — given `(boxRow, boxCol)`, the 9 cell indices are computed on demand. No Box struct owning its own cells.
- **RowView and ColView remain lenses** — they still hold references/indices into Board's flat storage rather than duplicating cells.
- **BoardView** is a new read-only borrowed slice (`[]const Cell`), passed to renderers instead of owned copies. Renderers iterate it directly.
- **Mutation via chokepoints only** — `Board.setCell(index, value)` and `Board.clearCell(index)`. No direct access to the flat array outside Board methods.
- **Rename `Cell.locked` → `Cell.given`** — clearer domain language (a "given" cell is fixed by the puzzle).
- **Box digit bitmask cache** — `[9]u8` on Board, each bit `n` set when digit `D(n)` appears somewhere in that Box. Updated inside mutation chokepoints for O(1) membership tests.

## Considered Options

| Option | Verdict |
|--------|---------|
| Keep ADR-0005 (Box owns cells) | Rejected — renderer copy path is wasteful; row/col constraint loops scatter across Boxes; adding bitmask cache means keeping two sources of truth per Box. |
| `Cell[9][9]` (2D array) | Close, but `[81]Cell` with math (`row * 9 + col`) is the same binary layout and maps naturally to slices for BoardView. No loss going flat. |
| Separate value/flag arrays (e.g., `[81]u4` + `[81]bool`) | Same total bytes but more confusing API — caller must keep two indices in sync. Keeping `Cell{value, given}` as one struct is cleaner and identical memory footprint. |

## Consequences

- **Positive**: Renderer path becomes borrow-and-render (no copy); row iteration is contiguous memory; bitmask cache for solver work is additive over flat storage with simple arithmetic per Box.
- **Negative**: Box cell iteration replaces a tight `[3][3]` loop with index math (`base + colOffset + rowOffset * 9`). Negligible runtime cost; Zig optimizer handles closed-form indexing well.
- **Risk**: Existing tests exercise Grid-level helpers (row(n), col(n)) deeply. These must be retargeted to Board-level test seams in the same refactor (Issue 15). The sub-issue plan addresses this via TDD: each phase is tested before moving on.
