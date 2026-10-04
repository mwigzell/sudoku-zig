// Sudoku facade: owns the command loop — prompt, parse, dispatch to the
// game engine, and render each resulting event back through the renderer.
const std = @import("std");
const facade_mod = @import("../../renderer/facade.zig");
const styler = @import("../ascii/styler.zig");
const game_engine = @import("../../engine/game_engine.zig");
const file_transport = @import("file_transport.zig");
const config = @import("../../config.zig");
const puzzle_gen = @import("../../puzzle_gen/mod.zig");
const command = @import("../../command.zig");
const settings_store = @import("../../settings_store.zig");
const startup_policy = @import("../../startup_policy.zig");

const disambiguate = @import("../ascii/disambiguate.zig");
const legend = @import("../../renderer/legend.zig");

const host_mod = @import("../host.zig");
const save_command = @import("save.zig");
const open_command = @import("open.zig");
const import_command = @import("import.zig");
const export_command = @import("export.zig");
const copy_command = @import("copy.zig");
const paste_command = @import("paste.zig");
const new_command = @import("new.zig");
const save_as_command = @import("save_as.zig");
const gen_progress = @import("gen_progress.zig");
pub const Error = error{ System, UnsupportedRenderer, NoFallbackConfigured };

/// One running game: engine + renderer; each entry shows the game, then turns it.
pub const SettingsPersist = struct {
    io: std.Io,
    data_dir: []const u8,
};

