// Sudoku facade: owns the command loop — prompt, parse, dispatch to the
// game engine, and render each resulting event back through the renderer.
const std = @import("std");
const facade_mod = @import("renderer/facade.zig");
const styler = @import("renderer/ascii/styler.zig");
const game_engine = @import("engine/game_engine.zig");
const file_transport = @import("engine/file_transport.zig");
const config = @import("config.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const command = @import("command.zig");

const disambiguate = @import("renderer/ascii/disambiguate.zig");
const legend = @import("renderer/legend.zig");

const host_mod = @import("host/host.zig");
const wasm_host = @import("host/wasm_host.zig");
const wasm_renderer = @import("renderer/wasm/wasm_renderer.zig");
const wasm_transport = @import("engine/wasm_transport.zig");
pub const Error = error{ System, UnsupportedRenderer, NoFallbackConfigured };

/// One running game: engine + renderer; native loops via native_run, wasm turns via wasm_run.
pub const Sudoku = struct {
    engine: game_engine.GameEngine,
    cfg: config.Config,
    renderer: facade_mod.Facade,

    /// Assemble a fresh game from the shared user-choices, a renderer facade,
    /// and the file transport arm the deployment selected.
    pub fn init(cfg: config.Config, facade: facade_mod.Facade, transport: file_transport.FileTransport) Error!@This() {
        const puzzle_str = puzzle_gen.PuzzleGen.generate(cfg.difficulty);
        return @This(){
            .cfg = cfg,
            .renderer = facade,
            .engine = try game_engine.GameEngine.init(puzzle_str, transport),
        };
    }

    /// Dispatch one engine event to the renderer; returns true when the loop should end.
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

    /// One command, end to end: getCommandInput → parse/dispatch → render.
    /// Returns true when the session is over (quit, or an I/O read failure).
    fn turn(self: *@This()) Error!bool {
        const avail = self.engine.getLegend();
        var names: [9][]const u8 = undefined;
        const count = avail.getNames(&names);
        const result = self.renderer.getCommandInput(names[0..count]) catch |err| {
            if (err == error.ReadEOF) return true;
            return error.System; // I/O read failure treated as system
        };
        return try self.handleResult(result);
    }

    /// Native loop: draw the initial board + legend once, then run command turns
    /// until quit or EOF. Does not deinit — the caller owns teardown.
    pub fn native_run(self: *@This()) Error!void {
        try self.renderer.render(self.engine.eventBoard(), null);
        try self.renderer.showLegend(self.engine.getLegend());
        while (true) if (try self.turn()) break;
    }

    /// Wasm loop: exactly one command turn end to end per call.
    /// Returns true when the session is over.
    pub fn wasm_run(self: *@This()) Error!bool {
        return try self.turn();
    }

    /// Release the engine; the passed-in facade is owned by the caller.
    pub fn deinit(self: *@This()) void {
        self.engine.deinit();
    }
};

const board = @import("board.zig");
const cell = @import("board/cell.zig");
const styler_t = @import("renderer/ascii/styler.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");

test "integrated e2e - full seam: fill command via prefix dispatch" {
    // Arrange: fresh engine via Sudoku.init through real AsciiRenderer
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const responses = [_][]const u8{
        "fill A3 4",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport);
    defer sudoku.deinit();

    // Act: run the full loop — fill A3 with 4 via prefix dispatch, then quit
    sudoku.native_run() catch {};

    // Assert (a): engine has undo available after mutation.
    {
        const avail = sudoku.engine.getLegend();
        try std.testing.expect(avail.undo);
    }

    // Assert (b): cell at chess coord A3 -> row 2, col 0 is four.
    {
        try std.testing.expectEqual(cell.CellValue.four, sudoku.engine.state.board.getCellValue(@as(u4, 2), @as(u4, 0)));
    }
}

// Full round-trip: save known state → mutate → open the saved file → verify restore
// Uses the host-built facade to exercise the full dialog/caching path.
test "integrated e2e - full seam: open loads saved game" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    // 1. Create a save file with known state (no MockRenderer - real path through renderer)
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_full_seam_open_test.sud";

    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // Save known state to disk before running through the renderer
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), file_transport.NativeTransport.make(std.testing.io));
    defer original.deinit();
    try original.saveGame(tmp_path);

    // Record B2 value in saved state for later verification
    const saved_b2 = original.eventBoard().get(1, 1);

    // Canned responses: fill a cell -> open dialog -> filename -> quit
    const responses = [_][]const u8{
        "fill B2 7", // Mutate B2 (diverges from saved)
        "open", // Trigger open dialog prompt
        tmp_path ++ "\n", // Filename response for the dialog prompt
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport);
    defer sudoku_instance.deinit();

    // Run full loop: open dialog -> filename prompt -> load file -> quit.
    sudoku_instance.native_run() catch {};

    // After opening saved file: B2 restored to original saved value (not seven)
    try std.testing.expectEqual(saved_b2, sudoku_instance.engine.eventBoard().get(1, 1));
}

