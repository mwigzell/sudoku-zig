# Issue 08 — Test infrastructure cleanup (idiomatic Zig colocation via library root)

Status: closed

## Parent

`.scratch/sudoku/prd.md`

## What to build

Restructure the test setup so that `addTest` discovers all colocated inline `test {}` blocks
naturally, following the idiomatic Zig pattern (Ziglings 105 style). The current setup has two
workarounds caused by having no proper library root:

### Problems to fix

1. **Fake test-runner aggregator (`src/tests.zig`).** This file exists solely to serve as a dead-code-workaround root for Zig 0.17 test discovery. Its `references` test (line ~18) touches every module just to prevent the compiler from discarding imported modules, and its `sanity` test is a trivial placeholder. Both are unnecessary with a proper library root.

2. **printGrid test forced out of `src/render.zig`.** Lines 68-70 of render.zig note that printGrid testing lives in `tests.zig` because "std.io fails to resolve under the current transitive-import arrangement." This is an import-graph problem caused by having no proper root — with a real library root, colocated tests compile fine.

3. **No library root for `addTest`.** The exe step points at `main.zig` (which only imports `board`) and the test step points at `tests.zig` — neither gives `addTest` a root that transitively covers all modules. This broken import topology forces the workarounds above.

### Work to do

1. **Create `src/root.zig`** as a proper library root that re-exports all modules:
   ```zig
   pub const cell = @import("cell.zig");
   pub const board = @import("board.zig");
   pub const render = @import("render.zig");
   ```

2. **Fix `build.zig` test step** to use `src/root.zig` as the root source file — giving `addTest` a module that transitively imports everything, so Zig's import-graph discovery naturally finds every colocated `test {}` block.

3. **Move printGrid test back to `src/render.zig`.** Remove the workaround comment (lines 68-70) and restore colocated testing.

4. **Delete `src/tests.zig`.** With root.zig providing proper discovery, its three tests are handled:
   - "sanity" placeholder → removed
   - "references" dead-code-workaround → no longer needed (root.zig solves the import topology)
   - "printGrid" → moved back to render.zig

### What this does NOT cover

- Writing new functional tests. Those are per-issue TDD cycles. This is purely infrastructure hygiene.
- Any API or import changes to existing modules (cell, board, render). They remain untouched except for the printGrid test move in render.zig.

## Acceptance criteria

- [x] `src/root.zig` exists and re-exports cell, board, render as `pub const`
- [x] `build.zig` test step uses `.root_source_file = b.path("src/root.zig")` — no fake module indirection
- [x] All inline `test {}` blocks remain in their original source files (cell, board, render)
- [x] printGrid test lives in render.zig (moved back from tests.zig)
- [x] Dead-code-workaround "references" test removed entirely
- [x] Sanity placeholder test removed
- [x] Force-fail trap removed (already done this session)
- [x] `tests.zig` deleted
- [x] `zig build test` discovers and runs all colocated tests with zero warnings
- [x] Zero new imports or API changes to existing modules

## Blocked by

(none — foundational prerequisite)

## Work Done

Work completed this session:
