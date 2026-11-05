// Sudoku facade: owns the command loop — prompt, parse, dispatch to the
// game engine, and render each resulting event back through the renderer.
const std = @import("std");
const facade_mod = @import("../../core/renderer/facade.zig");
const styler = @import("../ascii/styler.zig");
const game_engine = @import("../../core/engine/game_engine.zig");
const file_transport = @import("file_transport.zig");
const config = @import("../../core/config.zig");
const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");
const command = @import("../../core/command.zig");
const startup_policy = @import("../../core/startup/policy.zig");
const startup_engine = @import("../../core/startup/engine.zig");
const file_policy = @import("../../core/file_policy.zig");
const flow_mod = @import("../../core/flow/mod.zig");

const disambiguate = @import("../ascii/disambiguate.zig");
const legend = @import("../../core/renderer/legend.zig");

const host_mod = @import("../host.zig");
const gen_progress = @import("gen_progress.zig");
const storage_mod = @import("storage.zig");
pub const Error = error{ System, UnsupportedRenderer, NoFallbackConfigured };

const PASTE_NO_PUZZLE_MSG: []const u8 = "paste: no puzzle specified";
const NO_FLUSH_MSG: []const u8 = "flush: the terminal has no closing write";
const NO_RECLAIM_MSG: []const u8 = "reclaim_file: the terminal has no earlier-install files";

