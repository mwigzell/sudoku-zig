Status: ready-for-agent
Triage date: 2026-07-16
Triage notes:
  - Parent index complete: scope, why, acceptance criteria, ADR-0006 reference all present.
  - Design decisions locked per prior session (flat storage, borrowed BoardView, no snapshot layer).
  - Sub-issues 15.1–15.5 drafted next with explicit code diffs + test blocks.
  - Agent will draft one sub-issue at a time, pausing for human review before coding.

## Blocked By

- [x] 15.1 (Flat `[81]Cell` storage) — closed
- [x] 15.2 (Box digit bitmask cache) — closed
- [ ] 15.3 (BoardView + Row/Col/Box lenses) — not yet closed
- [ ] 15.4 (AsciiRenderer replacing StdoutRenderer) — not yet closed
- [ ] 15.5 (main.zig rewire + cleanup) — not yet closed

## Working mode
HITL (Human In The Loop). One TDD cycle per sub-issue. Agent enumerates plan with code diffs, human reviews on paper before coding. See `.coding-standards.md` → "TDD methodology (HITL)".

## Parent

`.scratch/sudoku/prd.md`

## What to build

Refactor the Board topology from Grid-as-storage (Box owns `Cell[3][3]`) to flat `[81]Cell` storage on Board. This flattens the data layout, demotes Box/Grid to computed views, and modernises the renderer — all while preserving identical `zig build run` output.

### Why (current pain points)
- **Box owns cells** — every lookup crosses `Grid → Box → Cell`. Scanning a row or column requires visiting 3 Boxes, pulling 3 cells from each. Cache-unfriendly and unnecessarily indirection-heavy.
- **Renderer indirection** — `StdoutRenderer` takes ownership of a copy (`RenderSnapshot`) just to iterate 81 cells in row-major order. We already flatten the grid for rendering.
- **No O(1) box membership test** — finding candidates during solving requires iterating all 9 cells per box with no precomputed bitmask.

### Design decisions (locked by prior session)
1. **Keep `Cell` struct shape** — `value: CellValue` (enum(u4)) + rename `locked` → `given`. No new CellState type, no separate value/flag arrays. Dropping `CellValue` for raw `u4` is deferred — binary layout is identical either way.
2. **BoardView is read-only borrowed lens** (`[]const Cell`). Mutation exclusively through Board's `setCell` / `clearCell`. No mutable BoardView.
3. **No snapshot layer** — command-then-render is sequential in a single-threaded game loop. Snapshot capability (solver, generation) is trivial at 81 u4s when actually needed.

## Sub-issue index

Each sub-issue must be reviewed against this parent's acceptance criteria and existing artifacts before code is written.

| Issue | Scope | File |
|-------|-------|------|
| [15.1 Flat `[81]Cell` storage](./15.1-refactor.md) | Drop Grid-as-storage, standalone Box. Add `setCell`, `clearCell`, `cellAt`. Update constructors. Rename `locked` → `given`. | `15.1-refactor.md` |
| [15.2 Box digit bitmask cache](./15.2-refactor.md) | `[9]u32` bitmask on Board, updated in mutation chokepoints. O(1) `hasValueInBox`. | `15.2-refactor.md` |
| [15.3 BoardView + Row/Col/Box lenses](./15.3-refactor.md) | Borrowed `BoardView`, 9-cell view structs for each axis. Intersection tests. | `15.3-refactor.md` |
| [15.4 AsciiRenderer replacing StdoutRenderer](./15.4-refactor.md) | Drop `RenderCell`/`RenderSnapshot`/`assembleRenderSnapshot`. Injected `std.Io.File.Writer`. Buffer-backed render tests. | `15.4-refactor.md` |
| [15.5 main.zig rewire + cleanup](./15.5-refactor.md) | Wire AsciiRenderer via Writer. Update root.zig imports. Drop obsolete files (box.zig, grid.zig → leaner, renderer.zig, collapse std_renderer.zig). Full test suite green. | `15.5-refactor.md` |

## Acceptance criteria

- [ ] `zig build run` produces identical ASCII board output for the embedded puzzle.
- [ ] All 16+ existing tests pass; new tests added for flat storage accessors, bitmask cache, view lenses, and buffer-backed rendering.
- [ ] `zig build cov` shows equal or improved coverage vs pre-refactor baseline.
- [ ] Obsolete files removed; `src/root.zig` imports reflect final module set.
- [ ] No wrapper-only test paths — all tests exercise the same code `main()` uses.

## ADR

ADR-0006 (`docs/adr/0006-flat-storage.md`) records this decision. Supersedes ADR-0005.

## Existing artifacts (do not duplicate)
- Refactor plan: `.scratch/sudoku/sudoku.md`
- Parent PRD: `.scratch/sudoku/prd.md`
- Issue 01 (Board domain): `.scratch/sudoku/issues/01-board-domain.md`
- ADR-0005: `docs/adr/0005-grid-topology.md`
- CONTEXT.md: `CONTEXT.md`
- Coding standards: `.coding-standards.md`
