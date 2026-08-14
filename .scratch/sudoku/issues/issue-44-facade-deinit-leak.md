triage: ready-for-agent

## Facade deinit — free leaked writer, styler, renderer pointers

`buildFacade` allocates three heap pointers that are never freed on `Sudoku.deinit()`:
1. Writer container (`*Io.File.Writer` or `*Io.Writer.Allocating`)
2. Styler (`*StylerType`)
3. Renderer instance itself (`*AsciiRenderer(T)`)

### Design: AsciiRendererAlloc container with opaque pointers

The three allocations are owned by `buildFacade` / `Sudoku`, not the renderer. The renderer's `deinit()` should only clean up its own internals (e.g. `last_filename`). A **holder struct** at Sudoku level owns and frees the heap allocations.

```zig
/// Holds the three heap allocations from buildFacade as opaque pointers.
/// Named AsciiRendererAlloc because this pattern is specific to how AsciiRenderer
/// constructs its internals — other renderer backends must not inherit this shape.
/// Stored on Sudoku as `?*AsciiRendererAlloc` (nullable pointer) so future renderers opt in, not out.
pub const AsciiRendererAlloc = struct {
    writer: *anyopaque,   // Io.File.Writer | Io.Writer.Allocating
    styler: *anyopaque,  // AnsiStyler | PlainStyler
    renderer: *anyopaque, // AsciiRenderer(StylerType)

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.destroy(self.styler);
        allocator.destroy(self.writer);
        allocator.destroy(self.renderer);
    }
};
```

Sudoku stores `ascii_renderer_alloc: ?*AsciiRendererAlloc` — a nullable pointer because this ownership pattern is specific to how AsciiRenderer is built, not universal. A future WASM renderer won't care about it.

### Facade deinit still cascades to renderer internals

Steps 1–2 (Facade `deinit_fn` vtable + `deinit_wrapper`) remain correct and needed — the WASM renderer also needs that path for its own cleanup. The wrapper calls `AsciiRenderer.deinit()` which only frees `last_filename`. It does **not** destroy `self` — that's handled by `AsciiRendererAlloc.deinit()`.

### Steps:

| Step | Status |
|------|--------|
| 1: Add `deinit_fn` field to Facade + public `Facade.deinit()` dispatcher | ✅ Done |
| 2: Add `deinit_wrapper` to Make(CT), wire into `make()`, remove `allocator.destroy(self)` from wrapper (ownership moves to AsciiRendererAlloc) | ✅ Done |
| 3: Remove styler destroy from AsciiRenderer.deinit() — renderer internals only | ✅ Redone (styler removed) |
| 4: Create `AsciiRendererAlloc` in sudoku.zig with opaque pointers; rewrite `buildFacade` to return one; store as nullable pointer on Sudoku struct; wire `AsciiRendererAlloc.deinit()` into `Sudoku.deinit()` before engine cleanup | **Ready** |
| 5: Full suite passes under SafeAllocator — zero leaks | Pending |

### Acceptance Criteria (current)

- Steps 1–3 done ✅
- Step 4 pending
- Step 5 pending

### Remaining Acceptance Criteria
- [ ] All e2e tests pass under SafeAllocator with zero leak warnings
- [ ] Production path (AnsiStyler + File.Writer) also freed correctly
- [ ] One call from Sudoku.deinit() cascades everything down via AsciiRendererAlloc

