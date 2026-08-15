triage: ready-for-human

Facade deinit — AsciiRendererAlloc as a tagged union of two structs

## Problem

`buildFacade` allocates three heap pointers that are never freed on `Sudoku.deinit()`:
1. Writer container (`*Io.File.Writer` or `*Io.Writer.Allocating`)
2. Styler (`AnsiStyler` | `PlainStyler`)
3. Renderer instance itself (`*AsciiRenderer(StylerType)`)

The original design used `*anyopaque` pointers for writer/styler but Zig's `allocator.destroy()` can't work on opaque — it needs compile-time type info via `@sizeOf()`.

## Design: Single Tagged Union of Two Structs

One union, two variants — each variant is a struct carrying all the pointers for that mode. A single `deinit()` switches on the tag and frees everything.

```zig
const RenderMode = enum { prod, mock };

pub const AsciiRendererAlloc = struct {
    allocator: std.mem.Allocator,
    handles: Handles,

    const Handles = union(RenderMode) {
        prod: ProdHandles,
        mock: MockHandles,
    };

    const ProdHandles = struct {
        writer: *std.Io.File.Writer,
        styler: *styler.AnsiStyler,
        renderer: *ascii_renderer.AsciiRenderer(styler.AnsiStyler),
    };

    const MockHandles = struct {
        writer: *std.Io.Writer.Allocating,
        styler: *styler.PlainStyler,
        renderer: *ascii_renderer.AsciiRenderer(styler.PlainStyler),
    };

    pub fn deinit(self: *@This()) void {
        switch (self.handles) {
            .prod => |*h| {
                self.allocator.destroy(h.writer);
                self.allocator.destroy(h.styler);
                self.allocator.destroy(h.renderer);
            },
            .mock => |*h| {
                h.writer.deinit(); // free internal buffer before destroy
                self.allocator.destroy(h.writer);
                self.allocator.destroy(h.styler);
                self.allocator.destroy(h.renderer);
            },
        }
    };
};
```

Single union, two leaf structs. The tag disambiguates which set of concrete types to destroy. `Io.Writer.Allocating` needs `.deinit()` before `destroy()` to release its internal buffer.

### Steps

| Step | Description | Status |
|------|-------------|--------|
| 1 | Define `AsciiRendererAlloc` struct — union of `ProdHandles` / `MockHandles` with concrete pointers + `deinit()` | Pending |
| 2 | Wire it in: `buildFacade` returns `(facade.Facade, *AsciiRendererAlloc)`, `Sudoku.init()` assigns both, `deinit()` wired in | Pending |
| 3 | Full suite passes under SafeAllocator — zero leaks | Pending |

### Acceptance Criteria

- [ ] All e2e tests pass under SafeAllocator with zero leak warnings
- [ ] Production path (AnsiStyler + File.Writer) freed correctly
- [ ] One call from Sudoku.deinit() cascades everything down cleanly
- [ ] No `*anyopaque` remaining in AsciiRendererAlloc