/// One running game: engine + renderer; each entry shows the game, then turns it.
pub const Sudoku = struct {
    engine: game_engine.GameEngine,
    cfg: config.Config,
    renderer: facade_mod.Facade,
    storage: storage_mod.Storage,
    out: *std.Io.Writer,
    last_cell: ?facade_mod.Selection = null,
    file_session: flow_mod.FileSession = .{},
    /// The one flow in progress; terminal step text points into it until the next flow starts.
    flow: flow_mod.Flow = undefined,
    /// Sees every step core issues and this shell's answer; the parity tests record transcripts with it.
    step_observer: ?StepObserver = null,

    /// Called once per step: with the answer before core takes it, or with null for the step that ends the flow.
    pub const StepObserver = struct {
        ctx: *anyopaque,
        onStep: *const fn (ctx: *anyopaque, step: flow_mod.Step, answer: ?flow_mod.Input) void,
    };

    /// Assemble a fresh game from the shared user-choices, a renderer facade,
    /// and the file transport arm the deployment selected.
    pub fn init(
        cfg: config.Config,
        facade: facade_mod.Facade,
        transport: file_transport.FileTransport,
        out: *std.Io.Writer,
        settings_persist: ?storage_mod.SettingsPersist,
    ) Error!@This() {
        // Startup policy owns if/when puzzle generation occurs.
        var renderer_facade = facade;
        puzzle_gen.PuzzleGen.setPlayProgress(gen_progress.playProgressToFacade, @ptrCast(&renderer_facade));
        defer puzzle_gen.PuzzleGen.setPlayProgress(null, null);
        var sudoku = @This(){
            .cfg = cfg,
            .renderer = facade,
            .storage = .{ .transport = transport, .settings_persist = settings_persist },
            .out = out,
            .engine = try startup_engine.initEngineFromStartup(cfg),
        };
        const current = sudoku.storage.loadCurrentFile(std.heap.page_allocator);
        defer if (current) |p| std.heap.page_allocator.free(p);
        sudoku.file_session.setCurrentFile(current);
        return sudoku;
    }

    /// Drive `self.flow` to its terminal step, carrying out each step on this platform.
    fn runFlow(self: *@This()) Error!flow_mod.Step {
        var scratch: [flow_mod.file_session.MAX_NAME_LEN]u8 = undefined;
        var step = self.flow.next(.start);
        while (true) {
            var read_bytes: ?[]u8 = null;
            const transport = self.storage.transport;
            defer if (read_bytes) |b| transport.free(transport.context, b);
            var opened: ?storage_mod.ReadResult = null;
            defer if (opened) |o| {
                transport.free(transport.context, o.resolved);
                transport.free(transport.context, o.bytes);
            };
            const input: flow_mod.Input = switch (step) {
                .resolve_default_target => .{ .default_target = self.storage.resolveDefaultTarget(&scratch) },
                .prompt_message => |prompt| .{ .pressed = try self.renderer.promptMessage(prompt) },
                .save, .save_as, .autosave => |target| .{ .wrote = self.storage.saveGame(&self.engine, target, &scratch) },
                .export_puzzle => |name| .{ .wrote = self.storage.exportPuzzle(&self.engine, name, &scratch) },
                .restore => |path| blk: {
                    const read = self.storage.restore(path, &scratch);
                    if (read == .file) read_bytes = @constCast(read.file.bytes);
                    break :blk .{ .read = read };
                },
                .open => |path| .{ .read = self.storage.open(path, &scratch, &opened) },
                .import_puzzle => |path| .{ .read = self.storage.importPuzzle(path, &scratch, &opened) },
                // The terminal has no clipboard; Paste takes its puzzle with the command.
                .paste_puzzle => .{ .read = .{ .failed = PASTE_NO_PUZZLE_MSG } },
                .show_game => |game| blk: {
                    try self.showStep(game);
                    break :blk .ack;
                },
                .generate_game => |difficulty| .{ .generated = .{ .line = self.generate(difficulty) } },
                .forget_current_file => |forget| blk: {
                    self.storage.forgetCurrentFile(forget);
                    break :blk .ack;
                },
                .persist_settings => |cfg| blk: {
                    self.cfg = cfg;
                    break :blk .{ .persisted = self.storage.persistSettings(cfg) };
                },
                .copy_puzzle => .{ .copied = self.printPuzzle() },
                // Only the web flushes, when its page closes; a terminal game is written after every command.
                .flush => .{ .wrote = .{ .failed = NO_FLUSH_MSG } },
                // Native writes never answer `taken`, so core never asks to reclaim a file here.
                .reclaim_file => .{ .wrote = .{ .failed = NO_RECLAIM_MSG } },
                .show_status, .done => {
                    if (self.step_observer) |o| o.onStep(o.ctx, step, null);
                    return step;
                },
            };
            if (self.step_observer) |o| o.onStep(o.ctx, step, input);
            step = self.flow.next(input);
        }
    }

    /// Carry out a `generate_game` step, reporting progress through the renderer.
    fn generate(self: *@This(), difficulty: puzzle_gen.Difficulty) []const u8 {
        puzzle_gen.PuzzleGen.setPlayProgress(gen_progress.playProgressToFacade, @ptrCast(&self.renderer));
        defer puzzle_gen.PuzzleGen.setPlayProgress(null, null);
        return puzzle_gen.PuzzleGen.generate(difficulty);
    }

    /// Carry out a `copy_puzzle` step: the terminal has no clipboard, so print the puzzle for the player to copy.
    fn printPuzzle(self: *@This()) flow_mod.step.Outcome {
        const line = self.engine.toPuzzle();
        self.out.writeAll(&line) catch |err| return .{ .failed = @errorName(err) };
        self.out.writeAll("\n") catch |err| return .{ .failed = @errorName(err) };
        return .ok;
    }

    /// Run one player command through the core command flow.
    fn runCommandFlow(self: *@This(), cmd: command.Command) Error!void {
        self.flow = .{ .command = flow_mod.CommandFlow.init(&self.engine, &self.file_session, cmd) };
        switch (try self.runFlow()) {
            .show_status => |text| try self.showGameWithStatus(text),
            else => {},
        }
    }

    /// Carry out a `show_game` step: draw what core reports, remembering the edited cell for region shading.
    /// A loaded game's file is also remembered for the next launch.
    fn showStep(self: *@This(), game: flow_mod.step.ShowGame) Error!void {
        if (game.loaded) {
            self.last_cell = null;
            if (game.file) |file| self.storage.persistCurrentFile(file);
        }
        if (game.cell) |c| self.last_cell = c;
        const region: ?facade_mod.Selection = if (game.config.show_region) self.last_cell else null;
        try self.renderer.render(game.board, game.status, region);
        try self.renderer.showLegend(game.legend);
    }

    /// The cell whose region is shaded, when Show Region is on.
    fn regionSelection(self: *const @This()) ?facade_mod.Selection {
        if (!self.engine.cfg.show_region) return null;
        return self.last_cell;
    }

    /// Dispatch one engine event to the renderer; returns true when the loop should end.
    /// `.ok.msg` rides the status slot (null shows none); `.error_msg` is core's error prompt.
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
                _ = try self.renderer.promptMessage(flow_mod.step.makeErrorPrompt(msg));
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
                if (cmd == .quit) return try self.handleEvent(self.engine.exec(cmd));
                try self.runCommandFlow(cmd);
                return false;
            },
        }
    }

    /// One command, end to end: getCommandInput → parse/dispatch → render.
    /// Return: true when the command signals session over (quit);
    /// error: input failed at the facade (renderer-level errors are already
    /// folded to error.System one level down) or dispatch/render failed.
    pub fn turn(self: *@This()) Error!bool {
        const avail = self.engine.getLegend();
        var names: [7][]const u8 = undefined;
        const count = avail.getNames(&names);
        const result = self.renderer.getCommandInput(
            names[0..count],
            self.engine.cfg.show_region,
            self.engine.cfg.warn_solvability,
            self.engine.cfg.difficulty,
            self.engine.cfg.log_level,
            self.engine.cfg.theme,
            self.engine.cfg.auto_restore,
            self.engine.cfg.auto_new,
            self.engine.cfg.auto_save,
            self.last_cell,
        ) catch return error.System;
        return try self.handleResult(result);
    }

    /// The first screen: the current board + legend.
    pub fn showGame(self: *@This()) Error!void {
        return self.showGameWithStatus(null);
    }

    /// First-screen render variant that allows a startup status line.
    pub fn showGameWithStatus(self: *@This(), status_msg: ?[]const u8) Error!void {
        try self.renderer.render(self.engine.eventBoard(), status_msg, self.regionSelection());
        try self.renderer.showLegend(self.engine.getLegend());
    }

    /// Run the shared startup flow: restore `current_file`, start a new game, or show the idle board.
    pub fn runStartupFlow(self: *@This(), current_file: ?[]const u8) Error!void {
        const current: ?flow_mod.startup.CurrentFile = if (current_file) |path|
            .{ .path = path, .name = std.fs.path.basename(path), .current = path }
        else
            null;
        self.flow = .{ .startup = flow_mod.StartupFlow.init(&self.engine, &self.file_session, .{
            .auto_restore = self.engine.cfg.auto_restore,
            .auto_new = self.engine.cfg.auto_new,
            .difficulty = self.engine.cfg.difficulty,
        }, current) };
        _ = try self.runFlow();
    }

    /// Release the engine and native transport session state.
    pub fn deinit(self: *@This()) void {
        self.engine.deinit();
        file_transport.NativeTransport.deinitSession();
    }
};

