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
const settings_store = @import("../../core/settings_store.zig");
const startup_policy = @import("../../core/startup/policy.zig");
const startup_engine = @import("../../core/startup/engine.zig");
const file_policy = @import("../../core/file_policy.zig");
const flow_mod = @import("../../core/flow/mod.zig");
const path_mod = @import("path.zig");

const disambiguate = @import("../ascii/disambiguate.zig");
const legend = @import("../../core/renderer/legend.zig");

const host_mod = @import("../host.zig");
const save_command = @import("save.zig");
const export_command = @import("export.zig");
const save_as_command = @import("save_as.zig");
const read_path = @import("read_path.zig");
const gen_progress = @import("gen_progress.zig");
pub const Error = error{ System, UnsupportedRenderer, NoFallbackConfigured };

const COPY_WRITE_FAILED_MSG: []const u8 = "copy: write failed";
const OPEN_NO_FILE_MSG: []const u8 = "open: no file specified";
const IMPORT_NO_FILE_MSG: []const u8 = "import: no file specified";
const PASTE_NO_LINE_MSG: []const u8 = "paste: no puzzle line specified";

/// One running game: engine + renderer; each entry shows the game, then turns it.
pub const SettingsPersist = struct {
    io: std.Io,
    data_dir: []const u8,
    /// User-visible folder for the default autosave file when there is no working file.
    visible_save_dir: []const u8,
};

