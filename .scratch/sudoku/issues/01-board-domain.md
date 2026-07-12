Status: ready-for-agent

## Working mode
HITL (Human In The Loop). One TDD cycle per session. Agent enumerates its plan, does one iteration, pauses for explicit direction before proceeding. See `.coding-standards.md` → "TDD methodology (HITL)".

## Parent

`.scratch/sudoku/prd.md`

## What to build

Establish the Board domain model with Box-as-owner topology per ADR-0005.
No rendering or I/O — just the domain structs and construction logic.

### Domain model (per ADR-0005)
- **Box** owns `Cell[3][3]` and knows its `(boxRow, boxCol)` in the meta-grid.
- **Grid** is the immutable topology: holds the authoritative `box[3][3]`, provides `row(n)` and `col(n)` returning RowView/ColView lenses across that owned data.
- **Board** owns a Grid plus mutable game state (timer, conflict marks).
- One embedded easy puzzle stored inline; construction of Board from flat 81-element u8 array writes cells through Box ownership.

### Test seams
- All tests are co-located inline with the source modules they test (Ziglings 105 colocation pattern):
  - Cell tests live in `src/cell.zig`; Board construction tests in `src/board.zig`; Grid topology tests inline wherever Grid/RowView/ColView are defined.
  - Discovered by `addTest` via the library root (`src/root.zig`).

## Deliverable structures & functions (TDD order)

### Box (`src/box.zig` — ✅ TDD Cycle 1 complete)
| What | Detail |
|------|--------|
| Struct fields | `cells: [3][3]Cell`, `boxRow: u2`, `boxCol: u2` |
| Function | `init(r: u2, c: u2) Box` — construct all cells empty/unlocked with stable meta-grid position |
| Test | verifies 9 cells start zero + position metadata correct |

### Grid (`src/grid.zig` — pending)
| What | Detail |
|------|--------|
| Struct fields | `boxes: [3][3]Box` (canonical storage) |
| Functions | `row(n): u8 → *RowView`, `col(n): u8 → *ColView`, `cellAt(row, col): u8 → *Cell` (coordinate→Box resolution for Board construction) |
| Row/Col lenses | RowView / ColView structs that aggregate 9 cell references across the Boxes they traverse (computed views, not owned arrays) |

### Board (`src/board.zig` refactor — pending)
| What | Detail |
|------|--------|
| Change | Replace flat `cells: [81]Cell` with `grid: Grid` as canonical storage |
| Function (rename) | `initWithPuzzle(flat: [81]u8) Board` — replace current `boardFromFlat`, write cells through Box ownership (`row / 3`, `col / 3` → target box, `row % 3`, `col % 3` → cell slot within that box) |
| Keeps | Existing tests still valid concept-wise (givens locked, empties unlocked) — updated for Grid access pattern |

## Acceptance criteria

- [ ] Zig project compiles natively with zero warnings
- [ ] Box struct owns Cell[3][3] with (boxRow, boxCol) metadata
- [ ] Grid provides row(n), col(n) returning computed views (not owned arrays)
- [ ] Board constructable from flat 81-element puzzle data written through Box ownership
- [ ] Unit tests exercise domain model construction and Grid views

## Blocked by
(none — issue 08 closed, prerequisite met)

## Triage Assessment

**Date**: 2026-07-11 (triage from handoff session)

| Criterion | Status |
|-----------|--------|
| Specification clarity | ✅ Clear — structs, topology rules, render contract all defined with ADR cross-references |
| Acceptance criteria measurable | ✅ 5 checklist items covering Box ownership, Grid views, Board construction, compilation, and unit tests (scope reduced on 2026-07-11 — Renderer moved to issue 09) |
| Blocked by | ✅ Issue 08 (test infrastructure cleanup, completed) — unblocked |
| Parent PRD aligned | ✅ Domain model underpins all user stories; Renderer mapped to US1 via issue 09 |
| Test strategy defined | ✅ HITL TDD mode, co-located tests named for each module, smoke test via fixedBufferStream |

### Gap / Refactor Note

The **current codebase still uses flat `[81]Cell`** (`board.zig: cells: [DIMENSION_SIZE * DIMENSION_SIZE]cell.Cell`). Issue 01 requires restructuring to Box-as-owner topology per ADR-0005. This is a breaking refactor of `board.zig` (and its ripple into `render.zig`). The handoff and ADR are consistent — the old flat-array structure is exactly what gets replaced.

### Risks

1. **Renderer work is separate (issue 09).** Existing `render.zig` accesses flat-index `b.cells[flat_index]` and will break when Board switches to Grid/Box topology. Issue 09 covers the rewrite.
2. **Zig 0.17 test discovery quirks** — tests.zig already has workarounds for co-located test blocks. Resolved by issue 08 (test infrastructure cleanup). The TDD cycles should account for `addTest` mechanics documented in `.coding-standards.md`.
3. **Tests force-fail flag** — `tests.zig` line `try std.testing.expect(false)` is a deliberate debug trap from prior session and will be removed by issue 08.

### Verdict

Status remains **ready-for-agent**. No missing information. Agent can proceed directly to TDD Cycle 1: implement Box struct → Grid with row(n)/col(n) lenses → Board constructor through Box ownership, test-first on each slice.

**Restructure note (2026-07-12)**: Renderer work split out to issue 09. Test infrastructure split out to issue 08. Issue 01 now covers domain model only — Block/Box/Grid/Board topology per ADR-0005. Blocked by issue 08 before any TDD cycles begin.

## Comments