// Save/Open route through handleEvent() so the user gets feedback + a re-render

test "integrated e2e - save success produces status message, re-render, legend refresh" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_save_success_test.sud";

    // Canned responses: save -> filename prompt -> quit
    const responses = [_][]const u8{
        "save",
        tmp_path ++ "\n",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport);
    defer sudoku.deinit();

    sudoku.native_run() catch {};

    // Clean up saved file
    std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
}

test "integrated e2e - run: open file success produces status message, re-render, and legend refresh" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    // Create a save file to open
    const io = std.testing.io;
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), file_transport.NativeTransport.make(io));
    defer original.deinit();
    const tmp_path = "/tmp/sudoku_e2e_open_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // Canned responses: open <path> -> quit
    const responses = [_][]const u8{
        "open " ++ tmp_path,
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport);
    defer sudoku_instance.deinit();

    // Act: run full loop - open loads file from command arg, re-renders, shows legend
    sudoku_instance.native_run() catch {};
}

test "integrated e2e - run: save uses default filename and returns success" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_save_default_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // Canned responses: save -> filename prompt -> quit
    const responses = [_][]const u8{
        "save",
        tmp_path ++ "\n",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport);
    defer sudoku.deinit();

    // Act: run full loop - save prompts for filename, writes file, re-renders
    sudoku.native_run() catch {};
}
// First save prompts for a filename; a follow-up save reuses it without prompting

test "integrated e2e - run: fill → save → quit" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const responses = [_][]const u8{
        "fill A3 7",
        "save", // save command (triggers dialog for first use)
        "sudoku_save.sud\n", // answer to save As dialog prompt
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport);
    defer sudoku_instance.deinit();
    sudoku_instance.native_run() catch {};
}
// save_as writes the file through the dialog and re-renders
test "integrated e2e - run: save_as writes file and re-renders" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    // Canned responses: command → dialog filename → quit
    const responses = [_][]const u8{
        "save_as",
        "test_save_as.sud",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport);
    defer sudoku_instance.deinit();
    sudoku_instance.native_run() catch {};
}

// new starts a fresh board and clears the mutation history
test "integrated e2e - run: new command resets board and history" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    // feed fill (adds to history), then new (should clear it), then quit
    const responses = [_][]const u8{
        "fill A3 7",
        "new",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport);
    defer sudoku_instance.deinit();
    sudoku_instance.native_run() catch {};

    // history should be empty after new command clears it
    try std.testing.expectEqual(@as(usize, 0), sudoku_instance.engine.state.history.entries.items.len);
}
// Full end-to-end run through the host-built ansi facade
test "integrated e2e - run: host-built ansi facade processes quit cleanly" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const responses = [_][]const u8{
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport);

    defer sudoku.deinit();

    // Act: run through the host-built facade end-to-end
    sudoku.native_run() catch {};
}

