const std = @import("std");
const ascii_renderer = @import("ascii/ascii_renderer.zig");
const styler = @import("ascii/styler.zig");
const input_source = @import("../input_source.zig");
const facade = @import("facade.zig");
const board = @import("../board.zig");
const legend = @import("legend.zig");
const command = @import("../command.zig");
const io_session = @import("../io_session.zig");

pub const AsciiRendererAlloc = struct {
    /// Static factory — allocates styler + renderer, creates context struct,
    /// wires vtable pointers, returns Facade. The prod path borrows the
    /// session's writer; the mock path owns its own (chunk 4 moves it into the session).
    pub fn makeFacade(session: *io_session.IoSession) facade.Error!facade.Facade {
        return if (session.reader.isMock()) mockBranch(session) else prodBranch(session);
    }
    /// Shared body of both branches: allocate styler, renderer and context,
    /// wire them, and return the facade (the facade's deinit destroys all three).
    fn buildContext(
        S: type,
        Ctx: type,
        session: *io_session.IoSession,
    ) facade.Error!facade.Facade {
        const alloc = session.alloc;
        const writer = session.writer.writer();
        const styler_ptr = alloc.create(S) catch return facade.Error.System;
        styler_ptr.* = S{};
        const R = ascii_renderer.AsciiRenderer(S);
        const renderer_ptr = alloc.create(R) catch return facade.Error.System;
        renderer_ptr.* = R.init(alloc, writer, styler_ptr, session.reader);

        const ctx = Ctx{
            .allocator = alloc,
            .writer = writer,
            .styler = styler_ptr,
            .renderer = renderer_ptr,
        };
        const ctx_ptr = alloc.create(Ctx) catch return facade.Error.System;
        ctx_ptr.* = ctx;

        return facade.Make(Ctx).make(ctx_ptr);
    }

    /// Production branch: AnsiStyler.
    fn prodBranch(session: *io_session.IoSession) facade.Error!facade.Facade {
        return buildContext(styler.AnsiStyler, ProdFacadeContext, session);
    }

    /// Mock branch: PlainStyler.
    fn mockBranch(session: *io_session.IoSession) facade.Error!facade.Facade {
        return buildContext(styler.PlainStyler, MockFacadeContext, session);
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
    writer: *std.Io.Writer, // session-borrowed; session.deinit() owns the buffer
    styler: *styler.PlainStyler,
    renderer: *ascii_renderer.AsciiRenderer(styler.PlainStyler),

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
    var aw = std.Io.Writer.Allocating.init(alloc); // test-owned now; context only borrows
    defer aw.deinit();

    const plain_styler_ptr = alloc.create(styler.PlainStyler) catch unreachable;
    plain_styler_ptr.* = styler.PlainStyler{};

    const PlainR = ascii_renderer.AsciiRenderer(styler.PlainStyler);
    const plain_renderer_ptr = alloc.create(PlainR) catch unreachable;
    plain_renderer_ptr.* = PlainR.init(
        alloc,
        &aw.writer,
        plain_styler_ptr,
        .{ .stdin = input_source.StdinSource.initStdin(alloc, std.testing.io) },
    );
    const mock_ctx = alloc.create(MockFacadeContext) catch unreachable;
    mock_ctx.* = MockFacadeContext{
        .allocator = alloc,
        .writer = &aw.writer,
        .styler = plain_styler_ptr,
        .renderer = plain_renderer_ptr,
    };
    mock_ctx.deinit();
}

test "AsciiRendererAlloc.makeFacade returns Facade" {
    const alloc = std.testing.allocator;
    const responses = [_][]const u8{};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var facade_result = AsciiRendererAlloc.makeFacade(&session) catch return error.Test;
    facade_result.deinit();
}
test "integrated e2e - prodBranch renders real grid into in-memory writer" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // A non-mock source routes to prodBranch; .mock writer tag keeps
    // content observable without touching real stdout.
    var session = io_session.IoSession{
        .reader = .{ .stdin = input_source.StdinSource.initStdin(alloc, io) },
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var fac = try AsciiRendererAlloc.makeFacade(&session);
    defer fac.deinit();

    const b = board.Board.init();
    try fac.render(b.asView(), null);

    const contents = std.Io.Writer.buffered(&session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "A B C │ D E F │ G H I") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "╰───────┴───────┴───────╯") != null);
}

test "integrated e2e - prodBranch showLegend writes into session writer buffer" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Non-mock reader routes to prodBranch; showLegend is the one prod
    // method with no input side, so the .mock writer tag makes its output
    // observable without touching real stdout. (showError/getCommandInput
    // read via StdinSource — untestable on the prod context by design.)
    var session = io_session.IoSession{
        .reader = .{ .stdin = input_source.StdinSource.initStdin(alloc, io) },
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var fac = try AsciiRendererAlloc.makeFacade(&session);
    defer fac.deinit();

    const commands = legend.Legend{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .save = false,
        .open = false,
        .new = false,
        .save_as = false,
    };
    try fac.showLegend(commands);

    const contents = std.Io.Writer.buffered(&session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Command: (F)ill") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(C)lear") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(Q)uit") != null);
    // Disabled flags must not surface — Legend drives the seam, not the renderer.
    try std.testing.expect(std.mem.indexOf(u8, contents, "(U)ndo") == null);
}