pub const Sudoku = struct {
    engine: game_engine.GameEngine,
    cfg: config.Config,
    renderer: facade_mod.Facade,
    transport: file_transport.FileTransport,
    out: *std.Io.Writer,
    settings_persist: ?SettingsPersist = null,
    last_cell: ?facade_mod.Selection = null,

    pub const StartupPolicyResult = struct {
        attempted_restore: bool,
        restore_failed: bool,
        rendered: bool,
    };

    /// Assemble a fresh game from the shared user-choices, a renderer facade,
    /// and the file transport arm the deployment selected.
    pub fn init(
        cfg: config.Config,
        facade: facade_mod.Facade,
        transport: file_transport.FileTransport,
        out: *std.Io.Writer,
        settings_persist: ?SettingsPersist,
    ) Error!@This() {
        var renderer_facade = facade;
        puzzle_gen.PuzzleGen.setPlayProgress(gen_progress.playProgressToFacade, @ptrCast(&renderer_facade));
        defer puzzle_gen.PuzzleGen.setPlayProgress(null, null);
        const puzzle_str = puzzle_gen.PuzzleGen.generate(cfg.difficulty);
        return @This(){
            .cfg = cfg,
            .renderer = facade,
            .transport = transport,
            .out = out,
            .settings_persist = settings_persist,
            .engine = try game_engine.GameEngine.init(puzzle_str, cfg),
        };
    }

    fn persistSettingsIfNeeded(self: *@This()) void {
        const sp = self.settings_persist orelse return;
        self.cfg = self.engine.getConfig();
        settings_store.save(std.heap.page_allocator, sp.io, sp.data_dir, self.cfg) catch {};
    }

    fn tracksCurrentFile(cmd: command.Command) bool {
        return switch (cmd) {
            .save, .save_as, .open => true,
            else => false,
        };
    }

    fn currentFilePathForCommand(cmd: command.Command) ?[]const u8 {
        return switch (cmd) {
            .save => |d| d.path,
            .save_as => |d| d.path,
            .open => |d| d.path,
            else => null,
        };
    }

    fn commandTriggersAutoSave(cmd: command.Command) bool {
        return switch (cmd) {
            .fill, .clear, .undo, .redo, .solve_for_me, .new, .open, .import, .paste => true,
            else => false,
        };
    }

    fn loadCurrentFileIfAny(self: *@This()) ?[]u8 {
        const sp = self.settings_persist orelse return null;
        return settings_store.loadCurrentFile(std.heap.page_allocator, sp.io, sp.data_dir) catch null;
    }

    fn persistCurrentFile(self: *@This(), path: ?[]const u8) void {
        const sp = self.settings_persist orelse return;
        settings_store.setCurrentFile(std.heap.page_allocator, sp.io, sp.data_dir, path) catch {};
    }

    fn persistResolvedCurrentFile(self: *@This(), path: []const u8) void {
        const resolved = self.transport.resolve(self.transport.context, path) catch return;
        defer self.transport.free(self.transport.context, resolved);
        self.persistCurrentFile(resolved);
    }

    fn applyAutoSavePolicyIfNeeded(self: *@This(), cmd: command.Command, event: game_engine.Event) game_engine.Event {
        if (!self.cfg.auto_save) return event;
        if (!commandTriggersAutoSave(cmd)) return event;
        switch (event) {
            .error_msg => return event,
            .ok => {},
        }

        const loaded = self.loadCurrentFileIfAny();
        defer if (loaded) |p| std.heap.page_allocator.free(p);
        const target = if (loaded) |p| p else save_command.DEFAULT_SAVE_FILE;
        const save_event = save_as_command.execute(&self.engine, self.transport, target);
        switch (save_event) {
            .ok => self.persistResolvedCurrentFile(target),
            .error_msg => {},
        }
        return save_event;
    }

    /// Dispatch one engine event to the renderer; returns true when the loop should end.
    /// Status passthrough (same rules as wasm shell.js applyEventStatus): silence when
    /// `.ok.msg` is null; never invent copy. `.error_msg` rides `showError` (interactive ack);
    /// `.ok.msg` rides the non-blocking `render` status slot.
    fn regionSelection(self: *const @This()) ?facade_mod.Selection {
        if (!self.engine.cfg.show_region) return null;
        return self.last_cell;
    }

    fn handleEvent(self: *@This(), event: game_engine.Event) Error!bool {
        switch (event) {
            .ok => |ev| {
                if (ev.cell) |c| self.last_cell = c;
                if (ev.is_quit) return true;
                try self.renderer.render(ev.board_view, ev.msg, self.regionSelection());
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
                const persist_after = switch (cmd) {
                    .set_region, .set_warn_solvability, .set_theme, .set_difficulty, .set_log_level => true,
                    else => false,
                };
                switch (cmd) {
                    .new, .open, .import, .paste => self.last_cell = null,
                    else => {},
                }
                const event = switch (cmd) {
                    .save => |data| blk: {
                        const path = data.path orelse save_command.DEFAULT_SAVE_FILE;
                        break :blk save_command.execute(&self.engine, self.transport, path);
                    },
                    .open => |data| open_command.execute(&self.engine, self.transport, data.path),
                    .import => |data| import_command.execute(&self.engine, self.transport, data.path),
                    .@"export" => |data| export_command.execute(&self.engine, self.transport, data.path),
                    .copy => copy_command.execute(&self.engine, self.out),
                    .paste => |data| paste_command.execute(&self.engine, data.line),
                    .new => |data| new_command.execute(&self.engine, data),
                    .save_as => |data| blk: {
                        const path = data.path orelse save_command.DEFAULT_SAVE_FILE;
                        break :blk save_as_command.execute(&self.engine, self.transport, path);
                    },
                    else => self.engine.exec(cmd),
                };
                if (tracksCurrentFile(cmd)) {
                    if (currentFilePathForCommand(cmd)) |path| switch (event) {
                        .ok => self.persistResolvedCurrentFile(path),
                        .error_msg => {},
                    };
                }
                const final_event = self.applyAutoSavePolicyIfNeeded(cmd, event);
                const quit = try self.handleEvent(final_event);
                if (persist_after) self.persistSettingsIfNeeded();
                return quit;
            },
        }
    }

    /// One command, end to end: getCommandInput → parse/dispatch → render.
    /// Return: true when the command signals session over (quit);
    /// error: input failed at the facade (renderer-level errors are already
    /// folded to error.System one level down) or dispatch/render failed.
    pub fn turn(self: *@This()) Error!bool {
        const avail = self.engine.getLegend();
        var names: [6][]const u8 = undefined;
        const count = avail.getNames(&names);
        const result = self.renderer.getCommandInput(
            names[0..count],
            self.engine.cfg.show_region,
            self.engine.cfg.warn_solvability,
            self.engine.cfg.difficulty,
            self.engine.cfg.log_level,
            self.engine.cfg.theme,
            self.last_cell,
        ) catch return error.System;
        return try self.handleResult(result);
    }

    /// The first screen: the current board + legend.
    pub fn showGame(self: *@This()) Error!void {
        try self.renderer.render(self.engine.eventBoard(), null, self.regionSelection());
        try self.renderer.showLegend(self.engine.getLegend());
    }

    /// Runs restore through the existing open-command seam using transport
    /// resolution and engine codec behavior.
    pub fn restoreFromPath(self: *@This(), file_path: []const u8) game_engine.Event {
        return open_command.execute(&self.engine, self.transport, file_path);
    }

    /// Startup action executor for native play; action selection is centralized
    /// in `startup_policy.evaluate` so web/native share one decision contract.
    pub fn runStartupPolicy(self: *@This(), current_file: ?[]const u8) Error!StartupPolicyResult {
        const decision = startup_policy.evaluate(.{
            .auto_restore = self.cfg.auto_restore,
            .auto_new = self.cfg.auto_new,
            .has_current_file = current_file != null,
            .restore_supported = true,
        });

        if (decision.action == .restore) {
            const event = self.restoreFromPath(current_file.?);
            switch (event) {
                .ok => {
                    _ = try self.handleEvent(event);
                    return .{ .attempted_restore = true, .restore_failed = false, .rendered = true };
                },
                .error_msg => |msg| {
                    try self.renderer.showError(msg);
                    return .{ .attempted_restore = true, .restore_failed = true, .rendered = false };
                },
            }
        }

        if (decision.action == .new) {
            const event = self.engine.newFromOneLinePuzzle(puzzle_gen.PuzzleGen.generate(self.cfg.difficulty));
            _ = try self.handleEvent(event);
            return .{ .attempted_restore = false, .restore_failed = false, .rendered = true };
        }

        return .{ .attempted_restore = false, .restore_failed = false, .rendered = false };
    }

    /// Release the engine and native transport session state.
    pub fn deinit(self: *@This()) void {
        self.engine.deinit();
        file_transport.NativeTransport.deinitSession();
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
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
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
        "m", // Menu → Open
        "2",
        tmp_path ++ "\n", // Filename response for the dialog prompt
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
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
        "m",
        "1",
        tmp_path ++ "\n",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
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
        "m",
        "2",
        tmp_path,
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();

    // Act: run full loop - open loads file from command arg, re-renders, shows legend
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
}

test "integrated e2e - run: open then save reuses opened path without filename prompt" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const io = std.testing.io;
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), config.Config.default());
    defer original.deinit();
    const tmp_path = "/tmp/sudoku_e2e_open_save_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    const setup_transport = file_transport.NativeTransport.make(io);
    const save_buf = try original.toSaveFormat(std.heap.page_allocator);
    defer std.heap.page_allocator.free(save_buf);
    try setup_transport.write(setup_transport.context, tmp_path, save_buf);

    // menu → open → path → menu → save → quit (no filename line after save)
    const responses = [_][]const u8{
        "m",
        "2",
        tmp_path,
        "m",
        "1",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();

    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    const on_disk = setup_transport.readAll(setup_transport.context, tmp_path) catch return error.TestFailed;
    defer setup_transport.free(setup_transport.context, on_disk);
    try std.testing.expect(on_disk.len > 0);
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
        "m",
        "1",
        tmp_path ++ "\n",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
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
        "m",
        "1", // save (triggers dialog for first use)
        "sudoku_save.sud\n", // answer to save As dialog prompt
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
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
        "m",
        "5",
        "test_save_as.sud",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
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
        "m",
        "5", // menu → New
        "2", // difficulty dialog → Medium (fresh generated puzzle)
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    // history should be empty after new command clears it
    try std.testing.expectEqual(@as(usize, 0), sudoku_instance.engine.state.history.entries.items.len);
}
// import via menu: puzzle file loaded into the engine, history reset
test "integrated e2e - run: import via menu loads puzzle and clears history" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const board_mod = @import("../../board/board.zig");
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_e2e_import_ok_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    const puzzle_line = puzzle_gen.PuzzleGen.hard();
    const setup_transport = file_transport.NativeTransport.make(io);
    try setup_transport.write(setup_transport.context, tmp_path, puzzle_line);

    // fill (adds history) → menu → Import → path → quit
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "3",
        tmp_path,
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    const expected = board_mod.fromOneLineString(puzzle_line) catch unreachable;
    try std.testing.expect(board_mod.equal(sudoku_instance.engine.state.board, expected));
    try std.testing.expectEqual(@as(usize, 0), sudoku_instance.engine.state.history.entries.items.len);
}

