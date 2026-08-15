const std = @import("std");
const ascii_renderer = @import("ascii/ascii_renderer.zig");
const styler = @import("ascii/styler.zig");
const input_source = @import("../input_source.zig");
const facade = @import("facade.zig");
const board = @import("../board.zig");
const legend = @import("legend.zig");
const command = @import("../command.zig");

pub const AsciiRendererAlloc = struct {
    /// Static factory — allocates styler + renderer, creates context struct,
    /// wires vtable pointers, returns Facade. The prod path borrows the
    /// caller-owned writer; the mock path ignores it.
    pub fn makeFacade(is: input_source.ReaderSource, alloc: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer) facade.Error!facade.Facade {
        return if (is.isMock()) mockBranch(is, alloc, io) else prodBranch(is, alloc, io, writer);
    }
    /// Production branch: caller-owned writer + AnsiStyler + Ansi renderer
    fn prodBranch(is: input_source.ReaderSource, alloc: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer) facade.Error!facade.Facade {
        _ = io; // io is now captured inside StdinSource; signature kept until chunk 3 (IoSession)
        const styler_ptr = alloc.create(styler.AnsiStyler) catch return facade.Error.System;
        styler_ptr.* = styler.AnsiStyler{};

        const R = ascii_renderer.AsciiRenderer(styler.AnsiStyler);
        const renderer_ptr = alloc.create(R) catch return facade.Error.System;
        renderer_ptr.* = R.init(alloc, writer, styler_ptr, is);
        renderer_ptr.clearScreen() catch return facade.Error.System;

        const ctx = ProdFacadeContext{
            .allocator = alloc,
            .writer = writer,
            .styler = styler_ptr,
            .renderer = renderer_ptr,
        };

        const ctx_ptr = alloc.create(ProdFacadeContext) catch return facade.Error.System;
        ctx_ptr.* = ctx;

        return facade.Make(ProdFacadeContext).make(ctx_ptr);
    }
    // --- Mock branch ---

    fn mockBranch(is: input_source.ReaderSource, alloc: std.mem.Allocator, io: std.Io) facade.Error!facade.Facade {
        _ = io; // io is now captured inside StdinSource; signature kept until chunk 3 (IoSession)
        const aw_ptr = alloc.create(std.Io.Writer.Allocating) catch return facade.Error.System;
        aw_ptr.* = std.Io.Writer.Allocating.init(alloc);

        const styler_ptr = alloc.create(styler.PlainStyler) catch return facade.Error.System;
        styler_ptr.* = styler.PlainStyler{};

        const R = ascii_renderer.AsciiRenderer(styler.PlainStyler);
        const renderer_ptr = alloc.create(R) catch return facade.Error.System;
        renderer_ptr.* = R.init(alloc, &aw_ptr.writer, styler_ptr, is);

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
    writer: *std.Io.Writer, // caller-owned; not destroyed here
    styler: *styler.AnsiStyler,
    renderer: *ascii_renderer.AsciiRenderer(styler.AnsiStyler),

    pub fn deinit(self: *@This()) void {
        self.renderer.deinit();
        const alloc = self.allocator;
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
        &file_writer_ptr.interface,
        styler_ptr,
        .{ .stdin = input_source.StdinSource.initStdin(alloc, std.testing.io) },
    );

    const prod_ctx = alloc.create(ProdFacadeContext) catch unreachable;
    prod_ctx.* = ProdFacadeContext{
        .allocator = alloc,
        .writer = &file_writer_ptr.interface,
        .styler = styler_ptr,
        .renderer = renderer_ptr,
    };
    prod_ctx.deinit();
    alloc.destroy(file_writer_ptr); // caller-owned now, not deinit's job

    // --- Mock context ---
    const aw_ptr = alloc.create(std.Io.Writer.Allocating) catch unreachable;
    aw_ptr.* = std.Io.Writer.Allocating.init(alloc);

    const plain_styler_ptr = alloc.create(styler.PlainStyler) catch unreachable;
    plain_styler_ptr.* = styler.PlainStyler{};

    const PlainR = ascii_renderer.AsciiRenderer(styler.PlainStyler);
    const plain_renderer_ptr = alloc.create(PlainR) catch unreachable;
    plain_renderer_ptr.* = PlainR.init(
        alloc,
        &aw_ptr.writer,
        plain_styler_ptr,
        .{ .stdin = input_source.StdinSource.initStdin(alloc, std.testing.io) },
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

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var facade_result = AsciiRendererAlloc.makeFacade(source, alloc, io, &aw.writer) catch return error.Test;
    facade_result.deinit();
}
test "integrated e2e - prodBranch renders real grid into in-memory writer" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    // A non-mock source routes to prodBranch
    const source: input_source.ReaderSource = .{ .stdin = input_source.StdinSource.initStdin(alloc, io) };

    var fac = try AsciiRendererAlloc.makeFacade(source, alloc, io, &aw.writer);
    defer fac.deinit();

    const b = board.Board.init();
    try fac.render(b.asView(), null);

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "A B C │ D E F │ G H I") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "╰───────┴───────┴───────╯") != null);
}
