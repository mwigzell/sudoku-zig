const std = @import("std");
const ascii_renderer = @import("ascii/ascii_renderer.zig");
const styler = @import("ascii/styler.zig");
const input_source = @import("../input_source.zig");
const facade = @import("facade.zig");
const board = @import("../board.zig");
const legend = @import("legend.zig");
const command = @import("../command.zig");

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


    /// Static factory — allocates writer, styler, renderer, creates context
    /// struct, wires vtable pointers, returns Facade.
    pub fn makeFacade(is: input_source.ReaderSource, alloc: std.mem.Allocator, io: std.Io) facade.Error!facade.Facade {
        return if (is.isMock()) mockBranch(is, alloc, io) else prodBranch(is, alloc, io);
    }

    /// Production branch: File.Writer + AnsiStyler + Ansi renderer
    fn prodBranch(is: input_source.ReaderSource, alloc: std.mem.Allocator, io: std.Io) facade.Error!facade.Facade {
        const file_writer_ptr = alloc.create(std.Io.File.Writer) catch return facade.Error.System;
        file_writer_ptr.* = std.Io.File.stdout().writer(io, &.{});
        file_writer_ptr.interface.print("\x1b[2J\x1b[H", .{}) catch return facade.Error.System;

        const styler_ptr = alloc.create(styler.AnsiStyler) catch return facade.Error.System;
        styler_ptr.* = styler.AnsiStyler{};

        const R = ascii_renderer.AsciiRenderer(styler.AnsiStyler);
        const renderer_ptr = alloc.create(R) catch return facade.Error.System;
        renderer_ptr.* = R.init(alloc, io, &file_writer_ptr.interface, styler_ptr, is);

        const ctx = ProdFacadeContext{
            .allocator = alloc,
            .writer = file_writer_ptr,
            .styler = styler_ptr,
            .renderer = renderer_ptr,
        };

        const ctx_ptr = alloc.create(ProdFacadeContext) catch return facade.Error.System;
        ctx_ptr.* = ctx;

        return facade.Make(ProdFacadeContext).make(ctx_ptr);
    }
    // --- Mock branch ---

    fn mockBranch(is: input_source.ReaderSource, alloc: std.mem.Allocator, io: std.Io) facade.Error!facade.Facade {
        const aw_ptr = alloc.create(std.Io.Writer.Allocating) catch return facade.Error.System;
        aw_ptr.* = std.Io.Writer.Allocating.init(alloc);

        const styler_ptr = alloc.create(styler.PlainStyler) catch return facade.Error.System;
        styler_ptr.* = styler.PlainStyler{};

        const R = ascii_renderer.AsciiRenderer(styler.PlainStyler);
        const renderer_ptr = alloc.create(R) catch return facade.Error.System;
        renderer_ptr.* = R.init(alloc, io, &aw_ptr.writer, styler_ptr, is);

        const ctx = MockFacadeContext{
            .allocator = alloc,
            .writer = aw_ptr,
            .styler = styler_ptr,
            .renderer = renderer_ptr,
        };

        const ctx_ptr = alloc.create(MockFacadeContext) catch return facade.Error.System;
        ctx_ptr.* = ctx;

        return facade.Make(MockFacadeContext).make(ctx_ptr);
    }

};

/// Holds allocator, writer, styler and renderer pointers for production mode.
pub const ProdFacadeContext = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.File.Writer,
    styler: *styler.AnsiStyler,
    renderer: *ascii_renderer.AsciiRenderer(styler.AnsiStyler),

    pub fn deinit(self: *@This()) void {
        self.renderer.deinit();
        const alloc = self.allocator;
        alloc.destroy(self.writer);
        alloc.destroy(self.styler);
        alloc.destroy(self.renderer);
        alloc.destroy(self);
    }

    /// Pass-through methods for Facade vtable wrappers.

    pub fn render(self: *@This(), view: board.Board.BoardView, status_msg: ?[]const u8) facade.Error!void {
        self.renderer.render(view, status_msg) catch return facade.Error.System;
    }

    pub fn showLegend(self: *@This(), commands: legend.Legend) facade.Error!void {
        self.renderer.showLegend(commands) catch return facade.Error.System;
    }

    pub fn showError(self: *@This(), msg: []const u8) facade.Error!void {
        return self.renderer.showError(msg);
    }

    pub fn getCommandInput(self: *@This(), names: []const []const u8) facade.Error!command.ParseCommandResult {
        return self.renderer.getCommandInput(names);
    }
};