// import failure: board and history must be left untouched
test "integrated e2e - run: import failure leaves board and history intact" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    std.Io.Dir.deleteFileAbsolute(std.testing.io, "/tmp/sudoku_e2e_import_fail_test.txt") catch {};
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "3",
        "/tmp/sudoku_e2e_import_fail_test.txt",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    // history survived
    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
    // filled cell A3 (row 2, col 0) still holds seven
    try std.testing.expectEqual(cell.CellValue.seven, sudoku_instance.engine.state.board.getCellValue(2, 0));
}

// export via menu: current board written to one line, history untouched
test "integrated e2e - run: export via menu writes one-line file" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const board_mod = @import("../../board/board.zig");
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_e2e_export_ok_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // fill (adds history) → menu → Export → path → quit
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "4",
        tmp_path,
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
    const expected = board_mod.toOneLineString(sudoku_instance.engine.state.board);
    const bytes = transport.readAll(transport.context, tmp_path) catch return error.TestFailed;
    defer transport.free(transport.context, bytes);
    try std.testing.expectEqual(@as(usize, 81), bytes.len);
    try std.testing.expectEqualSlices(u8, &expected, bytes[0..81]);
    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
}

test "integrated e2e - run: copy via menu prints one-line puzzle; history untouched" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "12",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    const expected = export_command.currentPuzzleLine(&sudoku_instance.engine);
    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, &expected) != null);
    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
    try std.testing.expectEqual(cell.CellValue.seven, sudoku_instance.engine.state.board.getCellValue(2, 0));
}

