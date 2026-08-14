triage: ready-for-human


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
    allocator: std.mem.Allocator,  // stored inside; used by deinit()
    writer: *anyopaque,   // Io.File.Writer | Io.Writer.Allocating
    styler: *anyopaque,  // AnsiStyler | PlainStyler
    renderer: *anyopaque, // AsciiRenderer(StylerType)

    pub fn deinit(self: *@This()) void {
        self.allocator.destroy(self.writer);
        self.allocator.destroy(self.renderer);
        self.allocator.destroy(self.styler);
    }
};
```

Sudoku stores `rendererAlloc: ?*AsciiRendererAlloc` — no underscore prefix, nullable pointer because this ownership pattern is specific to AsciiRenderer.

### Facade deinit still cascades to renderer internals

The Facade `deinit_fn` vtable + `deinit_wrapper` are done and correct — both the ASCII and WASM renderer need that path for their own internal cleanup (e.g. `last_filename`). The wrapper calls `AsciiRenderer.deinit()` which only frees its internals. It does **not** destroy `self` — that's handled by `AsciiRendererAlloc.deinit()`

### Steps:

| Step | Status |
|------|--------|
| 1: `buildFacade` returns tuple `(facade.Facade, *AsciiRendererAlloc)` → `Sudoku.init()` assigns both | Pending |
| 2: Wire `Sudoku.deinit()` to call `rendererAlloc.?.deinit()` before `engine.deinit()` | Pending |
| 3: Full suite passes under SafeAllocator — zero leaks | Pending |

### Remaining Acceptance Criteria
- [ ] All e2e tests pass under SafeAllocator with zero leak warnings
- [ ] Production path (AnsiStyler + File.Writer) also freed correctly
- [ ] One call from Sudoku.deinit() cascades everything down via AsciiRendererAlloc

