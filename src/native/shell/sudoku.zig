// Sudoku facade: owns the command loop — prompt, parse, dispatch to the
// game engine, and render each resulting event back through the renderer.
const std = @import("std");
const facade_mod = @import("../../renderer/facade.zig");
const styler = @import("../ascii/styler.zig");
const game_engine = @import("../../engine/game_engine.zig");
const file_transport = @import("file_transport.zig");
const config = @import("../../config.zig");
const puzzle_gen = @import("../../puzzle_gen.zig");
const command = @import("../../command.zig");

const disambiguate = @import("../ascii/disambiguate.zig");
const legend = @import("../../renderer/legend.zig");

const host_mod = @import("../host.zig");
const save_command = @import("save.zig");
const open_command = @import("open.zig");
const new_command = @import("new.zig");
const save_as_command = @import("save_as.zig");
pub const Error = error{ System, UnsupportedRenderer, NoFallbackConfigured };

/// One running game: engine + renderer; both deployments show the game, then turn it.
pub const Sudoku = struct {
    engine: game_engine.GameEngine,
    cfg: config.Config,
    renderer: facade_mod.Facade,
    transport: file_transport.FileTransport,

    /// Assemble a fresh game from the shared user-choices, a renderer facade,
    /// and the file transport arm the deployment selected.
    pub fn init(cfg: config.Config, facade: facade_mod.Facade, transport: file_transport.FileTransport) Error!@This() {
        const puzzle_str = puzzle_gen.PuzzleGen.generate(cfg.difficulty);
        return @This(){
            .cfg = cfg,
            .renderer = facade,
            .transport = transport,
            .engine = try game_engine.GameEngine.init(puzzle_str, cfg),
        };
    }

    /// Dispatch one engine event to the renderer; returns true when the loop should end.
    /// Status passthrough (same rules as wasm shell.js applyEventStatus): show a message
    /// only for `.error_msg` or `.ok.msg`; silence when `.ok.msg` is null; never invent copy.
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
                const event = switch (cmd) {
                    .save => |data| blk: {
                        const path = data.path orelse save_command.DEFAULT_SAVE_FILE;
                        break :blk save_command.execute(&self.engine, self.transport, path);
                    },
                    .open => |data| open_command.execute(&self.engine, self.transport, data.path),
                    .new => |data| new_command.execute(&self.engine, self.transport, data),
                    .save_as => |data| blk: {
                        const path = data.path orelse save_command.DEFAULT_SAVE_FILE;
                        break :blk save_as_command.execute(&self.engine, self.transport, path);
                    },
                    else => self.engine.exec(cmd),
                };
                return try self.handleEvent(event);
            },
        }
    }

    /// One command, end to end: getCommandInput → parse/dispatch → render.
    /// Return: true when the command signals session over (quit);
    /// error: input failed at the facade (renderer-level errors are already
    /// folded to error.System one level down) or dispatch/render failed.
    pub fn turn(self: *@This()) Error!bool {
        const avail = self.engine.getLegend();
        var names: [9][]const u8 = undefined;
        const count = avail.getNames(&names);
        const result = self.renderer.getCommandInput(names[0..count]) catch return error.System; // I/O read failure treated as system
        return try self.handleResult(result);
    }

    /// The first screen: the current board + legend.
    pub fn showGame(self: *@This()) Error!void {
        try self.renderer.render(self.engine.eventBoard(), null);
        try self.renderer.showLegend(self.engine.getLegend());
    }

    /// Release the engine; the passed-in facade is owned by the caller.
    pub fn deinit(self: *@This()) void {
        self.engine.deinit();
    }
};

const board = @import("../../board/board.zig");
const cell = @import("../../board/cell.zig");
const styler_t = @import("../ascii/styler.zig");
const ascii_renderer = @import("../ascii/renderer.zig");

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
    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

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
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), config.Config.default());
    defer original.deinit();
    const setup_transport = file_transport.NativeTransport.make(io);
    const save_buf = try original.toSaveFormat(std.heap.page_allocator);
    defer std.heap.page_allocator.free(save_buf);
    try setup_transport.write(setup_transport.context, tmp_path, save_buf);

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
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

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

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

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
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), config.Config.default());
    defer original.deinit();
    const tmp_path = "/tmp/sudoku_e2e_open_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    const setup_transport = file_transport.NativeTransport.make(io);
    const save_buf = try original.toSaveFormat(std.heap.page_allocator);
    defer std.heap.page_allocator.free(save_buf);
    try setup_transport.write(setup_transport.context, tmp_path, save_buf);

    // Canned responses: open <path> -> quit
    const responses = [_][]const u8{
        "open " ++ tmp_path,
        "", // accept the status message (Press Enter)
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
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
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
    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;
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
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
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
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
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
        "", // accept the status message (Press Enter)
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

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
    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;
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
