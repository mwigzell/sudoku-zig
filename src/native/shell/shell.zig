// Sudoku facade: owns the command loop — prompt, parse, dispatch to the
// game engine, and render each resulting event back through the renderer.
const std = @import("std");
const facade_mod = @import("../../core/renderer/facade.zig");
const frame_mod = @import("../../core/frame.zig");
const styler = @import("../ascii/styler.zig");
const game_engine = @import("../../core/engine/game_engine.zig");
const file_transport = @import("file_transport.zig");
const config = @import("../../core/config.zig");
const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");
const command = @import("../../core/command.zig");
const startup_policy = @import("../../core/startup/policy.zig");
const startup_engine = @import("../../core/startup/engine.zig");
const startup_config = @import("../../core/startup/config.zig");
const file_policy = @import("../../core/file_policy.zig");
const flow_mod = @import("../../core/flow/mod.zig");
const legend = @import("../../core/renderer/legend.zig");

const host_mod = @import("../host.zig");
const gen_progress = @import("gen_progress.zig");
const storage_mod = @import("storage.zig");
const logger = @import("../../core/logger.zig");

const log = logger.Logger(.shell);

pub const Error = error{ System, UnsupportedRenderer, NoFallbackConfigured };

const PASTE_NO_PUZZLE_MSG: []const u8 = "paste: no puzzle specified";
const NO_FLUSH_MSG: []const u8 = "flush: the terminal has no closing write";
const NO_RECLAIM_MSG: []const u8 = "reclaim_file: the terminal has no earlier-install files";