const board = @import("../../core/board/board.zig");
const cell = @import("../../core/board/cell.zig");
const logger = @import("../../core/logger.zig");
const styler_t = @import("../ascii/styler.zig");
const ascii_renderer = @import("../ascii/renderer.zig");

const settings_store = @import("../../core/settings_store.zig");
const save_defaults = @import("../../core/save_defaults.zig");

/// Scripted renderer: feeds preset commands and yes/no answers, records what the shell showed.
const DeterministicFacade = struct {
    steps: []const command.ParseCommandResult,
    idx: usize = 0,
    render_calls: usize = 0,
    legend_calls: usize = 0,
    error_calls: usize = 0,
    replace_prompts: usize = 0,
    last_render_msg: ?[]const u8 = null,
    replace_answers: []const bool = &[_]bool{},
    replace_idx: usize = 0,

    /// Renderer seam backed by this scripted facade.
    pub fn asFacade(self: *@This()) facade_mod.Facade {
        return facade_mod.Make(@This()).make(self);
    }

    /// Records render calls from Sudoku.handleEvent for deterministic branch tests.
    pub fn render(self: *@This(), _: board.Board.BoardView, msg: ?[]const u8, _: ?facade_mod.Selection) !void {
        self.render_calls += 1;
        self.last_render_msg = msg;
    }

    /// Records legend refreshes from successful event handling.
    pub fn showLegend(self: *@This(), _: legend.Legend) !void {
        self.legend_calls += 1;
    }

    /// Records prompts: a one-button prompt is an acknowledged error, more buttons a question
    /// answered from the scripted yes/no answers (yes when they run out).
    pub fn promptMessage(self: *@This(), prompt: flow_mod.PromptMessage) !usize {
        if (prompt.buttons.len == 1) {
            self.error_calls += 1;
            return 0;
        }
        self.replace_prompts += 1;
        var yes = true;
        if (self.replace_idx < self.replace_answers.len) {
            yes = self.replace_answers[self.replace_idx];
            self.replace_idx += 1;
        }
        return if (yes) flow_mod.step.QUESTION_OK else flow_mod.step.QUESTION_CANCEL;
    }

    /// Feeds pre-scripted command results into Sudoku.turn for deterministic flow tests.
    pub fn getCommandInput(
        self: *@This(),
        _: []const []const u8,
        _: bool,
        _: bool,
        _: config.Difficulty,
        _: logger.Severity,
        _: config.ViewTheme,
        _: bool,
        _: bool,
        _: bool,
        _: ?facade_mod.Selection,
    ) !command.ParseCommandResult {
        if (self.idx >= self.steps.len) return .{ .valid = .{ .quit = {} } };
        const step = self.steps[self.idx];
        self.idx += 1;
        return step;
    }

    /// No-op progress sink for deterministic tests that do not assert gen progress output.
    pub fn reportGenProgress(_: *@This(), _: puzzle_gen.GenProgressEvent) !void {}

    /// No-op lifecycle hook to satisfy the Facade contract in tests.
    pub fn deinit(_: *@This()) void {}
};

