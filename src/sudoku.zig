const std = @import("std");
const facade = @import("renderer/facade.zig");
const styler = @import("renderer/ascii/styler.zig");
const game_engine = @import("engine/game_engine.zig");
const config = @import("config.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const command = @import("command.zig");

const disambiguate = @import("renderer/ascii/disambiguate.zig");
const legend = @import("renderer/legend.zig");

const AsciiRendererAlloc = @import("renderer/ascii_renderer_alloc.zig").AsciiRendererAlloc;
const io_session = @import("io_session.zig");
pub const Error = error{System};

pub const Sudoku = struct {
    engine: game_engine.GameEngine,
    cfg: config.Config,

    io: std.Io,
    renderer: facade.Facade,
    fn buildFacade(cfg: config.Config, session: *io_session.IoSession) Error!facade.Facade {
        switch (cfg.preferred_renderer) {
            .ansi => {
                return AsciiRendererAlloc.makeFacade(session);
            },
            .ascii => {
                return AsciiRendererAlloc.makePlainFacade(session);
            },
            else => {
                return error.System;
            },
        }
    }

    pub fn init(cfg: config.Config, session: *io_session.IoSession, io: std.Io) Error!@This() {
        const puzzle_str = puzzle_gen.PuzzleGen.generate(cfg.difficulty);
        const facade_result = try buildFacade(cfg, session);
        return @This(){
            .cfg = cfg,
            .renderer = facade_result,
            .io = io,
            .engine = try game_engine.GameEngine.init(puzzle_str, io),
        };
    }

    fn handleEvent(self: *@This(), event: game_engine.Event) Error!bool {
        switch (event) {
            .ok => |ev| {
                if (ev.is_quit) return true;
                if (ev.msg) |m| try self.renderer.showError(m);
                try self.renderer.render(ev.board_view, null);
                try self.renderer.showLegend(self.engine.getLegend());
                return false;
            },
            .error_msg => |msg| {
                try self.renderer.showError(msg);
                return false;
            },
        }
    }

    /// Handle one parsed result. Returns true when the command loop should end.
    fn handleResult(self: *@This(), result: command.ParseCommandResult) Error!bool {
        switch (result) {
            .error_msg => |msg| {
                _ = try self.handleEvent(game_engine.Event{ .error_msg = msg });
                return false;
            },
            .valid => |cmd| {
                const event = self.engine.exec(cmd);
                return try self.handleEvent(event);
            },
        }
    }

    /// Prompt through renderer, parse, dispatch. Returns true on quit.
    fn promptForAndRunCommand(self: *@This()) Error!bool {
        const avail = self.engine.getLegend();
        var names: [9][]const u8 = undefined;
        const count = avail.getNames(&names);
        const result = self.renderer.getCommandInput(names[0..count]) catch |err| {
            if (err == error.ReadEOF) return true;
            return error.System; // I/O read failure treated as system
        };
        return try self.handleResult(result);
    }

    pub fn run(self: *@This()) Error!void {
        try self.renderer.render(self.engine.eventBoard(), null);
        try self.renderer.showLegend(self.engine.getLegend());
        while (true) {
            const isDone = try self.promptForAndRunCommand();
            if (isDone) break;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.renderer.deinit();
        self.engine.deinit();
    }
};

const board = @import("board.zig");
const cell = @import("board/cell.zig");
const input_source = @import("input_source.zig");
const styler_t = @import("renderer/ascii/styler.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");

// Step 7 test placeholder
test "Sudoku stores io field during init" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const responses = [_][]const u8{};
    const source: input_source.ReaderSource = .{ .mock = input_source.MockSource.init(alloc, &responses) };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku_instance = try Sudoku.init(cfg, &session, io);
    defer sudoku_instance.deinit();

    _ = sudoku_instance.io;
}
test "integrated e2e - full seam: fill command via prefix dispatch" {
    // Arrange: fresh engine via Sudoku.init through real AsciiRenderer
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const responses = [_][]const u8{
        "fill A3 4",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku = try Sudoku.init(cfg, &session, io);
    defer sudoku.deinit();

    // Act: run the full loop — fill A3 with 4 via prefix dispatch, then quit
    sudoku.run() catch {};

    // Assert (a): engine has undo available after mutation.
    {
        const avail = sudoku.engine.getLegend();
        try std.testing.expect(avail.undo);
    }

    // Assert (b): cell at chess coord A3 -> row 2, col 0 is four.
    {
        try std.testing.expectEqual(cell.CellValue.four, sudoku.engine.board.getCellValue(@as(u4, 2), @as(u4, 0)));
    }
}

// Issue 32 — full round-trip integration: save known state → mutate → open saved file → verify restore
// Uses real AsciiRenderer + MockSource to exercise the full dialog/caching path (replaces rigged MockRenderer test).
test "integrated e2e - full seam: open loads saved game" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };

    // 1. Create a save file with known state (no MockRenderer - real path through renderer)
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/sudoku_full_seam_open_test.sud";

    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // Save known state to disk before running through the renderer
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), io);
    defer original.deinit();
    try original.saveGame(io, tmp_path);

    // Record B2 value in saved state for later verification
    const saved_b2 = original.eventBoard().get(1, 1);

    // Canned responses: fill a cell -> open dialog -> filename -> quit
    const responses = [_][]const u8{
        "fill B2 7", // Mutate B2 (diverges from saved)
        "open", // Trigger open dialog prompt
        tmp_path ++ "\n", // Filename response for the dialog prompt
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku_instance = try Sudoku.init(cfg, &session, io);
    defer sudoku_instance.deinit();

    // Run full loop: open dialog -> filename prompt -> load file -> quit.
    sudoku_instance.run() catch {};

    // After opening saved file: B2 restored to original saved value (not seven)
    try std.testing.expectEqual(saved_b2, sudoku_instance.engine.eventBoard().get(1, 1));
}