pub const Sudoku = struct {
    engine: game_engine.GameEngine,
    cfg: config.Config,
    renderer: facade_mod.Facade,
    transport: file_transport.FileTransport,
    out: *std.Io.Writer,
    settings_persist: ?SettingsPersist = null,
    last_cell: ?facade_mod.Selection = null,
    file_session: flow_mod.FileSession = .{},
    /// The one flow in progress; terminal step text points into it until the next flow starts.
    flow: flow_mod.Flow = undefined,
    /// Holds a flow's terminal text once it becomes an event, so later flows cannot overwrite it.
    flow_text: [256]u8 = undefined,

    /// How a flow's `write` step is carried out: Save records its status in the game, autosave does not,
    /// and Export writes only the puzzle line without making it the working file.
    const WriteMode = enum { save, autosave, export_line };

    /// Assemble a fresh game from the shared user-choices, a renderer facade,
    /// and the file transport arm the deployment selected.
    pub fn init(
        cfg: config.Config,
        facade: facade_mod.Facade,
        transport: file_transport.FileTransport,
        out: *std.Io.Writer,
        settings_persist: ?SettingsPersist,
    ) Error!@This() {
        // Startup policy owns if/when puzzle generation occurs.
        var renderer_facade = facade;
        puzzle_gen.PuzzleGen.setPlayProgress(gen_progress.playProgressToFacade, @ptrCast(&renderer_facade));
        defer puzzle_gen.PuzzleGen.setPlayProgress(null, null);
        var sudoku = @This(){
            .cfg = cfg,
            .renderer = facade,
            .transport = transport,
            .out = out,
            .settings_persist = settings_persist,
            .engine = try startup_engine.initEngineFromStartup(cfg),
        };
        if (settings_persist) |sp| {
            const current = settings_store.loadCurrentFile(std.heap.page_allocator, sp.io, sp.data_dir) catch null;
            defer if (current) |p| std.heap.page_allocator.free(p);
            sudoku.file_session.setWorkingFile(current);
        }
        return sudoku;
    }

    /// Carry out a `persist_settings` step; without settings persistence there is nowhere to write.
    fn persistSettings(self: *@This(), cfg: config.Config) flow_mod.step.Outcome {
        self.cfg = cfg;
        const sp = self.settings_persist orelse return .ok;
        settings_store.save(std.heap.page_allocator, sp.io, sp.data_dir, cfg) catch |err| return .{ .failed = @errorName(err) };
        return .ok;
    }

    fn pathExists(self: *@This(), path: []const u8) bool {
        const resolved = self.transport.resolve(self.transport.context, path) catch return false;
        defer self.transport.free(self.transport.context, resolved);
        const bytes = self.transport.readAll(self.transport.context, resolved) catch |err| switch (err) {
            file_transport.TransportError.FileNotFound => return false,
            file_transport.TransportError.AccessDenied => return true,
            else => return false,
        };
        self.transport.free(self.transport.context, bytes);
        return true;
    }

    /// Owned `<visible_save_dir>/sudoku.sud`; null without settings persistence.
    /// Only the default folder is created on demand; a missing working-file folder must still fail the write.
    fn defaultVisibleSavePath(self: *@This()) ?[]u8 {
        const sp = self.settings_persist orelse return null;
        std.Io.Dir.cwd().createDirPath(sp.io, sp.visible_save_dir) catch {};
        return path_mod.resolveSavePath(std.heap.page_allocator, sp.visible_save_dir, save_command.DEFAULT_SAVE_FILE) catch null;
    }

    fn persistCurrentFile(self: *@This(), path: ?[]const u8) void {
        const sp = self.settings_persist orelse return;
        settings_store.setCurrentFile(std.heap.page_allocator, sp.io, sp.data_dir, path) catch {};
    }

    /// Carry out a `write` step; `scratch` holds the reported name or error text.
    fn writeTarget(self: *@This(), mode: WriteMode, name: []const u8, scratch: []u8) flow_mod.Wrote {
        const resolved = self.transport.resolve(self.transport.context, name) catch |err| {
            return .{ .failed = std.fmt.bufPrint(scratch, "resolve: {s}", .{@errorName(err)}) catch "system error" };
        };
        defer self.transport.free(self.transport.context, resolved);

        switch (mode) {
            .save => switch (save_as_command.execute(&self.engine, self.transport, resolved)) {
                .ok => {},
                .error_msg => |msg| return .{ .failed = copyInto(scratch, msg) },
            },
            .autosave => {
                const save_buf = self.engine.toSaveFormat(std.heap.page_allocator) catch |err| return .{ .failed = @errorName(err) };
                defer std.heap.page_allocator.free(save_buf);
                self.transport.write(self.transport.context, resolved, save_buf) catch |err| return .{ .failed = @errorName(err) };
            },
            .export_line => {
                const line = export_command.currentPuzzleLine(&self.engine);
                self.transport.write(self.transport.context, resolved, &line) catch |err| return .{ .failed = @errorName(err) };
                return .{ .ok = copyInto(scratch, resolved) };
            },
        }
        self.persistCurrentFile(resolved);
        return .{ .ok = copyInto(scratch, resolved) };
    }

    fn copyInto(scratch: []u8, text: []const u8) []const u8 {
        const len = @min(text.len, scratch.len);
        std.mem.copyForwards(u8, scratch[0..len], text[0..len]);
        return scratch[0..len];
    }

    /// Carry out a `read_file` step; on success the bytes are owned by the caller.
    fn readFile(self: *@This(), path: []const u8, scratch: []u8) flow_mod.step.FileRead {
        var stage: read_path.Stage = .resolve;
        const read = read_path.readFileBytes(self.transport, path, &stage) catch |err| {
            const label: []const u8 = switch (stage) {
                .resolve => "resolve",
                .read => "readAll",
            };
            return .{ .failed = std.fmt.bufPrint(scratch, "{s}: {s}", .{ label, @errorName(err) }) catch "system error" };
        };
        self.transport.free(self.transport.context, read.resolved);
        return .{ .bytes = read.bytes };
    }

    /// Carry out a `pick_open` step: the terminal has no picker, so read the path typed with the command.
    /// On success `read` owns the bytes and resolved path until the flow takes the next step.
    fn pickOpen(self: *@This(), pick: flow_mod.step.PickOpen, scratch: []u8, read: *?read_path.ReadResult) flow_mod.step.Picked {
        const path = pick.path orelse return .{ .failed = switch (pick.kind) {
            .game => OPEN_NO_FILE_MSG,
            .puzzle => IMPORT_NO_FILE_MSG,
        } };
        var stage: read_path.Stage = .resolve;
        const got = read_path.readFileBytes(self.transport, path, &stage) catch |err| {
            const label: []const u8 = switch (stage) {
                .resolve => "resolve",
                .read => "readAll",
            };
            return .{ .failed = std.fmt.bufPrint(scratch, "{s}: {s}", .{ label, @errorName(err) }) catch "system error" };
        };
        read.* = got;
        return .{ .file = .{ .bytes = got.bytes, .name = got.resolved } };
    }

    /// Carry out a `forget_current_file` step: stop restoring it, and delete it when asked.
    fn forgetCurrentFile(self: *@This(), forget: flow_mod.step.ForgetCurrentFile) void {
        const sp = self.settings_persist orelse return;
        if (forget.delete) delete: {
            const resolved = self.transport.resolve(self.transport.context, forget.path) catch break :delete;
            defer self.transport.free(self.transport.context, resolved);
            std.Io.Dir.deleteFileAbsolute(sp.io, resolved) catch {};
        }
        self.persistCurrentFile(null);
    }

    /// Drive `self.flow` to its terminal step, carrying out each step on this platform.
    fn runFlow(self: *@This(), mode: WriteMode) Error!flow_mod.Step {
        var scratch: [flow_mod.file_session.MAX_NAME_LEN]u8 = undefined;
        var step = self.flow.next(.start);
        while (!flow_mod.isTerminal(step)) {
            var read_bytes: ?[]u8 = null;
            defer if (read_bytes) |b| self.transport.free(self.transport.context, b);
            var opened: ?read_path.ReadResult = null;
            defer if (opened) |o| {
                self.transport.free(self.transport.context, o.resolved);
                self.transport.free(self.transport.context, o.bytes);
            };
            const input: flow_mod.Input = switch (step) {
                .resolve_default_target => blk: {
                    const default_visible = self.defaultVisibleSavePath();
                    defer if (default_visible) |p| std.heap.page_allocator.free(p);
                    break :blk .{ .default_target = copyInto(&scratch, default_visible orelse save_command.DEFAULT_SAVE_FILE) };
                },
                .check_target => |name| .{ .target_checked = self.pathExists(name) },
                .ask => |question| .{ .answered = try self.renderer.ask(question) },
                .write => |name| .{ .wrote = self.writeTarget(mode, name, &scratch) },
                .read_file => |path| blk: {
                    const read = self.readFile(path, &scratch);
                    if (read == .bytes) read_bytes = @constCast(read.bytes);
                    break :blk .{ .file_read = read };
                },
                .pick_open => |pick| .{ .picked = self.pickOpen(pick, &scratch, &opened) },
                // The terminal has no clipboard; Paste takes its line with the command.
                .read_clipboard => .{ .file_read = .{ .failed = PASTE_NO_LINE_MSG } },
                .show_game => |game| blk: {
                    try self.showStep(game);
                    break :blk .ack;
                },
                .generate => |difficulty| .{ .generated = .{ .line = puzzle_gen.PuzzleGen.generate(difficulty) } },
                .forget_current_file => |forget| blk: {
                    self.forgetCurrentFile(forget);
                    break :blk .ack;
                },
                .persist_settings => |cfg| .{ .persisted = self.persistSettings(cfg) },
                .copy_line => .{ .copied = self.printPuzzleLine() },
                // Pickers follow only a `taken` write, which native writes never report.
                .pick_existing, .pick_new => unreachable,
                .show_status, .show_error, .done => unreachable,
            };
            step = self.flow.next(input);
        }
        return step;
    }

    /// Carry out a `copy_line` step: the terminal has no clipboard, so print the line for the player to copy.
    fn printPuzzleLine(self: *@This()) flow_mod.step.Outcome {
        const line = export_command.currentPuzzleLine(&self.engine);
        self.out.writeAll(&line) catch return .{ .failed = COPY_WRITE_FAILED_MSG };
        self.out.writeAll("\n") catch return .{ .failed = COPY_WRITE_FAILED_MSG };
        return .ok;
    }

    /// Map a flow's terminal step to the event the loop shows; `done` shows `otherwise`.
    fn flowEvent(self: *@This(), terminal: flow_mod.Step, otherwise: game_engine.Event) game_engine.Event {
        return switch (terminal) {
            .show_status => |text| .{ .ok = .{
                .board_view = self.engine.eventBoard(),
                .msg = copyInto(&self.flow_text, text),
                .is_quit = false,
            } },
            .show_error => |msg| .{ .error_msg = copyInto(&self.flow_text, msg) },
            else => otherwise,
        };
    }

    fn runSaveFlow(self: *@This(), intent: file_policy.WriteIntent, path: []const u8) Error!game_engine.Event {
        self.flow = .{ .save = flow_mod.SaveFlow.forCommand(&self.file_session, intent, path, self.engine.cfg.auto_save) };
        const terminal = try self.runFlow(.save);
        return self.flowEvent(terminal, .{ .ok = .{
            .board_view = self.engine.eventBoard(),
            .msg = null,
            .is_quit = false,
        } });
    }

    fn runExportFlow(self: *@This(), export_flow: flow_mod.ExportFlow) Error!game_engine.Event {
        self.flow = .{ .@"export" = export_flow };
        const terminal = try self.runFlow(.export_line);
        return self.flowEvent(terminal, .{ .ok = .{
            .board_view = self.engine.eventBoard(),
            .msg = null,
            .is_quit = false,
        } });
    }

    fn runCommandFlow(self: *@This(), cmd: command.Command) Error!void {
        self.flow = .{ .command = flow_mod.CommandFlow.init(&self.engine, &self.file_session, cmd) };
        switch (try self.runFlow(.autosave)) {
            .show_status => |text| try self.showGameWithStatus(text),
            .show_error => |msg| try self.renderer.showError(msg),
            else => {},
        }
    }

    /// Carry out a `show_game` step: draw what core reports, remembering the edited cell for region shading.
    /// A loaded game's file is also remembered for the next launch.
    fn showStep(self: *@This(), game: flow_mod.step.ShowGame) Error!void {
        if (game.loaded) {
            self.last_cell = null;
            if (game.file) |file| self.persistCurrentFile(file);
        }
        if (game.cell) |c| self.last_cell = c;
        const region: ?facade_mod.Selection = if (game.config.show_region) self.last_cell else null;
        try self.renderer.render(game.board, game.status, region);
        try self.renderer.showLegend(game.legend);
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
                const event = switch (cmd) {
                    .save => |data| try self.runSaveFlow(.save, data.path orelse save_command.DEFAULT_SAVE_FILE),
                    .save_as => |data| try self.runSaveFlow(.save_as, data.path orelse save_command.DEFAULT_SAVE_FILE),
                    .@"export" => |data| try self.runExportFlow(flow_mod.ExportFlow.toFile(data.path)),
                    .copy => try self.runExportFlow(flow_mod.ExportFlow.toClipboard()),
                    .quit => self.engine.exec(cmd),
                    else => {
                        try self.runCommandFlow(cmd);
                        return false;
                    },
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
            .{ .path = path, .name = std.fs.path.basename(path), .working = path }
        else
            null;
        self.flow = .{ .startup = flow_mod.StartupFlow.init(&self.engine, &self.file_session, .{
            .auto_restore = self.engine.cfg.auto_restore,
            .auto_new = self.engine.cfg.auto_new,
            .difficulty = self.engine.cfg.difficulty,
        }, current) };
        switch (try self.runFlow(.save)) {
            .show_error => |msg| try self.renderer.showError(msg),
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
const logger = @import("../../core/logger.zig");
const styler_t = @import("../ascii/styler.zig");
const ascii_renderer = @import("../ascii/renderer.zig");

const test_doubles = @import("test_doubles.zig");
const DeterministicFacade = test_doubles.DeterministicFacade;
const MemoryTransport = test_doubles.MemoryTransport;

test {
    _ = @import("parity_test.zig");
}

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

    const expected = try board.fromOneLineString(puzzle_gen.PuzzleGen.medium());
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

test "save shows its saved-to status after the later flows run" {
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_save_status_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    const cfg = config.Config.default();
    const responses = [_][]const u8{ "m", "1", tmp_path ++ "\n", "quit" };
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
    try std.testing.expect(std.mem.indexOf(u8, output, "saved to: " ++ tmp_path) != null);
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

    const board_mod = @import("../../core/board/board.zig");
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

    const board_mod = @import("../../core/board/board.zig");
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
    const before = export_command.currentPuzzleLine(&app.engine);
    try app.runStartupFlow(null);
    const after = export_command.currentPuzzleLine(&app.engine);

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
    try std.testing.expect(std.mem.indexOf(u8, output, "Generating:") == null);
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

    const solved = export_command.currentPuzzleLine(&app.engine);
    const expected =
        "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    try std.testing.expectEqualSlices(u8, expected, &solved);
}

test "startup policy: auto_restore true restores from current_file path" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_startup_restore_ok.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    var cfg = test_defaults.testConfigDefaults();
    cfg.difficulty = .hard;
    cfg.auto_restore = true;

    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), test_defaults.testConfigDefaults());
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

    try app.runStartupFlow(tmp_path);
    try std.testing.expectEqualStrings(tmp_path, app.file_session.workingFile().?);
    try std.testing.expectEqual(saved_b2, app.engine.eventBoard().get(1, 1));
}

test "startup policy: solved restore prompt cancel keeps restored solved board" {
    const test_defaults = @import("../../test/config_defaults.zig");
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = true;
    cfg.auto_new = true;

    const solved = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    var saved_engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    defer saved_engine.deinit();
    _ = saved_engine.newFromOneLinePuzzle(solved);
    const save_buf = try saved_engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(save_buf);

    var facade_impl = DeterministicFacade{
        .steps = &[_]command.ParseCommandResult{},
        .replace_answers = &[_]bool{false},
    };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    try transport_impl.put("/startup.sud", save_buf);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.runStartupFlow("/startup.sud");
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
    try std.testing.expect(app.engine.state.board.isSolved());
    try std.testing.expectEqual(file_policy.WriteContext.continuation, app.file_session.write_context);
}

test "startup policy: solved restore prompt confirm starts fresh game" {
    const test_defaults = @import("../../test/config_defaults.zig");
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = true;
    cfg.auto_new = true;
    cfg.difficulty = .easy;

    const solved = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    var saved_engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    defer saved_engine.deinit();
    _ = saved_engine.newFromOneLinePuzzle(solved);
    const save_buf = try saved_engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(save_buf);

    var facade_impl = DeterministicFacade{
        .steps = &[_]command.ParseCommandResult{},
        .replace_answers = &[_]bool{true},
    };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    try transport_impl.put("/startup.sud", save_buf);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, null);
    defer app.deinit();

    try app.runStartupFlow("/startup.sud");
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
    try std.testing.expect(!app.engine.state.board.isSolved());
    try std.testing.expectEqual(file_policy.WriteContext.detached, app.file_session.write_context);
}