const MemoryTransport = @import("memory_transport.zig").MemoryTransport;

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

test "deterministic major path: save_as then open restores saved snapshot" {
    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .fill = .{ .row = 2, .col = 0, .digit = .seven } } },
        .{ .valid = .{ .save_as = .{ .path = "/virtual/game.sud" } } },
        .{ .valid = .{ .fill = .{ .row = 2, .col = 0, .digit = .one } } },
        .{ .valid = .{ .open = .{ .path = "/virtual/game.sud" } } },
        .{ .valid = .{ .quit = {} } },
    };
    var facade_impl = DeterministicFacade{ .steps = &steps };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try Sudoku.init(config.Config.default(), facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expectEqual(cell.CellValue.seven, app.engine.state.board.getCellValue(2, 0));
    try std.testing.expectEqual(@as(usize, 0), facade_impl.error_calls);
}

test "deterministic major path: import then export round-trips through command loop" {
    const line = puzzle_gen.PuzzleGen.hard();
    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .import = .{ .path = "/virtual/in.txt" } } },
        .{ .valid = .{ .@"export" = .{ .path = "/virtual/out.txt" } } },
        .{ .valid = .{ .quit = {} } },
    };
    var facade_impl = DeterministicFacade{ .steps = &steps };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    try transport_impl.put("/virtual/in.txt", line);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try Sudoku.init(config.Config.default(), facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const written = transport_impl.files.get("/virtual/out.txt") orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, line, written);
    try std.testing.expectEqual(@as(usize, 0), facade_impl.error_calls);
}

test "deterministic major path: explicit new puzzle replaces board and clears history" {
    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .fill = .{ .row = 2, .col = 0, .digit = .seven } } },
        .{ .valid = .{ .new = .{ .puzzle = puzzle_gen.PuzzleGen.medium() } } },
        .{ .valid = .{ .quit = {} } },
    };
    var facade_impl = DeterministicFacade{ .steps = &steps };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try Sudoku.init(config.Config.default(), facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const expected = try board.fromPuzzle(puzzle_gen.PuzzleGen.medium());
    try std.testing.expect(board.equal(app.engine.state.board, expected));
    try std.testing.expectEqual(@as(usize, 0), app.engine.state.history.entries.items.len);
}

test "deterministic major path: new without a puzzle generates one at the chosen difficulty" {
    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .fill = .{ .row = 2, .col = 0, .digit = .seven } } },
        .{ .valid = .{ .new = .{ .difficulty = .easy } } },
        .{ .valid = .{ .quit = {} } },
    };
    var facade_impl = DeterministicFacade{ .steps = &steps };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var cfg = config.Config.default();
    cfg.difficulty = .hard;

    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expectEqual(@as(usize, 0), app.engine.state.history.entries.items.len);
    try std.testing.expectEqual(puzzle_gen.Difficulty.easy, app.engine.cfg.difficulty);
    try std.testing.expectEqualStrings(game_engine.NEW_GAME_STARTED_MSG, app.engine.state.status.optional().?);
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
        "6",
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