/// One running game: engine, Config and file session side by side, plus the renderer; each entry shows the game, then turns it.
pub const Sudoku = struct {
    engine: game_engine.GameEngine,
    /// The player's Config; the command flow changes it and hands the engine its fields.
    cfg: config.Config,
    renderer: facade_mod.Facade,
    storage: storage_mod.Storage,
    out: *std.Io.Writer,
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
        config_persist: ?storage_mod.ConfigPersist,
    ) Error!@This() {
        // Startup policy owns if/when puzzle generation occurs.
        var renderer_facade = facade;
        puzzle_gen.PuzzleGen.setPlayProgress(gen_progress.playProgressToFacade, @ptrCast(&renderer_facade));
        defer puzzle_gen.PuzzleGen.setPlayProgress(null, null);
        var sudoku = @This(){
            .cfg = cfg,
            .renderer = facade,
            .storage = .{ .transport = transport, .config_persist = config_persist },
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
                .forget_current_file => |forget| .{ .forgot = self.storage.forgetCurrentFile(forget) },
                .persist_config => |cfg| .{ .persisted = self.storage.persistConfig(cfg) },
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
        self.flow = .{ .command = flow_mod.CommandFlow.init(&self.engine, &self.file_session, &self.cfg, cmd) };
        switch (try self.runFlow()) {
            .show_status => |text| try self.showGameWithStatus(text),
            else => {},
        }
    }

    /// Carry out a `show_game` step: draw what core reports.
    /// A loaded game's file is also remembered for the next launch; a store that refuses that
    /// pointer write is shown core's sentence, since the next launch will not reopen the game.
    fn showStep(self: *@This(), game: flow_mod.step.ShowGame) Error!void {
        const not_remembered: ?[]const u8 = blk: {
            if (!game.loaded) break :blk null;
            const file = game.file orelse break :blk null;
            break :blk switch (self.storage.persistCurrentFile(file)) {
                .ok => null,
                .refused => |reason| flow_mod.command.loadedNotRememberedMsg(reason),
                // Not a settings repair: the game still shows, and the store's error name is recorded
                // here because no sentence would be true of it.
                .failed => |reason| logged: {
                    log.err("could not remember {s}: {s}", .{ file, reason });
                    break :logged null;
                },
            };
        };
        // The sentence takes the status slot: what the player loses at the next launch matters more
        // than the load's own words.
        if (not_remembered) |text| return self.showGameWithStatus(text);
        try self.renderer.render(game.frame);
        try self.renderer.showLegend(game.legend);
    }

    /// Dispatch one engine event to the renderer; returns true when the loop should end.
    /// `.ok.msg` rides the status slot (null shows none); `.error_msg` is core's error prompt.
    fn handleEvent(self: *@This(), event: game_engine.Event) Error!bool {
        switch (event) {
            .ok => |ev| {
                if (ev.is_quit) return true;
                try self.renderer.render(frame_mod.build(&self.engine, self.cfg, ev.msg));
                try self.renderer.showLegend(self.engine.getLegend(self.cfg.auto_save));
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
        const avail = self.engine.getLegend(self.cfg.auto_save);
        var names: [command.Commands.len][]const u8 = undefined;
        const count = avail.getNames(&names);
        const result = self.renderer.getCommandInput(names[0..count], self.cfg) catch return error.System;
        return try self.handleResult(result);
    }

    /// The first screen: the current board + legend.
    pub fn showGame(self: *@This()) Error!void {
        return self.showGameWithStatus(null);
    }

    /// First-screen render variant that allows a startup status line.
    pub fn showGameWithStatus(self: *@This(), status_msg: ?[]const u8) Error!void {
        try self.renderer.render(frame_mod.build(&self.engine, self.cfg, status_msg));
        try self.renderer.showLegend(self.engine.getLegend(self.cfg.auto_save));
    }

    /// Run the shared startup flow: restore `current_file`, start a new game, or show the idle board.
    pub fn runStartupFlow(self: *@This(), current_file: ?[]const u8) Error!void {
        const current: ?flow_mod.startup.CurrentFile = if (current_file) |path|
            .{ .path = path, .name = std.fs.path.basename(path), .current = path }
        else
            null;
        self.flow = .{ .startup = flow_mod.StartupFlow.init(&self.engine, &self.file_session, &self.cfg, current) };
        switch (try self.runFlow()) {
            // A refused forget ends startup on core's sentence, the same line the web host answers with.
            .show_status => |text| try self.showGameWithStatus(text),
            else => {},
        }
    }

    /// Release the engine and native transport session state.
    pub fn deinit(self: *@This()) void {
        self.engine.deinit();
        file_transport.NativeTransport.deinitSession();
    }
};

const board = @import("../../core/board/board.zig");
const cell = @import("../../core/board/cell.zig");
const styler_t = @import("../ascii/styler.zig");
const ascii_renderer = @import("../ascii/renderer.zig");

const config_store = @import("../../core/config_store.zig");
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
    last_marks_visible: bool = false,
    last_legend: ?legend.Legend = null,
    replace_answers: []const bool = &[_]bool{},
    replace_idx: usize = 0,

    /// Renderer seam backed by this scripted facade.
    pub fn asFacade(self: *@This()) facade_mod.Facade {
        return facade_mod.Make(@This()).make(self);
    }

    /// Records render calls from Sudoku.handleEvent for deterministic branch tests.
    pub fn render(self: *@This(), frame: facade_mod.Frame) !void {
        self.render_calls += 1;
        self.last_marks_visible = frame.marks_visible;
        self.last_render_msg = frame.status;
    }

    /// Records legend refreshes from successful event handling, keeping the last one shown.
    pub fn showLegend(self: *@This(), shown: legend.Legend) !void {
        self.legend_calls += 1;
        self.last_legend = shown;
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
        _: config.Config,
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

const MemoryTransport = @import("../../test/support/memory_transport.zig").MemoryTransport;

test "with Show Pencil Marks off, a pencil command draws the board with marks and the next other command without" {
    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .pencil = .{ .row = 2, .col = 0, .digit = .five } } },
        .{ .valid = .{ .fill = .{ .row = 2, .col = 0, .digit = .seven } } },
    };
    var facade_impl = DeterministicFacade{ .steps = &steps };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var cfg = config.Config.default();
    cfg.show_marks = false;
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    _ = try app.turn();
    try std.testing.expect(facade_impl.last_marks_visible);
    _ = try app.turn();
    try std.testing.expect(!facade_impl.last_marks_visible);
}

test "new shows core's generation progress through the renderer" {
    const cfg: config.Config = .{
        .difficulty = .easy,
        .renderers = .{ .preferred = .ascii, .fallback = .ascii },
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
    cfg.renderers.preferred = .ansi;
    cfg.renderers.fallback = .ansi;
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
    cfg.renderers.preferred = .ansi;
    cfg.renderers.fallback = .ansi;
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
// Full end-to-end run through the host-built ansi facade
test "integrated e2e - run: host-built ansi facade processes quit cleanly" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
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
        .renderers = .{ .preferred = .ascii, .fallback = .ascii },
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
    try sudoku.renderer.render(.{ .board = sudoku.engine.state.board.asView() });

    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "A B C │ D E F") != null);
    // PlainStyler: no CSI escapes anywhere in the rendered output.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\x1b[") == null);
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