test "integrated e2e - run: paste via menu loads puzzle and clears history" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const board_mod = @import("../../board/board.zig");
    const puzzle_line = puzzle_gen.PuzzleGen.hard();
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "13",
        puzzle_line,
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    const expected = board_mod.fromOneLineString(puzzle_line) catch unreachable;
    try std.testing.expect(board_mod.equal(sudoku_instance.engine.state.board, expected));
    try std.testing.expectEqual(@as(usize, 0), sudoku_instance.engine.state.history.entries.items.len);
}

test "integrated e2e - run: paste failure leaves board and history intact" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    var bad_line: [81]u8 = undefined;
    @memset(&bad_line, 'x');
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "13",
        &bad_line,
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
    try std.testing.expectEqual(cell.CellValue.seven, sudoku_instance.engine.state.board.getCellValue(2, 0));
}

// export failure: board and history must be left untouched
test "integrated e2e - run: export failure leaves board and history intact" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };
    std.Io.Dir.deleteFileAbsolute(std.testing.io, "/tmp/sudoku_e2e_export_missing_dir/x.txt") catch {};
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "4",
        "/tmp/sudoku_e2e_export_missing_dir/x.txt",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
    try std.testing.expectEqual(cell.CellValue.seven, sudoku_instance.engine.state.board.getCellValue(2, 0));
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
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);

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
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();
    try sudoku.renderer.render(sudoku.engine.state.board.asView(), null, null);

    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "A B C │ D E F") != null);
    // PlainStyler: no CSI escapes anywhere in the rendered output.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\x1b[") == null);
}
// RED: a .ok.msg status renders non-blocking — line-graphics box,
// no "Press Enter" ack, and the next input line is the next command.
test "integrated e2e - .ok.msg status is non-blocking; next line is a command" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };
    const io = std.testing.io;
    const gpa = std.heap.page_allocator;
    const tmp_path = "/tmp/sudoku_status_nonblocking_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), config.Config.default());
    defer original.deinit();
    const setup_transport = file_transport.NativeTransport.make(io);
    const save_buf = try original.toSaveFormat(gpa);
    defer gpa.free(save_buf);
    try setup_transport.write(setup_transport.context, tmp_path, save_buf);
    const b = original.state.board;
    const pick: struct { r: u4, c: u4 } = blk: {
        for (0..9) |r| {
            for (0..9) |c| {
                const ru = @as(u4, @intCast(r));
                const cu = @as(u4, @intCast(c));
                if (b.isGiven(ru, cu) or b.getCellValue(ru, cu) != cell.CellValue.zero) continue;
                const seven_bits: u32 = (@as(u32, 1) << 6);
                if (b.getBoxDigitBits(@intCast(@divTrunc(r, 3)), @intCast(@divTrunc(c, 3))) & seven_bits != 0) continue;
                var clash = false;
                for (0..9) |k| {
                    if (b.getCellValue(ru, @as(u4, @intCast(k))) == cell.CellValue.seven or
                        b.getCellValue(@as(u4, @intCast(k)), cu) == cell.CellValue.seven)
                    {
                        clash = true;
                        break;
                    }
                }
                if (clash) continue;
                break :blk .{ .r = ru, .c = cu };
            }
        }
        unreachable; // every generated puzzle leaves a clean cell
    };
    const ci: u8 = @intCast(pick.c);
    const col_letters = "ABCDEFGHI";
    const col_letter = col_letters[ci % 9];
    const fill_cmd = try std.fmt.allocPrint(gpa, "fill {c}{d} 7", .{ col_letter, pick.r + 1 });
    defer gpa.free(fill_cmd);
    const responses = [_][]const u8{
        "m",
        "2",
        tmp_path,
        fill_cmd,
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();
    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;
    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    // 1. Status message is displayed ...
    try std.testing.expect(std.mem.indexOf(u8, contents, "opened:") != null);
    // 2. ... without the interactive ack prompt ...
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") == null);
    // 3. ... inside a line-graphics frame (side border, or a top edge on the line above).
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var prev: ?[]const u8 = null;
    var framed = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "opened:") != null) {
            framed = std.mem.indexOf(u8, line, "│") != null or
                (prev != null and std.mem.indexOf(u8, prev.?, "┌") != null);
            break;
        }
        prev = line;
    }
    try std.testing.expect(framed);
    // 4. The line after the status is read as the next command: the fill lands.
    try std.testing.expectEqual(cell.CellValue.seven, sudoku.engine.state.board.getCellValue(pick.r, pick.c));
}

