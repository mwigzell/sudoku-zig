# Issue 43 - Next Steps (2026-08-13)

## Completed ✅

- **Step 1:** root.zig test tuple now includes all 15+ previously missing modules (sudoku, mutation_history, disambiguate, legend, path, fill, clear_command, undo_command, redo_command, quit_command, save_command, save_as_command, open_command, new_command, input_source). Uncommitted.
- **Step 5:** `allocatorForTest()` field reference fixed from `testing_allocator` → `allocator`. Uncommitted.
- **Bonus:** `readline()` body was missing its closing brace — doc comment was being parsed inside the function. Fixed. Uncommitted.
- Reverted broken sudoku.zig and main.zig edits to clean state via git checkout.

## Remaining: Fix buildFacade (sudoku.zig lines 21-42)

### The One Bug

`buildFacade()` sets `renderer.allocator = arena`. When MockSource returns a `std.testing.allocator` slice, renderer calls `self.allocator.free(raw)` → arena frees testing memory → GPF.

**Fix inside buildFacade only — keep init with 4 args `(cfg, is, comptime Styler: type, io)`:**

1. Get allocator from source: `const alloc = is.allocatorForTest();`
2. Use that as renderer's internal allocator: `R.init(alloc, ...)`
3. Allocate styler on arena (currently on stack — dangling pointer risk):
   ```zig
   const styler_ptr = arena.allocator().create(S) catch return error.System;
   styler_ptr.* = S{};
   ```
4. Rest of buildFacade unchanged (arena-allocated writer, renderer_ptr, etc.)

### Impact on Tests vs Production

- **Tests:** MockSource allocator = std.testing.allocator → renderer frees MockSource strings via testing allocator ✓
- **Production:** StdinSource allocator = page_allocator → renderer frees stdin strings via page allocator ✓

No split inits needed. No `initReal`. One fix, one place.

### Expected Result

All 8 crashed e2e tests pass → full suite 214/214.
