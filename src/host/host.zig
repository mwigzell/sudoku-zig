// Host: the per-process substrate — supplies the renderer session and
// materializes the Facade for the configured renderer preference.
// Prod supplies real (io, alloc); the test entry provides std.testing internally (see createForTest). No renderer knowledge lives in Sudoku.
const std = @import("std");
const config = @import("../config.zig");
const facade_mod = @import("../renderer/facade.zig");
const io_session = @import("../io_session.zig");
const input_source = @import("../input_source.zig");
const command = @import("../command.zig");
const cell = @import("../board/cell.zig");
const AsciiRendererAlloc = @import("../renderer/ascii_renderer_alloc.zig").AsciiRendererAlloc;
const game_engine = @import("../engine/game_engine.zig");
const puzzle_gen = @import("../puzzle_gen.zig");

// ────────────────────── co-located tests ──────────────────────
pub const Host = struct {
    pub const Error = error{ System, UnsupportedRenderer, NoFallbackConfigured };

    cfg: config.Config,
    io: std.Io,
    alloc: std.mem.Allocator,

    /// Canned input for the test entry; null in production.
    test_responses: ?[]const []const u8 = null,

    /// True once the terminal session has been built — lazy, terminal arms only.
    have_session: bool = false,

    session: io_session.IoSession = undefined,

    /// Prod entry: the terminal arm builds real stdin from io + a real stdout writer.
    pub fn create(cfg: config.Config, io: std.Io, alloc: std.mem.Allocator) @This() {
        return .{ .cfg = cfg, .io = io, .alloc = alloc };
    }

    /// Test entry: canned responses in, owned mock buffer out. Tests never see
    /// the reader/writer unions behind the host.
    pub fn createForTest(cfg: config.Config, responses: []const []const u8) @This() {
        return .{
            .cfg = cfg,
            .io = std.testing.io,
            .alloc = std.testing.allocator,
            .test_responses = responses,
        };
    }

    /// Materialize the facade for the configured preference: the preferred arm
    /// first, then the configured fallback; an unconfigured fallback is an error.
    pub fn facade(self: *Host) Error!facade_mod.Facade {
        return self.facadeFor(self.cfg.preferred_renderer) catch {
            const fallback = self.cfg.fallback_renderer orelse return error.NoFallbackConfigured;
            return self.facadeFor(fallback) catch return error.UnsupportedRenderer;
        };
    }

    /// Per-renderer substrate: build the terminal session or refuse the renderer.
    fn facadeFor(self: *Host, choice: config.RendererKind) Error!facade_mod.Facade {
        return switch (choice) {
            .ansi, .ascii => self.terminalFacade(choice),
            .tui => error.UnsupportedRenderer, // ncurses substrate not yet wired
            .wasm => error.UnsupportedRenderer, // JS-side substrate not yet wired
        };
    }

    /// Resolve the session lazily, then hand it to the renderer factory.
    fn terminalFacade(self: *Host, choice: config.RendererKind) Error!facade_mod.Facade {
        if (!self.have_session) self.openSession();
        return switch (choice) {
            .ansi => AsciiRendererAlloc.makeFacade(&self.session),
            .ascii => AsciiRendererAlloc.makePlainFacade(&self.session),
            else => unreachable,
        };
    }

    /// Build the terminal session exactly once: real stdin/stdout for the prod
    /// entry, or the canned mock reader + owned buffer for the test entry.
    fn openSession(self: *Host) void {
        self.session = if (self.test_responses) |responses| io_session.IoSession{
            .reader = .{ .mock = input_source.MockSource.init(self.alloc, responses) },
            .writer = .{ .mock = std.Io.Writer.Allocating.init(self.alloc) },
            .alloc = self.alloc,
        } else io_session.IoSession{
            .reader = .{ .stdin = input_source.StdinSource.initStdin(self.alloc, self.io) },
            .writer = .{ .stdout = std.Io.File.stdout().writer(self.io, &.{}) },
            .alloc = self.alloc,
        };
        self.have_session = true;
    }

    /// Release the session if one was built; facades own their own contexts.
    pub fn deinit(self: *Host) void {
        if (self.have_session) self.session.deinit();
    }
};

test "host: .tui preference, no fallback configured refuses facade without a session" {
    const cfg = config.Config{
        .difficulty = .easy,
        .preferred_renderer = .tui,
        .fallback_renderer = null,
        .log_level = .info,
    };
    var host = Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();

    try std.testing.expectError(Host.Error.NoFallbackConfigured, host.facade());
    try std.testing.expect(!host.have_session);
}

test "host: .wasm preference falls back to .ascii and yields a working facade" {
    const cfg = config.Config{
        .difficulty = .easy,
        .preferred_renderer = .wasm,
        .fallback_renderer = .ascii,
        .log_level = .info,
    };
    var host = Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();

    var f = try host.facade();
    defer f.deinit();

    try std.testing.expect(host.have_session);

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), std.testing.io);
    defer engine.deinit();
    try f.render(engine.eventBoard(), null);
}

test "host: createForTest .ascii preference yields a working facade" {
    const cfg = config.Config{
        .difficulty = .easy,
        .preferred_renderer = .ascii,
        .fallback_renderer = .ascii,
        .log_level = .info,
    };

    // Canned input: one valid command consumed through the parse seam.
    const responses = [_][]const u8{"fill A3 4"};
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();

    var f = try host.facade();
    defer f.deinit();

    // Working facade: renders a real board view without error
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), std.testing.io);
    defer engine.deinit();
    try f.render(engine.eventBoard(), null);

    // And the injected mock reader drives the command parse path:
    // "fill A3 4" must round-trip into the very fill command it denotes
    // (names = the set of commands offered to the parser; a lone "Fill" is unambiguous).
    const parsed = try f.getCommandInput(&.{"Fill"});
    switch (parsed) {
        .error_msg => return error.ExpectedValidParse,
        .valid => |c| {
            try std.testing.expectEqual(
                command.Command{ .fill = command.FillData{ .row = 2, .col = 0, .digit = cell.CellValue.four } },
                c,
            );
        },
    }
}

test "host: .tui preference falls back to .ascii and yields a working facade" {
    const cfg = config.Config{
        .difficulty = .easy,
        .preferred_renderer = .tui,
        .fallback_renderer = .ascii,
        .log_level = .info,
    };
    var host = Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();

    var f = try host.facade();
    defer f.deinit();

    try std.testing.expect(host.have_session);

    // Working fallback facade renders a real board view through its session.
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), std.testing.io);
    defer engine.deinit();
    try f.render(engine.eventBoard(), null);
}

test "host: both arms unsupported errors without building a terminal session" {
    const cfg = config.Config{
        .difficulty = .easy,
        .preferred_renderer = .wasm,
        .fallback_renderer = .tui,
        .log_level = .info,
    };
    var host = Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();

    try std.testing.expectError(Host.Error.UnsupportedRenderer, host.facade());
    try std.testing.expect(!host.have_session);
}

test "host: no fallback configured yields NoFallbackConfigured" {
    const cfg = config.Config{
        .difficulty = .easy,
        .preferred_renderer = .wasm,
        .fallback_renderer = null,
        .log_level = .info,
    };
    var host = Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();

    try std.testing.expectError(Host.Error.NoFallbackConfigured, host.facade());
    try std.testing.expect(!host.have_session);
}