test "startup policy: relaunch restores latest autosave without rewriting givens" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    const FixtureMove = struct {
        row: u8,
        col: u8,
        digit: u8,
    };
    const FixtureProbe = struct {
        row: u8,
        col: u8,
        value: u8,
    };
    const AutosaveRestoreParityFixture = struct {
        puzzle_line: []const u8,
        moves: []const FixtureMove,
        given_probe: FixtureProbe,
        move_probes: []const FixtureProbe,
    };

    const fixture_path = "src/test/fixtures/autosave_restore_parity.json";
    const fixture_bytes = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        fixture_path,
        std.testing.allocator,
        std.Io.Limit.unlimited,
    );
    defer std.testing.allocator.free(fixture_bytes);
    const fixture_json = try std.json.parseFromSlice(
        AutosaveRestoreParityFixture,
        std.testing.allocator,
        fixture_bytes,
        .{},
    );
    defer fixture_json.deinit();
    const fixture = fixture_json.value;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path_rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path_rel);
    const data_path_abs_z = try std.Io.Dir.cwd().realPathFileAlloc(io, data_path_rel, std.testing.allocator);
    defer std.testing.allocator.free(data_path_abs_z);
    const data_path = data_path_abs_z[0 .. data_path_abs_z.len - 1];

    const seed_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/autosave-relaunch.sud", .{data_path});
    defer std.testing.allocator.free(seed_path);
    try settings_store.setCurrentFile(std.testing.allocator, io, data_path, seed_path);

    var first_cfg = test_defaults.testConfigDefaults();
    first_cfg.auto_save = true;
    const first_responses = [_][]const u8{};
    var first_host = host_mod.Host.createForTest(first_cfg, &first_responses);
    defer first_host.deinit();
    var first_facade = try first_host.facade();
    defer first_facade.deinit();

    var first_app = try Sudoku.init(first_cfg, first_facade, file_transport.NativeTransport.make(io), first_host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer first_app.deinit();
    _ = first_app.engine.newFromOneLinePuzzle(fixture.puzzle_line);
    for (fixture.moves) |move| {
        const row: u4 = @intCast(move.row);
        const col: u4 = @intCast(move.col);
        const fill_cmd: command.Command = .{
            .fill = .{
                .row = row,
                .col = col,
                .digit = cell.rawToCellValue(move.digit),
            },
        };
        try first_app.runCommandFlow(fill_cmd);
    }

    const expected_board = first_app.engine.state.board;
    const expected_history_pointer = first_app.engine.state.history.pointer;
    const expected_history_len = first_app.engine.state.history.entries.items.len;
    const expected_save = try first_app.engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(expected_save);

    var second_cfg = test_defaults.testConfigDefaults();
    second_cfg.auto_restore = true;
    const second_responses = [_][]const u8{};
    var second_host = host_mod.Host.createForTest(second_cfg, &second_responses);
    defer second_host.deinit();
    var second_facade = try second_host.facade();
    defer second_facade.deinit();

    var second_app = try Sudoku.init(second_cfg, second_facade, file_transport.NativeTransport.make(io), second_host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer second_app.deinit();

    const current = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current != null);

    try second_app.runStartupFlow(current.?);

    try std.testing.expect(board.equal(expected_board, second_app.engine.state.board));
    try std.testing.expectEqual(expected_history_pointer, second_app.engine.state.history.pointer);
    try std.testing.expectEqual(expected_history_len, second_app.engine.state.history.entries.items.len);
    const given_row: u4 = @intCast(fixture.given_probe.row);
    const given_col: u4 = @intCast(fixture.given_probe.col);
    try std.testing.expectEqual(
        cell.rawToCellValue(fixture.given_probe.value),
        second_app.engine.state.board.getCellValue(given_row, given_col),
    );
    try std.testing.expect(second_app.engine.state.board.isGiven(given_row, given_col));
    for (fixture.move_probes) |probe| {
        const probe_row: u4 = @intCast(probe.row);
        const probe_col: u4 = @intCast(probe.col);
        try std.testing.expectEqual(
            cell.rawToCellValue(probe.value),
            second_app.engine.state.board.getCellValue(probe_row, probe_col),
        );
        try std.testing.expect(!second_app.engine.state.board.isGiven(probe_row, probe_col));
    }
    const restored_save = try second_app.engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(restored_save);
    try std.testing.expectEqualSlices(u8, expected_save, restored_save);
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
    const data_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/data", .{tmp_abs_z[0 .. tmp_abs_z.len - 1]});
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
    const before = export_command.currentPuzzleLine(&app.engine);

    try app.runStartupFlow(broken_path);

    const after = export_command.currentPuzzleLine(&app.engine);
    try std.testing.expectEqualSlices(u8, &before, &after);
    try std.testing.expectEqualStrings(startup_policy.IDLE_STARTUP_STATUS, facade_impl.last_render_msg.?);
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
    try std.testing.expect(app.file_session.workingFile() == null);
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

test "autosave: first autosave with no working file writes the visible save folder and makes it the working file" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(tmp_rel);
    const tmp_abs_z = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp_rel, std.testing.allocator);
    defer std.testing.allocator.free(tmp_abs_z);
    const tmp_abs = tmp_abs_z[0 .. tmp_abs_z.len - 1];
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

    const bytes = app.transport.readAll(app.transport.context, expected) catch return error.TestFailed;
    defer app.transport.free(app.transport.context, bytes);
    try std.testing.expect(bytes.len > 0);

    const output = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, output, file_policy.REPLACE_CONFIRM_TITLE) == null);
}

