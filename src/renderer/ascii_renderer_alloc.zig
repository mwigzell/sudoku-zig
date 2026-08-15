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

    /// Concrete pointer sets for each renderer mode.
    const Handles = union(RenderMode) {
        prod: ProdHandles,
        mock: MockHandles,
    };

    pub const ProdHandles = struct {
        writer: *std.Io.File.Writer,
        styler: *styler.AnsiStyler,
        renderer: *ascii_renderer.AsciiRenderer(styler.AnsiStyler),
    };

    pub const MockHandles = struct {
        writer: *std.Io.Writer.Allocating,
        styler: *styler.PlainStyler,
        renderer: *ascii_renderer.AsciiRenderer(styler.PlainStyler),
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
    };
};