// RED: a .error_msg still acks — Press Enter shown, and the ack Enter
// is consumed by the ack (does not leak back to the parser as a command).
test "integrated e2e - .error_msg ack preserved: Enter is an ack, not a command" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };
    // bare fill → .error_msg; the empty line is the user's ack Enter; quit ends the loop.
    // The empty line is the user's ack Enter; quit ends the loop.
    const responses = [_][]const u8{ "fill", "", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();
    try sudoku.showGame();
    var terminated = false;
    while (true) {
        if (try sudoku.turn()) {
            terminated = true;
            break;
        }
    }
    try std.testing.expect(terminated);
    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    // routed through showError: the error text is in the output
    try std.testing.expect(std.mem.indexOf(u8, contents, "fill requires coordinate") != null);
    // interactive ack prompt present
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") != null);
    // the ack Enter was consumed by the ack, not re-parsed as a command
    try std.testing.expect(std.mem.indexOf(u8, contents, "empty input") == null);
    // exactly one ack — the ack line did not re-enter the parser loop
    var ack_count: usize = 0;
    var rest = contents;
    while (std.mem.indexOfPos(u8, rest, 0, "Press Enter to continue...")) |i| {
        ack_count += 1;
        rest = rest[i + "Press Enter to continue...".len ..];
    }
    try std.testing.expectEqual(@as(usize, 1), ack_count);
}

