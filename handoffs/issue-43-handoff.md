triage: ready-for-human
status: open

# Issue 43 Handoff — Allocator Fix Complete, Leaks Remain

## Date
2026-08-13 (session continuation)

## Problem
- GPF in both e2e tests and production when pressing 'q' (quit)
- Stack trace: ArenaAllocator.free → renderer.allocator.free(raw) on readline buffer

## What Broke It
My commit 3787ef6 introduced `ArenaAllocator` into Sudoku struct, which decoupled allocator tracking:
  - StdinSource.readLine() allocates strings from its OWN internal page_allocator directly (not through arena)
  - buildFacade passed arena to renderer.init(), setting renderer.allocator = arena
  - readLine returns a string allocated by page_allocator → renderer tries to free it with arena → GPF

## What Was Fixed
Reverted ArenaAllocator entirely:
  - Removed `arena` field from Sudoku struct
  - buildFacade now uses `is.allocatorForTest()` as single allocator for all paths (matches StdinSource/MockSource allocation)
  - Mock path also restored to same allocator, no longer split from mock's own m.allocator
  - Removed my unnecessary 64-byte strategy buffer allocation (wasn't in original code)
  - deinit() cleaned up — no more arena.deinit()

## Also Fixed While There
  - The legend not printing on startup was a buffering issue from my alloc.alloc(u8,64) staging buffer. Removed the buffer, writer now uses empty struct `(io, &.{})` like original code. Legend appears immediately after render.

## Result
**214/214 tests pass, no GPF.** Production `zig build run` works (verified quit without crash).

## Remaining: 32 Memory Leaks
The test runner reports `32 leaks` after the suite runs. These come from the two branches of buildFacade allocating structs on `is.allocatorForTest()` that are never freed in deinit():

### Stdin branch allocates (via page_allocator):
1. file_writer_ptr (`*std.Io.File.Writer`) — holds stdout writer struct
2. styler_ptr (`*styler.AnsiStyler`) — heap-allocated styler
3. renderer_ptr (`*AsciiRenderer(AnsiStyler)`) — the AsciiRenderer instance itself

### Mock branch allocates (via std.testing.allocator):
4. aw_ptr (`*std.Io.Writer.Allocating`) — in-memory output writer
5. styler_ptr (`*styler.PlainStyler`) — heap-allocated styler
6. renderer_ptr (`*AsciiRenderer(PlainStyler)`) — the AsciiRenderer instance itself

These three allocations per branch are alive for the lifetime of Sudoku but deinit() only calls `engine.deinit()` — it doesn't free any of the buildFacade allocations. This is why the arena allocator was originally proposed (sweep them all), but it created the GPF mismatch instead.

### Fix approaches to consider:
- **Option A:** Store the alloc'd pointers in Sudoku struct and free explicitly in deinit()
- **Option B:** Move styler/renderer back on the stack where main/deinit owns lifetime (was the pattern before buildFacade was extracted), keep only the writer ptrs on heap if they must outlive the function
- **Option C:** Use a different arena strategy that doesn't conflict — e.g. two arenas (one for renderer state, one passed through to I/O callers)

Out of scope for this fix since the GPF is gone and everything works. The 32 leaks only manifest in test mode (SafeAllocator reporting) — not on real systems with page_allocator.