test "startup: an accepted new game is written and shows core's saved-to line before the first turn" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const solved_line = "534678912672195348198342567859761423426853791713924856961537284287419635345286179";
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var transport = MemoryTransport.init(std.testing.allocator);
    defer transport.deinit();
    var solved = try game_engine.GameEngine.init(solved_line, test_defaults.testConfigDefaults());
    defer solved.deinit();
    const bytes = try solved.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try transport.put(MemoryTransport.DIR ++ "/startup.sud", bytes);

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = true;
    cfg.auto_new = true;
    cfg.auto_save = true;
    var facade_impl = DeterministicFacade{ .steps = &[_]command.ParseCommandResult{}, .replace_answers = &[_]bool{true} };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport.asTransport(), &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = MemoryTransport.DIR });
    defer app.deinit();

    try app.runStartupFlow("startup.sud");

    // One question (the solved prompt); the write itself is a continuation and does not ask.
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(file_policy.SAVED_TO_FMT, .{MemoryTransport.DIR ++ "/startup.sud"}), facade_impl.last_render_msg.?);
    try std.testing.expect(!app.engine.state.board.isSolved());
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
    try config_store.setCurrentFile(std.testing.allocator, io, data_path, broken_path);

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
    const pointer = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
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

test "startup: a refused forget leaves the save, shows core's sentence and ends" {
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
    try config_store.setCurrentFile(std.testing.allocator, io, data_path, broken_path);

    // Settings that read and refuse writes: the pointer cannot be cleared, which is the whole point.
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, config_store.file_name });
    defer std.testing.allocator.free(config_path);
    try std.Io.Dir.cwd().setFilePermissions(io, config_path, .fromMode(0o444), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io, config_path, .fromMode(0o644), .{}) catch {};
    const probe = std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = config_path, .data = "", .flags = .{ .truncate = false } });
    if (probe) |_| return error.SkipZigTest else |_| {}

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = true;
    cfg.auto_new = true;
    var facade_impl = DeterministicFacade{
        .steps = &[_]command.ParseCommandResult{},
        .replace_answers = &[_]bool{true},
    };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport, &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.runStartupFlow(broken_path);

    // The clear was refused before the file was touched, so Delete left it in place.
    _ = try std.Io.Dir.cwd().statFile(io, broken_path, .{});
    try std.testing.expectEqualStrings(startup_config.SETTINGS_WRITE_FAILED_MSG, facade_impl.last_render_msg.?);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
    const pointer = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (pointer) |p| std.testing.allocator.free(p);
    try std.testing.expectEqualStrings(broken_path, pointer orelse return error.TestFailed);
}

test "startup: a forget the adapter could not complete shows core's generic failure and keeps the save" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const forget_mod = @import("../../core/flow/forget.zig");
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

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = true;
    cfg.auto_new = true;
    var facade_impl = DeterministicFacade{
        .steps = &[_]command.ParseCommandResult{},
        .replace_answers = &[_]bool{true},
    };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport, &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();
    // A store that fails inside its own path work: neither an unreadable nor an unwritable
    // settings file, so no repair sentence is true of it.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    app.storage.gpa = failing.allocator();

    try app.runStartupFlow(broken_path);

    // The clear failed before the delete, so the file Delete asked for is still on disk.
    _ = try std.Io.Dir.cwd().statFile(io, broken_path, .{});
    try std.testing.expectEqualStrings(forget_mod.FAILED_MSG, facade_impl.last_render_msg.?);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
}