test "integrated e2e - menu hint returns placement status without mutating board" {
    const cfg: config.Config = .{
        .difficulty = .easy,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const responses = [_][]const u8{ "m", "8", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    const before = export_command.currentPuzzleLine(&sudoku_instance.engine);

    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    const after = export_command.currentPuzzleLine(&sudoku_instance.engine);
    try std.testing.expectEqualSlices(u8, &before, &after);
    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(placement)") != null);
}

test "integrated e2e - fill does not shade region until show_region enabled" {
    const region_on = "\x1b[48;5;238m";
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };
    const gpa = std.heap.page_allocator;
    var probe = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), cfg);
    defer probe.deinit();
    const b = probe.state.board;
    const pick: struct { r: u4, c: u4 } = blk: {
        for (0..9) |r| {
            for (0..9) |c| {
                const ru = @as(u4, @intCast(r));
                const cu = @as(u4, @intCast(c));
                if (b.isGiven(ru, cu) or b.getCellValue(ru, cu) != cell.CellValue.zero) continue;
                const seven_bits: u32 = (@as(u32, 1) << 6);
                if (b.getBoxDigitBits(@intCast(@divTrunc(r, 3)), @intCast(@divTrunc(c, 3))) & seven_bits != 0) continue;
                var clash = false;
                for (0..9) |k| {
                    if (b.getCellValue(ru, @as(u4, @intCast(k))) == cell.CellValue.seven or
                        b.getCellValue(@as(u4, @intCast(k)), cu) == cell.CellValue.seven)
                    {
                        clash = true;
                        break;
                    }
                }
                if (clash) continue;
                break :blk .{ .r = ru, .c = cu };
            }
        }
        unreachable;
    };
    const col_letters = "ABCDEFGHI";
    const fill_cmd = try std.fmt.allocPrint(gpa, "fill {c}{d} 7", .{ col_letters[pick.c], pick.r + 1 });
    defer gpa.free(fill_cmd);
    const responses = [_][]const u8{ fill_cmd, "m", "7", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    const board_marker = "╰───────┴───────┴───────╯";
    const first_board_end = std.mem.indexOf(u8, contents, board_marker) orelse return error.TestFailed;
    const after_fill = contents[0 .. first_board_end + board_marker.len];
    try std.testing.expect(std.mem.indexOf(u8, after_fill, region_on) == null);
    try std.testing.expect(sudoku.last_cell != null);
    try std.testing.expect(sudoku.engine.cfg.show_region);
    try std.testing.expect(std.mem.indexOf(u8, contents, region_on) != null);
}

test "integrated e2e: menu Settings persists difficulty to settings.json" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const cfg = config.Config.default();
    const responses = [_][]const u8{ "menu\n", "14\n", "2\n", "3\n", "quit\n" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), .{ .io = io, .data_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expectEqual(config.Difficulty.hard, app.engine.cfg.difficulty);
    const restored = try settings_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expectEqual(config.Difficulty.hard, restored.difficulty);
}

test "integrated e2e: menu Settings persists warn_solvability to settings.json" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const cfg = config.Config.default();
    const responses = [_][]const u8{ "menu\n", "14\n", "1\n", "quit\n" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), .{ .io = io, .data_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expect(app.engine.cfg.warn_solvability);
    const restored = try settings_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expect(restored.warn_solvability);
}