test "autosave: persisted SUD0 restores exact board given_bits and history pointer" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path_rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path_rel);
    const data_path_abs_z = try std.Io.Dir.cwd().realPathFileAlloc(io, data_path_rel, std.testing.allocator);
    defer std.testing.allocator.free(data_path_abs_z);
    const data_path = data_path_abs_z[0 .. data_path_abs_z.len - 1];

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_save = true;
    const seed_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/autosave-roundtrip.sud", .{data_path});
    defer std.testing.allocator.free(seed_path);
    try settings_store.setCurrentFile(std.testing.allocator, io, data_path, seed_path);

    const responses = [_][]const u8{
        "fill A3 7",
        "fill A4 8",
        "undo",
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
    try std.testing.expect(current != null);

    const resolved_current = app.transport.resolve(app.transport.context, current.?) catch return error.TestFailed;
    defer app.transport.free(app.transport.context, resolved_current);

    const bytes = app.transport.readAll(app.transport.context, resolved_current) catch return error.TestFailed;
    defer app.transport.free(app.transport.context, bytes);

    var restored = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    defer restored.deinit();
    try restored.loadSaveFormat(bytes);

    try std.testing.expect(board.equal(app.engine.state.board, restored.state.board));
    try std.testing.expectEqual(app.engine.state.history.pointer, restored.state.history.pointer);
    try std.testing.expectEqual(app.engine.state.history.entries.items.len, restored.state.history.entries.items.len);
}