/// Holds allocator, writer, styler and renderer pointers for mock/test mode.
pub const MockFacadeContext = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer.Allocating,
    styler: *styler.PlainStyler,
    renderer: *ascii_renderer.AsciiRenderer(styler.PlainStyler),

    pub fn deinit(self: *@This()) void {
        self.writer.deinit();
        self.renderer.deinit();
        const alloc = self.allocator;
        alloc.destroy(self.writer);
        alloc.destroy(self.styler);
        alloc.destroy(self.renderer);
        alloc.destroy(self);
    }

    /// Pass-through methods for Facade vtable wrappers.

    pub fn render(self: *@This(), view: board.Board.BoardView, status_msg: ?[]const u8) facade.Error!void {
        self.renderer.render(view, status_msg) catch return facade.Error.System;
    }

    pub fn showLegend(self: *@This(), commands: legend.Legend) facade.Error!void {
        self.renderer.showLegend(commands) catch return facade.Error.System;
    }

    pub fn showError(self: *@This(), msg: []const u8) facade.Error!void {
        return self.renderer.showError(msg);
    }

    pub fn getCommandInput(self: *@This(), names: []const []const u8) facade.Error!command.ParseCommandResult {
        return self.renderer.getCommandInput(names);
    }
};
test "Prod/MockFacadeContext deinit releases child pointers without leak" {
    const alloc = std.testing.allocator;

    // --- Prod context ---
    const file_writer_ptr = alloc.create(std.Io.File.Writer) catch unreachable;
    file_writer_ptr.* = std.Io.File.stdout().writer(std.testing.io, &.{});

    const styler_ptr = alloc.create(styler.AnsiStyler) catch unreachable;
    styler_ptr.* = styler.AnsiStyler{};

    const AnsiR = ascii_renderer.AsciiRenderer(styler.AnsiStyler);
    const renderer_ptr = alloc.create(AnsiR) catch unreachable;
    renderer_ptr.* = AnsiR.init(
        alloc,
        std.testing.io,
        &file_writer_ptr.interface,
        styler_ptr,
        .{ .stdin = input_source.StdinSource.initStdin(alloc) },
    );

    const prod_ctx = alloc.create(ProdFacadeContext) catch unreachable;
    prod_ctx.* = ProdFacadeContext{
        .allocator = alloc,
        .writer = file_writer_ptr,
        .styler = styler_ptr,
        .renderer = renderer_ptr,
    };
    prod_ctx.deinit();

    // --- Mock context ---
    const aw_ptr = alloc.create(std.Io.Writer.Allocating) catch unreachable;
    aw_ptr.* = std.Io.Writer.Allocating.init(alloc);

    const plain_styler_ptr = alloc.create(styler.PlainStyler) catch unreachable;
    plain_styler_ptr.* = styler.PlainStyler{};

    const PlainR = ascii_renderer.AsciiRenderer(styler.PlainStyler);
    const plain_renderer_ptr = alloc.create(PlainR) catch unreachable;
    plain_renderer_ptr.* = PlainR.init(
        alloc,
        std.testing.io,
        &aw_ptr.writer,
        plain_styler_ptr,
        .{ .stdin = input_source.StdinSource.initStdin(alloc) },
    );
    const mock_ctx = alloc.create(MockFacadeContext) catch unreachable;
    mock_ctx.* = MockFacadeContext{
        .allocator = alloc,
        .writer = aw_ptr,
        .styler = plain_styler_ptr,
        .renderer = plain_renderer_ptr,
    };
    mock_ctx.deinit();
}

test "AsciiRendererAlloc.makeFacade returns Facade" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const responses = [_][]const u8{};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var facade_result = AsciiRendererAlloc.makeFacade(source, alloc, io) catch return error.Test;
    facade_result.deinit();
}