test "save: a refused pointer write shows core's sentence and leaves the game file written" {
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
    // A config.json taken by a directory: no read of it succeeds, for root or an ordinary user.
    const config_as_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, config_store.file_name });
    defer std.testing.allocator.free(config_as_dir);
    try std.Io.Dir.cwd().createDirPath(io, config_as_dir);
    const save_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/saves", .{tmp_abs_z});
    defer std.testing.allocator.free(save_dir);
    try std.Io.Dir.cwd().createDirPath(io, save_dir);
    const game = try std.fmt.allocPrint(std.testing.allocator, "{s}/game.sud", .{save_dir});
    defer std.testing.allocator.free(game);

    const steps = [_]command.ParseCommandResult{.{ .valid = .{ .save = .{ .path = game } } }};
    var facade_impl = DeterministicFacade{ .steps = &steps };
    const transport = file_transport.NativeTransport.make(io);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_save = false;
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport, &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = save_dir });
    defer app.deinit();

    try app.showGame();
    try std.testing.expect(!try app.turn());

    // The bytes landed before the pointer write was refused, so core's sentence says the game
    // file was written and the save is on disk.
    try std.testing.expectEqualStrings(flow_mod.save.WRITTEN_SETTINGS_REFUSED_MSG, facade_impl.last_render_msg.?);
    _ = try std.Io.Dir.cwd().statFile(io, game, .{});
}

test "open: a refused pointer write draws the loaded game and shows core's sentence" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(tmp_rel);
    const tmp_abs_z = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp_rel, std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs_z);
    const data_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/data", .{tmp_abs_z});
    defer std.testing.allocator.free(data_path);
    try std.Io.Dir.cwd().createDirPath(io, data_path);
    // A config.json taken by a directory: no read of it succeeds, for root or an ordinary user.
    const config_as_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, config_store.file_name });
    defer std.testing.allocator.free(config_as_dir);
    try std.Io.Dir.cwd().createDirPath(io, config_as_dir);

    const puzzle = "530070000600195000098000060800060003400803001700020006060000280000419005000080079";
    const save_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/saves", .{tmp_abs_z});
    defer std.testing.allocator.free(save_dir);
    try std.Io.Dir.cwd().createDirPath(io, save_dir);
    const game = try std.fmt.allocPrint(std.testing.allocator, "{s}/game.sud", .{save_dir});
    defer std.testing.allocator.free(game);
    var source = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), test_defaults.testConfigDefaults());
    defer source.deinit();
    _ = source.newFromOneLinePuzzle(puzzle);
    const saved = try source.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(saved);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = game, .data = saved });

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = false;
    cfg.auto_new = false;
    cfg.auto_save = false;
    const steps = [_]command.ParseCommandResult{.{ .valid = .{ .open = .{ .path = game } } }};
    var facade_impl = DeterministicFacade{ .steps = &steps };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), file_transport.NativeTransport.make(io), &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = save_dir });
    defer app.deinit();
    try app.showGame();
    try std.testing.expect(!try app.turn());

    // The game is on screen, and core says the next launch will not reopen it.
    try std.testing.expectEqualStrings(puzzle, &app.engine.toPuzzle());
    try std.testing.expectEqualStrings(flow_mod.command.LOADED_SETTINGS_REFUSED_MSG, facade_impl.last_render_msg.?);
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
    const current = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
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

    const current = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
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
    try config_store.setCurrentFile(std.testing.allocator, io, data_path, bad_path);

    const responses = [_][]const u8{ "fill A3 7", "quit" };
    var host = host_mod.Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();
    try app.showGame();
    while (true) if (try app.turn()) break;

    const current = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
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
    try config_store.setCurrentFile(std.testing.allocator, io, data_path, default_virtual);
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
    try config_store.setCurrentFile(std.testing.allocator, io, data_path, default_virtual);
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
    try config_store.setCurrentFile(std.testing.allocator, io, data_path, default_virtual);
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
    var cfg = config.Config.default();
    cfg.auto_save = false;

    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
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

/// Whether the legend the shell last showed listed `name`.
fn legendOffers(facade_impl: *const DeterministicFacade, name: []const u8) bool {
    const shown = facade_impl.last_legend orelse return false;
    var names: [command.Commands.len][]const u8 = undefined;
    const count = shown.getNames(&names);
    for (names[0..count]) |offered| if (std.mem.eql(u8, offered, name)) return true;
    return false;
}