test "integrated e2e - run: save_as failure does not persist current_file pointer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const bad_path = "/tmp/sudoku_missing_parent_dir/deny.sud";

    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const responses = [_][]const u8{
        "m",
        "6",
        bad_path,
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const current = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current == null);
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

test "new shows core's generation progress through the renderer" {
    const cfg: config.Config = .{
        .difficulty = .easy,
        .preferred_renderer = .ascii,
        .fallback_renderer = .ascii,
        .log_level = .info,
    };
    const responses = [_][]const u8{ "m", "5", "1", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    var want_buf: [96]u8 = undefined;
    const want = puzzle_gen.formatProgressEvent(.round, &want_buf).?;
    try std.testing.expect(std.mem.indexOf(u8, host.writer().buffered(), want) != null);
}

test "new command with auto_save enabled does not print saved-to status" {
    var cfg = config.Config.default();
    cfg.auto_save = true;
    cfg.difficulty = .hard;
    cfg.preferred_renderer = .ansi;
    cfg.fallback_renderer = .ansi;
    cfg.log_level = .info;

    const responses = [_][]const u8{
        "m",
        "5",
        "2",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, "saved to:") == null);
}

test "save as to a typed path shows its saved-to status after the later flows run" {
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_save_status_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    const cfg = config.Config.default();
    const responses = [_][]const u8{ "m", "6", tmp_path ++ "\n", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, std.fmt.comptimePrint(file_policy.SAVED_TO_FMT, .{tmp_path})) != null);
}

test "menu save while autosave is on writes nothing and says why" {
    var cfg = config.Config.default();
    cfg.auto_save = true;
    const responses = [_][]const u8{ "m", "1", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, file_policy.SAVE_WHILE_AUTO_SAVE_MSG) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "saved to:") == null);
}

test "autosave does not clobber undo win status with saved-to message" {
    var cfg = config.Config.default();
    cfg.auto_save = true;
    cfg.difficulty = .hard;
    cfg.preferred_renderer = .ansi;
    cfg.fallback_renderer = .ansi;
    cfg.log_level = .info;

    const responses = [_][]const u8{
        "fill E5 6",
        "clear E5",
        "undo",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer app.deinit();

    const almost = "483921657967345821251876493548132976729504138136798245372689514814253769695417382";
    _ = app.engine.newFromOneLinePuzzle(almost);

    try app.showGame();
    while (true) if (try app.turn()) break;

    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, "You win!") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "saved to:") == null);
}
// import via menu: puzzle file loaded into the engine, history reset
test "integrated e2e - run: import via menu loads puzzle and clears history" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
    };

    const board_mod = @import("../../core/board/board.zig");
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

    const expected = board_mod.fromPuzzle(puzzle_line) catch unreachable;
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
    const expected = sudoku_instance.engine.toPuzzle();
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

    const expected = sudoku_instance.engine.toPuzzle();
    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, &expected) != null);
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
    const opened_status = " is open.";
    // 1. Status message is displayed ...
    try std.testing.expect(std.mem.indexOf(u8, contents, opened_status) != null);
    // 2. ... without the interactive ack prompt ...
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") == null);
    // 3. ... inside a line-graphics frame (side border, or a top edge on the line above).
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var prev: ?[]const u8 = null;
    var framed = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, opened_status) != null) {
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
    const parser = @import("../ascii/parser.zig");
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
    // routed through promptMessage: the error text is in the output
    try std.testing.expect(std.mem.indexOf(u8, contents, parser.FILL_USAGE_MSG) != null);
    // interactive ack prompt present
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") != null);
    // the ack Enter was consumed by the ack, not re-parsed as a command
    try std.testing.expect(std.mem.indexOf(u8, contents, parser.EMPTY_INPUT_MSG) == null);
    // exactly one ack — the ack line did not re-enter the parser loop
    var ack_count: usize = 0;
    var rest = contents;
    while (std.mem.indexOfPos(u8, rest, 0, "Press Enter to continue...")) |i| {
        ack_count += 1;
        rest = rest[i + "Press Enter to continue...".len ..];
    }
    try std.testing.expectEqual(@as(usize, 1), ack_count);
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
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
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
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expect(app.engine.cfg.warn_solvability);
    const restored = try settings_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expect(restored.warn_solvability);
}