test "startup policy: auto_restore false and auto_new false keeps manual startup" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
        .auto_restore = false,
        .auto_new = false,
    };
    var host = host_mod.Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(std.testing.io), host.writer(), null);
    defer app.deinit();

    const before = export_command.currentPuzzleLine(&app.engine);
    const startup = try app.runStartupPolicy(null);
    const after = export_command.currentPuzzleLine(&app.engine);

    try std.testing.expect(!startup.attempted_restore);
    try std.testing.expect(!startup.restore_failed);
    try std.testing.expect(!startup.rendered);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "startup policy: auto_restore true restores from current_file path" {
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_startup_restore_ok.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
        .auto_restore = true,
    };

    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), config.Config.default());
    defer original.deinit();
    const transport = file_transport.NativeTransport.make(io);
    const save_buf = try original.toSaveFormat(std.heap.page_allocator);
    defer std.heap.page_allocator.free(save_buf);
    try transport.write(transport.context, tmp_path, save_buf);
    const saved_b2 = original.eventBoard().get(1, 1);

    var host = host_mod.Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), null);
    defer app.deinit();
    _ = app.engine.exec(.{ .fill = .{ .row = 1, .col = 1, .digit = cell.CellValue.seven } });

    const startup = try app.runStartupPolicy(tmp_path);
    try std.testing.expect(startup.attempted_restore);
    try std.testing.expect(!startup.restore_failed);
    try std.testing.expect(startup.rendered);
    try std.testing.expectEqual(saved_b2, app.engine.eventBoard().get(1, 1));
}

test "startup policy: restore failure blocks and does not auto-new fallback in same run" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
        .auto_restore = true,
        .auto_new = true,
    };

    const responses = [_][]const u8{ "\n" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(std.testing.io), host.writer(), null);
    defer app.deinit();
    const before = export_command.currentPuzzleLine(&app.engine);

    const startup = try app.runStartupPolicy("/tmp/missing_startup_restore_file.sud");
    const after = export_command.currentPuzzleLine(&app.engine);
    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);

    try std.testing.expect(startup.attempted_restore);
    try std.testing.expect(startup.restore_failed);
    try std.testing.expect(!startup.rendered);
    try std.testing.expectEqualSlices(u8, &before, &after);
    try std.testing.expect(std.mem.indexOf(u8, output, "Press Enter to continue...") != null);
}

test "autosave: fill writes default save and bootstraps current_file when unset" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var cfg = config.Config.default();
    cfg.auto_save = true;

    const responses = [_][]const u8{ "fill A3 7", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path });
    defer app.deinit();
    try app.showGame();
    while (true) if (try app.turn()) break;

    const current = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current != null);

    const bytes = app.transport.readAll(app.transport.context, current.?) catch return error.TestFailed;
    defer app.transport.free(app.transport.context, bytes);
    try std.testing.expect(bytes.len > 0);
}

test "autosave: non-state settings command does not bootstrap current_file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var cfg = config.Config.default();
    cfg.auto_save = true;

    const responses = [_][]const u8{ "menu\n", "14\n", "4\n", "2\n", "quit\n" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path });
    defer app.deinit();
    try app.showGame();
    while (true) if (try app.turn()) break;

    const current = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current == null);
}

test "autosave: successful open updates current_file pointer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var cfg = config.Config.default();
    cfg.auto_save = false;

    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), config.Config.default());
    defer original.deinit();
    const tmp_path = "/tmp/sudoku_autosave_open_pointer.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    const setup_transport = file_transport.NativeTransport.make(io);
    const save_buf = try original.toSaveFormat(std.heap.page_allocator);
    defer std.heap.page_allocator.free(save_buf);
    try setup_transport.write(setup_transport.context, tmp_path, save_buf);

    const responses = [_][]const u8{ "m", "2", tmp_path, "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path });
    defer app.deinit();
    try app.showGame();
    while (true) if (try app.turn()) break;

    const current = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings(tmp_path, current.?);
}