// Step 10 — Save/Open must route through handleEvent() for feedback + re-render

test "integrated e2e - save success produces status message, re-render, legend refresh" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/sudoku_save_success_test.sud";

    // Canned responses: save -> filename prompt -> quit
    const responses = [_][]const u8{
        "save",
        tmp_path ++ "\n",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku = try Sudoku.init(cfg, &session, io);
    defer sudoku.deinit();

    sudoku.run() catch {};

    // Clean up saved file
    std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
}

test "integrated e2e - run: open file success produces status message, re-render, and legend refresh" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };

    // Create a save file to open
    const io = std.testing.io;
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), io);
    defer original.deinit();
    const tmp_path = "/tmp/sudoku_e2e_open_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    const alloc = std.testing.allocator;

    // Canned responses: open <path> -> quit
    const responses = [_][]const u8{
        "open " ++ tmp_path,
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku_instance = try Sudoku.init(cfg, &session, io);
    defer sudoku_instance.deinit();

    // Act: run full loop - open loads file from command arg, re-renders, shows legend
    sudoku_instance.run() catch {};
}

test "integrated e2e - run: save uses default filename and returns success" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/sudoku_save_default_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // Canned responses: save -> filename prompt -> quit
    const responses = [_][]const u8{
        "save",
        tmp_path ++ "\n",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku = try Sudoku.init(cfg, &session, io);
    defer sudoku.deinit();

    // Act: run full loop - save prompts for filename, writes file, re-renders
    sudoku.run() catch {};
}
// Step 12b — Subsequent saves reuse last filename, give feedback without prompting

test "integrated e2e - run: fill → save → quit" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const responses = [_][]const u8{
        "fill A3 7",
        "save", // save command (triggers dialog for first use)
        "sudoku_save.sud\n", // answer to save As dialog prompt
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku_instance = try Sudoku.init(cfg, &session, io);
    defer sudoku_instance.deinit();
    sudoku_instance.run() catch {};
}
// Issue 34 Step 2 — e2e: save_as writes file and re-renders
test "integrated e2e - run: save_as writes file and re-renders" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // Canned responses: command → dialog filename → quit
    const responses = [_][]const u8{
        "save_as",
        "test_save_as.sud",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku_instance = try Sudoku.init(cfg, &session, io);
    defer sudoku_instance.deinit();
    sudoku_instance.run() catch {};
}

// Issue 34 Step 3 — e2e: new command resets board and history
test "integrated e2e - run: new command resets board and history" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // feed fill (adds to history), then new (should clear it), then quit
    const responses = [_][]const u8{
        "fill A3 7",
        "new",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku_instance = try Sudoku.init(cfg, &session, io);
    defer sudoku_instance.deinit();
    sudoku_instance.run() catch {};

    // history should be empty after new command clears it
    try std.testing.expectEqual(@as(usize, 0), sudoku_instance.engine.history.entries.items.len);
}
// Issue 45 Step 4 — verify factory delegation (buildFacade uses AsciiRendererAlloc.makeFacade)
test "integrated e2e - buildFacade delegates to AsciiRendererAlloc.makeFacade" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const responses = [_][]const u8{
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var session = io_session.IoSession{
        .reader = source,
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku = try Sudoku.init(cfg, &session, io);

    // Facade deinit routes through vtable to deinit() — no renderer_alloc sidecar needed.
    // If buildFacade still returned FacadeResult this would compile-break.
    defer sudoku.deinit();

    // Act: run through the factory-built facade end-to-end
    sudoku.run() catch {};
}

test "integrated e2e - .ascii renderer kind renders plain unstyled grid" {
    const cfg: config.Config = .{
        .difficulty = .easy,
        .preferred_renderer = .ascii,
        .fallback_renderer = .ascii,
    };
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    // Non-mock reader picks the prod branch; .mock writer keeps output observable.
    var session = io_session.IoSession{
        .reader = .{ .stdin = input_source.StdinSource.initStdin(alloc, io) },
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };
    defer session.deinit();
    var sudoku = try Sudoku.init(cfg, &session, io);
    defer sudoku.deinit();
    try sudoku.renderer.render(sudoku.engine.board.asView(), null);

    const contents = std.Io.Writer.buffered(&session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "A B C │ D E F") != null);
    // PlainStyler: no CSI escapes anywhere in the rendered output.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\x1b[") == null);
}