test "integrated e2e: menu Settings persists auto startup/save flags to settings.json" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const cfg = config.Config.default();
    const responses = [_][]const u8{
        "menu\n", "14\n", "5\n", // auto_restore on
        "menu\n", "14\n", "6\n", // auto_new on
        "menu\n", "14\n", "7\n", // auto_save on
        "quit\n",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expect(app.engine.cfg.auto_restore);
    try std.testing.expect(app.engine.cfg.auto_new);
    try std.testing.expect(app.engine.cfg.auto_save);

    const restored = try settings_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expect(restored.auto_restore);
    try std.testing.expect(restored.auto_new);
    try std.testing.expect(restored.auto_save);
}

test "startup policy: auto_restore false and auto_new false keeps manual startup" {
    const test_defaults = @import("../../test/config_defaults.zig");
    var cfg = test_defaults.testConfigDefaults();
    cfg.difficulty = .hard;
    cfg.auto_restore = false;
    cfg.auto_new = false;
    var host = host_mod.Host.createForTest(cfg, &[0][]const u8{});
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(std.testing.io), host.writer(), null);
    defer app.deinit();

    var expected_idle: [81]u8 = undefined;
    @memset(&expected_idle, '0');
    const before = app.engine.toPuzzle();
    try app.runStartupFlow(null);
    const after = app.engine.toPuzzle();

    try std.testing.expectEqualSlices(u8, &expected_idle, &before);
    try std.testing.expectEqualSlices(u8, &before, &after);
    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, startup_policy.IDLE_STARTUP_STATUS) != null);
}

test "showGameWithStatus forwards startup status to renderer" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const cfg = test_defaults.testConfigDefaults();
    var facade_impl = DeterministicFacade{ .steps = &[_]command.ParseCommandResult{} };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.showGameWithStatus("engine ready");
    try std.testing.expectEqual(@as(usize, 1), facade_impl.render_calls);
    try std.testing.expectEqualStrings("engine ready", facade_impl.last_render_msg.?);
}

test "manual startup does not print generation progress when both auto flags are false" {
    const test_defaults = @import("../../test/config_defaults.zig");
    var cfg = test_defaults.testConfigDefaults();
    cfg.difficulty = .hard;
    cfg.auto_restore = false;
    cfg.auto_new = false;
    const responses = [_][]const u8{"quit"};
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(std.testing.io), host.writer(), null);
    defer app.deinit();

    try app.runStartupFlow(null);
    while (true) if (try app.turn()) break;

    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    var round_buf: [96]u8 = undefined;
    const round_line = puzzle_gen.formatProgressEvent(.round, &round_buf).?;
    try std.testing.expect(std.mem.indexOf(u8, output, round_line) == null);
}

test "win state stays manual: no automatic transition after You win" {
    const test_defaults = @import("../../test/config_defaults.zig");
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_new = true;

    const responses = [_][]const u8{
        "fill E5 6",
        "quit",
    };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(std.testing.io), host.writer(), null);
    defer app.deinit();

    const almost = "483921657967345821251876493548132976729504138136798245372689514814253769695417382";
    _ = app.engine.newFromOneLinePuzzle(almost);

    try app.showGame();
    while (true) if (try app.turn()) break;

    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, "You win!") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "You win!"));

    const solved = app.engine.toPuzzle();
    const expected =
        "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    try std.testing.expectEqualSlices(u8, expected, &solved);
}

