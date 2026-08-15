const std = @import("std");
const ascii_renderer = @import("ascii/ascii_renderer.zig");
const styler = @import("ascii/styler.zig");

/// Tag to distinguish the two renderer allocation modes.
const RenderMode = enum { prod, mock };

/// Owns the three heap pointers created by buildFacade (writer, styler, renderer)
/// and releases them on deinit. A tagged union disambiguates which concrete types
/// to destroy — no *anyopaque guesswork needed.
pub const AsciiRendererAlloc = struct {
    allocator: std.mem.Allocator,
    handles: Handles,

    const AnsiRenderer = ascii_renderer.AsciiRenderer(styler.AnsiStyler);
    const PlainRenderer = ascii_renderer.AsciiRenderer(styler.PlainStyler);

    /// Concrete pointer sets for each renderer mode.
    const Handles = union(RenderMode) {
        prod: ProdHandles,
        mock: MockHandles,
    };

    pub const ProdHandles = struct {
        writer: *std.Io.File.Writer,
        styler: *styler.AnsiStyler,
        renderer: *AnsiRenderer,
    };

    pub const MockHandles = struct {
        writer: *std.Io.Writer.Allocating,
        styler: *styler.PlainStyler,
        renderer: *PlainRenderer,
    };

    /// Free all heap allocations. Io.Writer.Allocating needs .deinit() before
    /// destroy to release its internal buffer; File.Writer is POD and just needs destroy.
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
    }
};

/// Holds allocator, writer, styler and renderer pointers for production mode.
pub const ProdFacadeContext = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.File.Writer,
    styler: *styler.AnsiStyler,
    renderer: *ascii_renderer.AsciiRenderer(styler.AnsiStyler),

    pub fn freeAll(self: *@This()) void {
        const alloc = self.allocator;
        alloc.destroy(self.writer);
        alloc.destroy(self.styler);
        alloc.destroy(self.renderer);
        alloc.destroy(self);
    }
};

/// Holds allocator, writer, styler and renderer pointers for mock/test mode.
pub const MockFacadeContext = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer.Allocating,
    styler: *styler.PlainStyler,
    renderer: *ascii_renderer.AsciiRenderer(styler.PlainStyler),

    pub fn freeAll(self: *@This()) void {
        const alloc = self.allocator;
        self.writer.deinit();
        alloc.destroy(self.writer);
        alloc.destroy(self.styler);
        alloc.destroy(self.renderer);
        alloc.destroy(self);
    }
};
test "Prod/MockFacadeContext freeAll releases child pointers without leak" {
    const alloc = std.testing.allocator;

    // --- Prod context ---
    const file_writer_ptr = alloc.create(std.Io.File.Writer) catch unreachable;
    file_writer_ptr.* = std.Io.File.stdout().writer(std.testing.io, &.{});

    const styler_ptr = alloc.create(styler.AnsiStyler) catch unreachable;
    styler_ptr.* = styler.AnsiStyler{};

    const AnsiR = ascii_renderer.AsciiRenderer(styler.AnsiStyler);
    const renderer_ptr = alloc.create(AnsiR) catch unreachable;

    const prod_ctx = alloc.create(ProdFacadeContext) catch unreachable;
    prod_ctx.* = ProdFacadeContext{
        .allocator = alloc,
        .writer = file_writer_ptr,
        .styler = styler_ptr,
        .renderer = renderer_ptr,
    };
    prod_ctx.freeAll();

    // --- Mock context ---
    const aw_ptr = alloc.create(std.Io.Writer.Allocating) catch unreachable;
    aw_ptr.* = std.Io.Writer.Allocating.init(alloc);

    const plain_styler_ptr = alloc.create(styler.PlainStyler) catch unreachable;
    plain_styler_ptr.* = styler.PlainStyler{};

    const PlainR = ascii_renderer.AsciiRenderer(styler.PlainStyler);
    const plain_renderer_ptr = alloc.create(PlainR) catch unreachable;

    const mock_ctx = alloc.create(MockFacadeContext) catch unreachable;
    mock_ctx.* = MockFacadeContext{
        .allocator = alloc,
        .writer = aw_ptr,
        .styler = plain_styler_ptr,
        .renderer = plain_renderer_ptr,
    };
    mock_ctx.freeAll();
}