test "autosave: non-state settings command does not bootstrap current_file" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_save = true;

    const responses = [_][]const u8{ "menu\n", "14\n", "4\n", "2\n", "quit\n" };
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
    try std.testing.expect(std.mem.indexOf(u8, output, "System") != null);
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
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_command.DEFAULT_SAVE_FILE});
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
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_command.DEFAULT_SAVE_FILE});
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
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_command.DEFAULT_SAVE_FILE});
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
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_command.DEFAULT_SAVE_FILE});
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

test "new triggers replace confirm before autosave can overwrite restored file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const steps = [_]command.ParseCommandResult{
        .{ .valid = .{ .new = .{ .puzzle = null } } },
        .{ .valid = .{ .paste = .{ .line = puzzle_gen.PuzzleGen.easy() } } },
        .{ .valid = .{ .quit = {} } },
    };
    const replace_answers = [_]bool{false};
    var facade_impl = DeterministicFacade{ .steps = &steps, .replace_answers = &replace_answers };
    var transport_impl = MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    try transport_impl.put("/virtual/old.sud", "OLD");

    try settings_store.setCurrentFile(std.testing.allocator, io, data_path, "/virtual/old.sud");

    var cfg = config.Config.default();
    cfg.auto_save = true;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var app = try Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const old_bytes = transport_impl.files.get("/virtual/old.sud") orelse return error.TestFailed;
    try std.testing.expectEqualSlices(u8, "OLD", old_bytes);
    const default_virtual = try std.fmt.allocPrint(std.testing.allocator, "/virtual/{s}", .{save_command.DEFAULT_SAVE_FILE});
    defer std.testing.allocator.free(default_virtual);
    try std.testing.expect(!transport_impl.files.contains(default_virtual));
    try std.testing.expectEqual(@as(usize, 1), facade_impl.replace_prompts);
}
