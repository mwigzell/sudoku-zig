triage: ready-for-agent

## Facade deinit — free leaked writer, styler, renderer pointers

`buildFacade` allocates three heap pointers that are never freed on `Sudoku.deinit()`:
1. Writer (`*Io.File.Writer` or `*Io.Writer.Allocating`)
2. Styler (`*StylerType`)
3. Renderer instance itself (`*AsciiRenderer(T)`)

`AsciiRenderer.deinit()` only frees `last_filename`. The Facade has no deinit path.

### Solution: Add deinit vtable entry to Facade + wire it through

**Facade (facade.zig):** Add `deinit_fn` vtable pointer and a public `pub fn deinit(self: *Facade) void` that dispatches through it.

**Make(CT) (facade.zig):**
* Add `deinit_wrapper(ctx)` — casts context to `*T`, calls `self.deinit()` then `self.allocator.destroy(self)` for the renderer instance.
* Extend `make(instance)` to include `.deinit_fn = deinit_wrapper`.
* The writer and styler pointers are freed by `AsciiRenderer.deinit()` which already stores both fields and its allocator — extend it in that file below.

**AsciiRenderer (ascii_renderer.zig):** Extend existing `deinit(self)`:
1. Call `self.writer.deinit()` if the writer is a Writer.Allocating, or just free it. Since `writer` is `*Io.Writer`, use `self.allocator.destroy(self.writer)` to free the pointer itself.
2. Free styler: `self.allocator.destroy(self.styler)`.
3. Keep existing `last_filename` free.

**Sudoku (sudoku.zig):** Add one line to existing `deinit()`:
```zig
pub fn deinit(self: *@This()) void {
    self.renderer.deinit();  // cascade: writer, styler, renderer freed
    self.engine.deinit();
}
```

The WasM renderer (future) implements its own `deinit` the same way — one vtable entry.

### Steps

- [ ] Step 1: Add `deinit_fn` field to Facade struct + public `Facade.deinit()` dispatcher
- [ ] Step 2: Add `deinit_wrapper` to Make(CT), wire into `make()` return value
- [ ] Step 3: Extend AsciiRenderer.deinit() to destroy writer pointer and styler pointer
- [ ] Step 4: Add `self.renderer.deinit()` to Sudoku.deinit() before engine.deinit()
- [ ] Step 5: Full suite passes with SafeAllocator — no leaks

### Acceptance Criteria

- All e2e tests pass under SafeAllocator with zero leak warnings
- Production path (AnsiStyler + File.Writer) also freed correctly
- One call from Sudoku.deinit() cascades everything down