fn restoreFailureScenario(delete: bool) !void {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_rel);
    const tmp_abs_z = try std.Io.Dir.cwd().realPathFileAlloc(io, data_rel, std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs_z);
    const data_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/data", .{tmp_abs_z});
    defer std.testing.allocator.free(data_path);
    try std.Io.Dir.cwd().createDirPath(io, data_path);
    const broken_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/broken.sud", .{data_path});
    defer std.testing.allocator.free(broken_path);
    const transport = file_transport.NativeTransport.make(io);
    try transport.write(transport.context, broken_path, "not a save");
    try settings_store.setCurrentFile(std.testing.allocator, io, data_path, broken_path);

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = true;
    cfg.auto_new = true;
    var facade_impl = DeterministicFacade{
        .steps = &[_]command.ParseCommandResult{},
        .replace_answers = &[_]bool{delete},
    };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport, &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();
    const before = app.engine.toPuzzle();

    try app.runStartupFlow(broken_path);

    const after = app.engine.toPuzzle();
    try std.testing.expectEqualSlices(u8, &before, &after);
    try std.testing.expectEqualStrings(startup_policy.IDLE_STARTUP_STATUS, facade_impl.last_render_msg.?);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
    try std.testing.expect(app.file_session.currentFile() == null);
    const pointer = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (pointer) |p| std.testing.allocator.free(p);
    try std.testing.expect(pointer == null);
    const still_there = if (std.Io.Dir.cwd().statFile(io, broken_path, .{})) |_| true else |_| false;
    try std.testing.expectEqual(!delete, still_there);
}

test "startup: restore failure shows the idle board, deletes the file on Delete and forgets it" {
    try restoreFailureScenario(true);
}

test "startup: restore failure keeps the file on Keep but still forgets it" {
    try restoreFailureScenario(false);
}

test "autosave: first autosave with no current file writes the visible save folder and makes it the current file" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(tmp_rel);
    const tmp_abs_z = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp_rel, std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs_z);
    const tmp_abs = tmp_abs_z;
    const data_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/data", .{tmp_abs});
    defer std.testing.allocator.free(data_path);
    const visible_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Documents/Sudoku", .{tmp_abs});
    defer std.testing.allocator.free(visible_dir);
    try std.Io.Dir.cwd().createDirPath(io, data_path);

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_save = true;

    const responses = [_][]const u8{ "fill A3 7", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = visible_dir });
    defer app.deinit();
    try app.showGame();
    while (true) if (try app.turn()) break;

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/Documents/Sudoku/sudoku.sud", .{tmp_abs});
    defer std.testing.allocator.free(expected);
    const current = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expectEqualStrings(expected, current orelse return error.TestFailed);

    const bytes = app.storage.transport.readAll(app.storage.transport.context, expected) catch return error.TestFailed;
    defer app.storage.transport.free(app.storage.transport.context, bytes);
    try std.testing.expect(bytes.len > 0);

    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, file_policy.REPLACE_CONFIRM_TITLE) == null);
}

test "autosave: successful open updates current_file pointer" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_save = false;

    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), test_defaults.testConfigDefaults());
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

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();
    try app.showGame();
    while (true) if (try app.turn()) break;

    const current = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings(tmp_path, current.?);
}

test "autosave: save failure surfaces error and keeps existing current_file pointer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const bad_path = "/tmp/sudoku_missing_parent_dir/autosave_fail.sud";

    var cfg = config.Config.default();
    cfg.auto_save = true;
    try settings_store.setCurrentFile(std.testing.allocator, io, data_path, bad_path);

    const responses = [_][]const u8{ "fill A3 7", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();
    try app.showGame();
    while (true) if (try app.turn()) break;

    const current = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings(bad_path, current.?);
    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, flow_mod.save.SAVE_FAILED_MSG) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "System") == null);
}

test "replace confirm: autosave cancel leaves existing target unchanged" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .paste = .{ .line = puzzle_gen.PuzzleGen.easy() } } },
        .{ .valid = .{ .quit = {} } },
    };
    const replace_answers = [_]bool{false};
    var facade_impl = DeterministicFacade{ .steps = &steps, .replace_answers = &replace_answers };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_defaults.DEFAULT_SAVE_FILE});
    defer std.testing.allocator.free(default_virtual);
    try transport_impl.put(default_virtual, "OLD");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var cfg = config.Config.default();
    cfg.auto_save = true;

    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = MemoryTransport.DIR });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const bytes = transport_impl.files.get(default_virtual) orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, "OLD", bytes);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
}