test "bookmark, rewind, redo: the shell shows core's move numbers and Rewind only while it can act" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const bookmark_command = @import("../../core/engine/bookmark.zig");
    // A classic puzzle: A3, A4 and A6 are empty, so each fill is a legal move.
    const puzzle = "530070000600195000098000060800060003400803001700020006060000280000419005000080079";
    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .fill = .{ .row = 0, .col = 2, .digit = .four } } }, // move 1
        .{ .valid = .{ .bookmark = {} } },
        .{ .valid = .{ .fill = .{ .row = 0, .col = 3, .digit = .six } } }, // move 2
        .{ .valid = .{ .fill = .{ .row = 0, .col = 5, .digit = .eight } } }, // move 3
        .{ .valid = .{ .rewind = {} } },
        .{ .valid = .{ .redo = {} } },
        .{ .valid = .{ .undo = {} } }, // lands on the bookmark: kept
        .{ .valid = .{ .undo = {} } }, // below it: forgotten
        .{ .valid = .{ .redo = {} } },
        .{ .valid = .{ .quit = {} } },
    };
    var facade_impl = DeterministicFacade{ .steps = &steps };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_save = false;

    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();
    // A known puzzle keeps the moves below about the board, not about what the generator chose.
    _ = app.engine.newFromOneLinePuzzle(puzzle);
    try app.showGame();

    // Move 1, no bookmark: Bookmark is always on the line, Rewind is not.
    try std.testing.expect(!try app.turn());
    try std.testing.expect(facade_impl.legend_calls > 0);
    try std.testing.expect(legendOffers(&facade_impl, "Bookmark"));
    try std.testing.expect(!legendOffers(&facade_impl, "Rewind"));

    // Bookmark names the move it pins.
    try std.testing.expect(!try app.turn());
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(bookmark_command.BOOKMARK_SET_FMT, .{1}), facade_impl.last_render_msg.?);

    // Two fills leave the bookmark behind the pointer, so Rewind joins the line.
    try std.testing.expect(!try app.turn());
    try std.testing.expect(!try app.turn());
    try std.testing.expectEqual(@as(usize, 3), app.engine.state.history.pointer);
    try std.testing.expect(legendOffers(&facade_impl, "Rewind"));

    // Rewind returns to the bookmarked move in one step.
    try std.testing.expect(!try app.turn());
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(bookmark_command.REWOUND_FMT, .{1}), facade_impl.last_render_msg.?);
    try std.testing.expectEqual(@as(usize, 1), app.engine.state.history.pointer);
    try std.testing.expectEqual(cell.CellValue.four, app.engine.state.board.getCellValue(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, app.engine.state.board.getCellValue(0, 3));
    try std.testing.expectEqual(cell.CellValue.zero, app.engine.state.board.getCellValue(0, 5));
    // At the bookmark there is nothing to rewind to, and Redo still has work.
    try std.testing.expect(!legendOffers(&facade_impl, "Rewind"));
    try std.testing.expect(app.engine.getLegend(cfg.auto_save).redo);

    // Redo replays one undone move, which leaves Rewind able to act again.
    try std.testing.expect(!try app.turn());
    try std.testing.expectEqual(@as(usize, 2), app.engine.state.history.pointer);
    try std.testing.expectEqual(cell.CellValue.six, app.engine.state.board.getCellValue(0, 3));
    try std.testing.expectEqual(cell.CellValue.zero, app.engine.state.board.getCellValue(0, 5));
    try std.testing.expect(legendOffers(&facade_impl, "Rewind"));

    // An undo that lands on the bookmark keeps it; the next undo is below it, so it is forgotten.
    try std.testing.expect(!try app.turn());
    try std.testing.expectEqual(@as(?u16, 1), app.engine.state.bookmark);
    try std.testing.expect(!legendOffers(&facade_impl, "Rewind"));
    try std.testing.expect(!try app.turn());
    try std.testing.expectEqual(@as(?u16, null), app.engine.state.bookmark);
    try std.testing.expect(!legendOffers(&facade_impl, "Rewind"));

    // Redo past where the bookmark sat does not bring it back.
    try std.testing.expect(!try app.turn());
    try std.testing.expectEqual(@as(usize, 1), app.engine.state.history.pointer);
    try std.testing.expectEqual(@as(?u16, null), app.engine.state.bookmark);
    try std.testing.expect(!legendOffers(&facade_impl, "Rewind"));
    try std.testing.expectEqual(@as(usize, 0), facade_impl.error_calls);
}

test {
    _ = @import("../../test/parity/native.zig");
}