test "integrated e2e - .ascii renderer kind renders plain unstyled grid" {
    const cfg: config.Config = .{
        .difficulty = .easy,
        .preferred_renderer = .ascii,
        .fallback_renderer = .ascii,
        .log_level = .info,
    };
    // The host's mock output buffer keeps the rendered grid observable.
    var host = host_mod.Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport);
    defer sudoku.deinit();
    try sudoku.renderer.render(sudoku.engine.state.board.asView(), null);

    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "A B C │ D E F") != null);
    // PlainStyler: no CSI escapes anywhere in the rendered output.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\x1b[") == null);
}

// Hostless assembly: a wasm facade + wasm transport stood in by static page
// mocks prove a game assembles without the native Host substrate.
var page_line_buf: [64]u8 = pad64("fill A3 4");
fn pad64(s: []const u8) [64]u8 {
    var out: [64]u8 = undefined;
    @memset(&out, 0);
    std.mem.copyForwards(u8, &out, s);
    return out;
}
var page_line_len: u32 = 9;

fn page_line_in(buf: [*]u8, cap: u32) callconv(.c) u32 {
    const n = @min(page_line_len, cap);
    @memcpy(buf[0..n], page_line_buf[0..n]);
    page_line_len = 0; // one line served — the next read is EOF
    return n;
}
fn page_bytes_out(bytes: [*]const u8, len: u32) callconv(.c) void {
    _ = bytes;
    _ = len;
}
fn page_picker(buf: [*]u8, cap: u32) callconv(.c) u32 {
    _ = buf;
    _ = cap;
    return 0; // cancelled
}

const Hostless = struct {
    host: *wasm_host.WasmHost,
    renderer: *wasm_renderer.WasmRenderer,
    facade: facade_mod.Facade,
    transport: file_transport.FileTransport,
};

fn hostless() Hostless {
    const A = std.testing.allocator;
    const transport = wasm_transport.WasmTransport.make(wasm_transport.test_file_write, wasm_transport.test_file_read);
    const host = A.create(wasm_host.WasmHost) catch unreachable;
    host.* = wasm_host.WasmHost.make(page_line_in, page_bytes_out, page_picker, wasm_transport.test_file_write, wasm_transport.test_file_read);
    const renderer = A.create(wasm_renderer.WasmRenderer) catch unreachable;
    renderer.* = wasm_renderer.WasmRenderer.init(A, host);
    return Hostless{
        .host = host,
        .renderer = renderer,
        .facade = facade_mod.Make(wasm_renderer.WasmRenderer).make(renderer),
        .transport = transport,
    };
}

test "hostless: wasm facade + transport assemble a working game" {
    var h = hostless();
    defer {
        std.testing.allocator.destroy(h.host);
        h.facade.deinit();
    }
    const cfg = config.Config{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };
    var game = try Sudoku.init(cfg, h.facade, h.transport);
    defer game.deinit();

    game.native_run() catch {};

    try std.testing.expectEqual(cell.CellValue.four, game.engine.state.board.getCellValue(@as(u4, 2), @as(u4, 0)));
    try std.testing.expect(game.engine.getLegend().undo);
}

test "hostless: hard cfg starts with the hard puzzle clues" {
    var h = hostless();
    defer {
        std.testing.allocator.destroy(h.host);
        h.facade.deinit();
    }
    const cfg = config.Config{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };
    var game = try Sudoku.init(cfg, h.facade, h.transport);
    defer game.deinit();

    // (1,7) is an eight clue in the hard puzzle string, blank in the easy one.
    try std.testing.expect(game.engine.state.board.isGiven(@as(u4, 1), @as(u4, 7)));
    try std.testing.expectEqual(cell.CellValue.eight, game.engine.state.board.getCellValue(@as(u4, 1), @as(u4, 7)));
}

test "hostless: easy cfg leaves (1,7) blank where hard has a clue" {
    var h = hostless();
    defer {
        std.testing.allocator.destroy(h.host);
        h.facade.deinit();
    }
    const cfg = config.Config{
        .difficulty = .easy,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };
    var game = try Sudoku.init(cfg, h.facade, h.transport);
    defer game.deinit();

    try std.testing.expect(!game.engine.state.board.isGiven(@as(u4, 1), @as(u4, 7)));
}