test "replace confirm: paste detaches and requires replace confirm before autosave overwrite" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .paste = .{ .line = puzzle_gen.PuzzleGen.easy() } } },
        .{ .valid = .{ .quit = {} } },
    };
    const replace_answers = [_]bool{false};
    var facade_impl = DeterministicFacade{ .steps = &steps, .replace_answers = &replace_answers };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_defaults.DEFAULT_SAVE_FILE});
    defer std.testing.allocator.free(default_virtual);
    try transport_impl.put(default_virtual, "OLD");
    try settings_store.setCurrentFile(std.testing.allocator, io, data_path, default_virtual);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var cfg = config.Config.default();
    cfg.auto_save = true;
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = MemoryTransport.DIR });
    defer app.deinit();
    app.file_session.write_context = .continuation;

    try app.showGame();
    while (true) if (try app.turn()) break;

    const bytes = transport_impl.files.get(default_virtual) orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, "OLD", bytes);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
}

test "replace confirm: undo autosave in detached context requires prompt before overwrite" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .undo = {} } },
        .{ .valid = .{ .quit = {} } },
    };
    const replace_answers = [_]bool{false};
    var facade_impl = DeterministicFacade{ .steps = &steps, .replace_answers = &replace_answers };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_defaults.DEFAULT_SAVE_FILE});
    defer std.testing.allocator.free(default_virtual);
    try transport_impl.put(default_virtual, "OLD");
    try settings_store.setCurrentFile(std.testing.allocator, io, data_path, default_virtual);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var cfg = config.Config.default();
    cfg.auto_save = true;
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = MemoryTransport.DIR });
    defer app.deinit();
    const almost = "483921657967345821251876493548132976729504138136798245372689514814253769695417382";
    _ = app.engine.newFromOneLinePuzzle(almost);
    _ = app.engine.exec(.{ .fill = .{ .row = 4, .col = 4, .digit = cell.CellValue.six } });
    app.file_session.write_context = .detached;

    try app.showGame();
    while (true) if (try app.turn()) break;

    const bytes = transport_impl.files.get(default_virtual) orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, "OLD", bytes);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
}

test "replace confirm: redo autosave in detached context requires prompt before overwrite" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .redo = {} } },
        .{ .valid = .{ .quit = {} } },
    };
    const replace_answers = [_]bool{false};
    var facade_impl = DeterministicFacade{ .steps = &steps, .replace_answers = &replace_answers };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_defaults.DEFAULT_SAVE_FILE});
    defer std.testing.allocator.free(default_virtual);
    try transport_impl.put(default_virtual, "OLD");
    try settings_store.setCurrentFile(std.testing.allocator, io, data_path, default_virtual);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var cfg = config.Config.default();
    cfg.auto_save = true;
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = MemoryTransport.DIR });
    defer app.deinit();
    const almost = "483921657967345821251876493548132976729504138136798245372689514814253769695417382";
    _ = app.engine.newFromOneLinePuzzle(almost);
    _ = app.engine.exec(.{ .fill = .{ .row = 4, .col = 4, .digit = cell.CellValue.six } });
    _ = app.engine.exec(.{ .undo = {} });
    app.file_session.write_context = .detached;

    try app.showGame();
    while (true) if (try app.turn()) break;

    const bytes = transport_impl.files.get(default_virtual) orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, "OLD", bytes);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
}

test "replace confirm: save cancel leaves existing target unchanged" {
    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .save = .{ .path = "/virtual/existing.sud" } } },
        .{ .valid = .{ .quit = {} } },
    };
    const replace_answers = [_]bool{false};
    var facade_impl = DeterministicFacade{ .steps = &steps, .replace_answers = &replace_answers };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    try transport_impl.put("/virtual/existing.sud", "OLD");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try Sudoku.init(config.Config.default(), facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const bytes = transport_impl.files.get("/virtual/existing.sud") orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, "OLD", bytes);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
}

test "replace confirm: save_as cancel leaves existing target unchanged" {
    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .save_as = .{ .path = "/virtual/existing.sud" } } },
        .{ .valid = .{ .quit = {} } },
    };
    const replace_answers = [_]bool{false};
    var facade_impl = DeterministicFacade{ .steps = &steps, .replace_answers = &replace_answers };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    try transport_impl.put("/virtual/existing.sud", "OLD");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try Sudoku.init(config.Config.default(), facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const bytes = transport_impl.files.get("/virtual/existing.sud") orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, "OLD", bytes);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
}

test {
    _ = @import("../../test/parity/native.zig");
}
