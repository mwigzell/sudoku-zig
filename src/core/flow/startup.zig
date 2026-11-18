// StartupFlow: what the game shows when the app starts — restore the current
// file, start a new game, or wait for the player — decided once for every platform.
const std = @import("std");
const startup_policy = @import("../startup/policy.zig");
const game_engine = @import("../engine/game_engine.zig");
const puzzle_gen = @import("../puzzle_gen/mod.zig");
const config = @import("../config.zig");
const step_mod = @import("step.zig");
const file_session_mod = @import("file_session.zig");
const save_mod = @import("save.zig");
const forget_mod = @import("forget.zig");
const startup_config = @import("../startup/config.zig");
const logger = @import("../logger.zig");

const log = logger.Logger(.startup);

const Step = step_mod.Step;
const Input = step_mod.Input;
const FileSession = file_session_mod.FileSession;
const MAX_NAME_LEN = file_session_mod.MAX_NAME_LEN;

pub const UNEXPECTED_INPUT_MSG = "Startup could not finish because the app sent an unexpected answer.";
pub const RESTORE_FAILED_TITLE = "Restore failed";
pub const RESTORE_FAILED_FMT = "The file {s} could not be restored. Do you want to delete it?";
pub const RESTORE_FAILED_OK_LABEL = "Delete";
pub const RESTORE_FAILED_CANCEL_LABEL = "Keep";
/// Logged when the platform reports the restore read as cancelled; nobody picks the restored file.
const RESTORE_CANCELLED_REASON = "the restore read was cancelled";

/// The file startup may restore: where to read it, what to call it, and what the
/// FileSession should follow afterwards (a path natively, a host name on the web).
pub const CurrentFile = struct {
    path: []const u8,
    name: []const u8,
    current: []const u8,
};

/// Fixed-size copy of a string the flow hands out in later steps.
const Text = struct {
    buf: [MAX_NAME_LEN]u8 = undefined,
    len: usize = 0,

    fn set(self: *Text, value: []const u8) void {
        const n = @min(value.len, self.buf.len);
        std.mem.copyForwards(u8, self.buf[0..n], value[0..n]);
        self.len = n;
    }

    fn get(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const StartupFlow = struct {
    engine: *game_engine.GameEngine,
    session: *FileSession,
    /// The player's Config: Auto Restore, Auto New and the difficulty shape startup.
    cfg: *const config.Config,
    has_current: bool = false,
    path: Text = .{},
    name: Text = .{},
    current: Text = .{},
    /// Status of the game just shown, or the question / error text still to come.
    text: Text = .{},
    restored: bool = false,
    /// The new game's write once its board has been acknowledged, if Auto Save is on.
    write: save_mod.SaveFlow = undefined,
    phase: Phase = .start,

    const Phase = enum {
        start,
        reading,
        showing_restored,
        asking_solved,
        generating,
        showing_new,
        resolving_new,
        saving_new,
        showing_idle,
        showing_idle_then_ask_delete,
        asking_delete,
        forgetting,
        showing_idle_then_error,
        finished,
    };

    /// A flow for this launch; `current` is the file the platform remembers, if any.
    pub fn init(engine: *game_engine.GameEngine, session: *FileSession, cfg: *const config.Config, current: ?CurrentFile) StartupFlow {
        var flow = StartupFlow{ .engine = engine, .session = session, .cfg = cfg };
        if (current) |file| {
            flow.has_current = true;
            flow.path.set(file.path);
            flow.name.set(file.name);
            flow.current.set(file.current);
            // The remembered file is the lane autosave follows, even when Auto Restore skips the read.
            flow.session.setCurrentFile(file.current);
        }
        return flow;
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *StartupFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.fail(UNEXPECTED_INPUT_MSG);
                const decision = startup_policy.evaluate(.{
                    .auto_restore = self.cfg.auto_restore,
                    .auto_new = self.cfg.auto_new,
                    .has_current_file = self.has_current,
                });
                return switch (decision.action) {
                    .restore => blk: {
                        self.phase = .reading;
                        break :blk .{ .restore = self.path.get() };
                    },
                    .new => self.generate(),
                    .idle => self.showIdle(.showing_idle),
                };
            },
            .reading => {
                const read = switch (input) {
                    .read => |r| r,
                    else => return self.fail(UNEXPECTED_INPUT_MSG),
                };
                const bytes = switch (read) {
                    .file => |f| f.bytes,
                    .cancelled => return self.restoreFailed(RESTORE_CANCELLED_REASON),
                    .failed => |msg| return self.restoreFailed(msg),
                };
                return switch (self.engine.restoreFromSave(bytes)) {
                    .error_msg => |msg| self.restoreFailed(msg),
                    .ok => |ok| blk: {
                        self.restored = true;
                        self.session.setCurrentFile(self.current.get());
                        self.session.apply(.startup_restore);
                        break :blk self.showGame(.showing_restored, ok.msg);
                    },
                };
            },
            .showing_restored => {
                if (input != .ack) return self.fail(UNEXPECTED_INPUT_MSG);
                if (!self.engine.state.board.isSolved()) return self.finish(.done);
                self.phase = .asking_solved;
                return step_mod.makeQuestion(
                    .information,
                    startup_policy.RESTORE_SOLVED_TITLE,
                    startup_policy.RESTORE_SOLVED_PROMPT,
                    startup_policy.RESTORE_SOLVED_OK_LABEL,
                    startup_policy.RESTORE_SOLVED_CANCEL_LABEL,
                );
            },
            .asking_solved => {
                const yes = switch (input) {
                    .pressed => |i| i == step_mod.QUESTION_OK,
                    else => return self.fail(UNEXPECTED_INPUT_MSG),
                };
                return if (yes) self.generate() else self.finish(.done);
            },
            .generating => {
                const generated = switch (input) {
                    .generated => |g| g,
                    else => return self.fail(UNEXPECTED_INPUT_MSG),
                };
                const line = switch (generated) {
                    .line => |l| l,
                    .cancelled => return if (self.restored) self.finish(.done) else self.showIdle(.showing_idle),
                    .failed => |msg| return self.generateFailed(msg),
                };
                return switch (self.engine.newFromOneLinePuzzle(line)) {
                    .error_msg => |msg| self.generateFailed(msg),
                    .ok => |ok| self.showGame(.showing_new, ok.msg),
                };
            },
            .showing_new, .showing_idle => {
                if (input != .ack) return self.fail(UNEXPECTED_INPUT_MSG);
                if (self.phase != .showing_new) return self.finish(.done);
                // A generated game is written when it exists, not when the player first moves.
                // With Auto Save off the app writes nothing and the load stays detached.
                if (!self.cfg.auto_save) {
                    self.session.apply(.startup_new);
                    return self.finish(.done);
                }
                self.phase = .resolving_new;
                return self.startNewGameWrite();
            },
            .resolving_new => {
                const name = switch (input) {
                    .default_target => |n| n,
                    else => return self.fail(UNEXPECTED_INPUT_MSG),
                };
                return self.beginNewGameWrite(name);
            },
            .saving_new => {
                const step = self.write.next(input);
                return if (step_mod.isTerminal(step)) self.finish(step) else step;
            },
            .showing_idle_then_ask_delete => {
                if (input != .ack) return self.fail(UNEXPECTED_INPUT_MSG);
                self.phase = .asking_delete;
                return step_mod.makeQuestion(.@"error", RESTORE_FAILED_TITLE, self.text.get(), RESTORE_FAILED_OK_LABEL, RESTORE_FAILED_CANCEL_LABEL);
            },
            .asking_delete => {
                const yes = switch (input) {
                    .pressed => |i| i == step_mod.QUESTION_OK,
                    else => return self.fail(UNEXPECTED_INPUT_MSG),
                };
                self.phase = .forgetting;
                return .{ .forget_current_file = .{ .path = self.path.get(), .delete = yes } };
            },
            .forgetting => return switch (input) {
                .forgot => |forgot| switch (forgot) {
                    .forgotten => self.finish(.done),
                    // A refused clear touched nothing; the player repairs or deletes the settings file
                    // and relaunches, so the flow ends on core's sentence instead of carrying on.
                    .refused => |reason| self.finish(.{ .show_status = reason.sentence() }),
                    .failed => |reason| blk: {
                        // The one log site for a forget that failed: every cause arrives here, a core
                        // store error and an adapter-reported one alike.
                        log.err("forget of {s} failed: {s}", .{ self.path.get(), reason });
                        break :blk self.finish(.{ .show_status = forget_mod.FAILED_MSG });
                    },
                },
                else => return self.fail(UNEXPECTED_INPUT_MSG),
            },
            .showing_idle_then_error => {
                if (input != .ack) return self.fail(UNEXPECTED_INPUT_MSG);
                return self.finish(step_mod.promptError(self.text.get()));
            },
            .finished => return .done,
        }
    }

    fn generate(self: *StartupFlow) Step {
        self.phase = .generating;
        return .{ .generate_game = self.cfg.difficulty };
    }

    /// The new game's first write: its current file, else the platform's default target.
    fn startNewGameWrite(self: *StartupFlow) Step {
        if (self.session.currentFile()) |current| return self.beginNewGameWrite(current);
        return .resolve_default_target;
    }

    fn beginNewGameWrite(self: *StartupFlow, name: []const u8) Step {
        self.write = save_mod.SaveFlow.newGame(self.session, name);
        self.phase = .saving_new;
        const step = self.write.next(.start);
        return if (step_mod.isTerminal(step)) self.finish(step) else step;
    }

    fn showGame(self: *StartupFlow, phase: Phase, status: ?[]const u8) Step {
        self.phase = phase;
        const shown: ?[]const u8 = if (status) |s| blk: {
            self.text.set(s);
            break :blk self.text.get();
        } else null;
        return step_mod.showGame(self.engine, self.cfg.*, shown, if (self.restored) self.name.get() else null);
    }

    /// Idle board with the welcome line; `phase` says what follows once it is drawn.
    fn showIdle(self: *StartupFlow, phase: Phase) Step {
        self.session.setCurrentFile(null);
        self.session.apply(.startup_idle);
        self.phase = phase;
        return step_mod.showGame(self.engine, self.cfg.*, startup_policy.IDLE_STARTUP_STATUS, null);
    }

    fn restoreFailed(self: *StartupFlow, reason: []const u8) Step {
        log.err("restore of {s} failed: {s}", .{ self.name.get(), reason });
        const text = std.fmt.bufPrint(&self.text.buf, RESTORE_FAILED_FMT, .{self.name.get()}) catch RESTORE_FAILED_TITLE;
        if (text.ptr == &self.text.buf) self.text.len = text.len else self.text.set(text);
        return self.showIdle(.showing_idle_then_ask_delete);
    }

    fn generateFailed(self: *StartupFlow, reason: []const u8) Step {
        log.err("generate failed: {s}", .{reason});
        if (self.restored) return self.finish(step_mod.promptError(step_mod.GENERATE_FAILED_MSG));
        self.text.set(step_mod.GENERATE_FAILED_MSG);
        return self.showIdle(.showing_idle_then_error);
    }

    fn fail(self: *StartupFlow, msg: []const u8) Step {
        return self.finish(step_mod.promptError(msg));
    }

    fn finish(self: *StartupFlow, terminal: Step) Step {
        self.phase = .finished;
        return terminal;
    }
};

// --- tests ---

const solved_line = "534678912672195348198342567859761423426853791713924856961537284287419635345286179";
const open_line = "530070000600195000098000060800060003400803001700020006060000280000419005000080079";

/// The Config fields startup reads, set per test.
const Options = struct {
    auto_restore: bool,
    auto_new: bool,
    auto_save: bool = true,
    difficulty: puzzle_gen.Difficulty,
};

const Harness = struct {
    engine: game_engine.GameEngine,
    session: FileSession = .{},
    cfg: config.Config = config.Config.default(),

    fn init() !Harness {
        return .{ .engine = try game_engine.GameEngine.init(open_line, config.Config.default()) };
    }

    fn deinit(self: *Harness) void {
        self.engine.deinit();
    }

    fn flow(self: *Harness, options: Options, current: ?CurrentFile) StartupFlow {
        self.cfg.auto_restore = options.auto_restore;
        self.cfg.auto_new = options.auto_new;
        self.cfg.auto_save = options.auto_save;
        self.cfg.difficulty = options.difficulty;
        return StartupFlow.init(&self.engine, &self.session, &self.cfg, current);
    }

    fn saveBytes(line: []const u8) ![]u8 {
        var source = try game_engine.GameEngine.init(line, config.Config.default());
        defer source.deinit();
        return source.toSaveFormat(std.testing.allocator);
    }
};

const restore_opts = Options{ .auto_restore = true, .auto_new = false, .difficulty = .easy };
const test_file = CurrentFile{ .path = "/data/game.sud", .name = "game.sud", .current = "/data/game.sud" };

test "startup with nothing to restore and no auto new shows the idle board" {
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(.{ .auto_restore = true, .auto_new = false, .difficulty = .easy }, null);
    const shown = f.next(.start);
    try std.testing.expectEqualStrings(startup_policy.IDLE_STARTUP_STATUS, shown.show_game.frame.status.?);
    try std.testing.expect(shown.show_game.file == null);
    try std.testing.expectEqual(Step.done, f.next(.ack));
}

test "startup restore reads the file, shows the game and continues it" {
    var h = try Harness.init();
    defer h.deinit();
    const bytes = try Harness.saveBytes(open_line);
    defer std.testing.allocator.free(bytes);
    var f = h.flow(restore_opts, test_file);
    try std.testing.expectEqualStrings("/data/game.sud", f.next(.start).restore);
    const shown = f.next(.{ .read = .{ .file = .{ .bytes = bytes } } });
    try std.testing.expectEqualStrings("game.sud", shown.show_game.file.?);
    try std.testing.expectEqual(Step.done, f.next(.ack));
    try std.testing.expectEqualStrings("/data/game.sud", h.session.currentFile().?);
    try std.testing.expectEqual(@import("../file_policy.zig").WriteContext.continuation, h.session.write_context);
}

test "startup restore keeps the bookmark, so Rewind is offered again" {
    var h = try Harness.init();
    defer h.deinit();

    // A game the player bookmarked and then moved past, saved as the file startup reads.
    var source = try game_engine.GameEngine.init(open_line, config.Config.default());
    defer source.deinit();
    _ = source.exec(.{ .fill = .{ .row = 0, .col = 2, .digit = .four } });
    _ = source.exec(.{ .bookmark = {} });
    _ = source.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .eight } });
    const bytes = try source.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var f = h.flow(restore_opts, test_file);
    _ = f.next(.start);
    const shown = f.next(.{ .read = .{ .file = .{ .bytes = bytes } } }).show_game;
    try std.testing.expectEqual(@as(?u16, 1), h.engine.state.bookmark);
    try std.testing.expect(shown.legend.rewind);
    try std.testing.expectEqual(Step.done, f.next(.ack));

    // The restored bookmark is usable, not just present: Rewind returns the bookmarked board.
    const rewound = h.engine.exec(.{ .rewind = {} });
    const cell = @import("../board/cell.zig");
    try std.testing.expectEqual(cell.CellValue.four, rewound.ok.board_view.get(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, rewound.ok.board_view.get(0, 3));
}

test "startup restore of a solved game asks, and New game writes the new game" {
    const policy = @import("../file_policy.zig");
    var h = try Harness.init();
    defer h.deinit();
    const bytes = try Harness.saveBytes(solved_line);
    defer std.testing.allocator.free(bytes);
    var f = h.flow(restore_opts, test_file);
    _ = f.next(.start);
    _ = f.next(.{ .read = .{ .file = .{ .bytes = bytes } } });
    const asked = f.next(.ack);
    try std.testing.expectEqualStrings(startup_policy.RESTORE_SOLVED_TITLE, asked.prompt_message.title);
    try std.testing.expectEqual(puzzle_gen.Difficulty.easy, f.next(.{ .pressed = step_mod.QUESTION_OK }).generate_game);
    const shown = f.next(.{ .generated = .{ .line = open_line } });
    try std.testing.expect(shown.show_game.frame.status != null);
    // The generated game is written when its board is acknowledged, before any move.
    const first = f.next(.ack).autosave;
    try std.testing.expectEqualStrings("/data/game.sud", first.name);
    try std.testing.expect(!first.replace);
    const replace = f.next(.{ .wrote = .exists }).autosave;
    try std.testing.expect(replace.replace);
    const wrote = f.next(.{ .wrote = .{ .ok = "/data/game.sud" } });
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(policy.SAVED_TO_FMT, .{"/data/game.sud"}), wrote.show_status);
    try std.testing.expect(!h.engine.state.board.isSolved());
    try std.testing.expectEqual(policy.WriteContext.continuation, h.session.write_context);
}

test "startup new with auto save off writes nothing and leaves the load detached" {
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(.{ .auto_restore = false, .auto_new = true, .auto_save = false, .difficulty = .easy }, test_file);
    _ = f.next(.start);
    _ = f.next(.{ .generated = .{ .line = open_line } });
    try std.testing.expectEqual(Step.done, f.next(.ack));
    try std.testing.expectEqualStrings("/data/game.sud", h.session.currentFile().?);
    try std.testing.expectEqual(@import("../file_policy.zig").WriteContext.detached, h.session.write_context);
}

test "startup restore of a solved game with auto save off writes nothing" {
    const policy = @import("../file_policy.zig");
    var h = try Harness.init();
    defer h.deinit();
    const bytes = try Harness.saveBytes(solved_line);
    defer std.testing.allocator.free(bytes);
    var f = h.flow(.{ .auto_restore = true, .auto_new = true, .auto_save = false, .difficulty = .easy }, test_file);
    _ = f.next(.start);
    _ = f.next(.{ .read = .{ .file = .{ .bytes = bytes } } });
    _ = f.next(.ack);
    _ = f.next(.{ .pressed = step_mod.QUESTION_OK });
    _ = f.next(.{ .generated = .{ .line = open_line } });
    // Auto Save off: startup ends on the generated board with no write and a detached load, so
    // the solved file on disk still asks on the next launch.
    try std.testing.expectEqual(Step.done, f.next(.ack));
    try std.testing.expectEqual(policy.WriteContext.detached, h.session.write_context);
}

test "a generated game onto a remembered file asks before replacing, and Keep stops following it" {
    const policy = @import("../file_policy.zig");
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(.{ .auto_restore = false, .auto_new = true, .difficulty = .easy }, test_file);
    _ = f.next(.start);
    _ = f.next(.{ .generated = .{ .line = open_line } });
    const write = f.next(.ack).autosave;
    try std.testing.expectEqualStrings("/data/game.sud", write.name);
    try std.testing.expect(!write.replace);
    try std.testing.expect(f.next(.{ .wrote = .exists }) == .prompt_message);
    const ended = f.next(.{ .pressed = step_mod.QUESTION_CANCEL });
    try std.testing.expectEqualStrings(policy.WRITE_CANCELLED_MSG, ended.show_status);
    try std.testing.expectEqualStrings("/data/game.sud", h.session.currentFile().?);
    try std.testing.expectEqual(policy.WriteContext.detached, h.session.write_context);
}

test "startup restore of a solved game keeps it when the player says Keep" {
    var h = try Harness.init();
    defer h.deinit();
    const bytes = try Harness.saveBytes(solved_line);
    defer std.testing.allocator.free(bytes);
    var f = h.flow(restore_opts, test_file);
    _ = f.next(.start);
    _ = f.next(.{ .read = .{ .file = .{ .bytes = bytes } } });
    _ = f.next(.ack);
    try std.testing.expectEqual(Step.done, f.next(.{ .pressed = step_mod.QUESTION_CANCEL }));
    try std.testing.expect(h.engine.state.board.isSolved());
}

test "startup restore failure shows idle, asks to delete, then forgets the file" {
    inline for (.{ true, false }) |delete| {
        var h = try Harness.init();
        defer h.deinit();
        var f = h.flow(restore_opts, test_file);
        _ = f.next(.start);
        const shown = f.next(.{ .read = .{ .failed = "readAll: FileNotFound" } });
        try std.testing.expectEqualStrings(startup_policy.IDLE_STARTUP_STATUS, shown.show_game.frame.status.?);
        const asked = f.next(.ack);
        try std.testing.expectEqualStrings(RESTORE_FAILED_TITLE, asked.prompt_message.title);
        try std.testing.expectEqualStrings(std.fmt.comptimePrint(RESTORE_FAILED_FMT, .{"game.sud"}), asked.prompt_message.text);
        const forget = f.next(.{ .pressed = if (delete) step_mod.QUESTION_OK else step_mod.QUESTION_CANCEL });
        try std.testing.expectEqualStrings("/data/game.sud", forget.forget_current_file.path);
        try std.testing.expectEqual(delete, forget.forget_current_file.delete);
        try std.testing.expectEqual(Step.done, f.next(.{ .forgot = .forgotten }));
        try std.testing.expect(h.session.currentFile() == null);
    }
}

test "a refused forget ends startup on core's sentence for that refusal" {
    inline for (.{
        .{ forget_mod.Refusal.settings_unreadable, startup_config.SETTINGS_REFUSED_MSG },
        .{ forget_mod.Refusal.settings_unwritable, startup_config.SETTINGS_WRITE_FAILED_MSG },
    }) |case| {
        var h = try Harness.init();
        defer h.deinit();
        var f = h.flow(restore_opts, test_file);
        _ = f.next(.start);
        _ = f.next(.{ .read = .{ .failed = "readAll: FileNotFound" } });
        _ = f.next(.ack);
        const forget = f.next(.{ .pressed = step_mod.QUESTION_OK });
        try std.testing.expect(forget == .forget_current_file);
        const ended = f.next(.{ .forgot = .{ .refused = case[0] } });
        try std.testing.expectEqualStrings(case[1], ended.show_status);
        try std.testing.expect(step_mod.isTerminal(ended));
    }
}

test "a forget that failed for another reason shows core's generic failure, with one log line" {
    // A core-mapped store error and an adapter-reported one arrive the same way; neither is a
    // settings refusal, so the player gets the generic sentence and the log carries the reason.
    inline for (.{ "OutOfMemory", "current-file forget failed: 500 (OutOfMemory)" }) |reason| {
        var h = try Harness.init();
        defer h.deinit();

        var logged: [256]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&logged);
        logger.test_sink = &sink;
        defer logger.test_sink = null;
        logger.min_level = .err;
        defer logger.min_level = .info;

        var f = h.flow(restore_opts, test_file);
        _ = f.next(.start);
        _ = f.next(.{ .read = .{ .failed = "readAll: FileNotFound" } });
        _ = f.next(.ack);
        _ = f.next(.{ .pressed = step_mod.QUESTION_OK });
        const ended = f.next(.{ .forgot = .{ .failed = reason } });

        try std.testing.expectEqualStrings(forget_mod.FAILED_MSG, ended.show_status);
        try std.testing.expect(step_mod.isTerminal(ended));
        const said = sink.buffered();
        // One line for the forget itself; the restore failure above has its own.
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, said, "forget of "));
        try std.testing.expect(std.mem.indexOf(u8, said, "/data/game.sud") != null);
        try std.testing.expect(std.mem.indexOf(u8, said, reason) != null);
    }
}

test "startup restore of unreadable bytes is a restore failure" {
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(restore_opts, test_file);
    _ = f.next(.start);
    _ = f.next(.{ .read = .{ .file = .{ .bytes = "not a save" } } });
    try std.testing.expectEqualStrings(RESTORE_FAILED_TITLE, f.next(.ack).prompt_message.title);
}

test "startup new generates at the saved difficulty, shows the game and writes it" {
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(.{ .auto_restore = false, .auto_new = true, .difficulty = .hard }, null);
    try std.testing.expectEqual(puzzle_gen.Difficulty.hard, f.next(.start).generate_game);
    const shown = f.next(.{ .generated = .{ .line = open_line } });
    try std.testing.expect(shown.show_game.file == null);
    try std.testing.expect(f.next(.ack) == .resolve_default_target);
    const write = f.next(.{ .default_target = "sudoku.sud" }).autosave;
    try std.testing.expectEqualStrings("sudoku.sud", write.name);
    try std.testing.expect(!write.replace);
    const wrote = f.next(.{ .wrote = .{ .ok = "sudoku.sud" } });
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(@import("../file_policy.zig").SAVED_TO_FMT, .{"sudoku.sud"}), wrote.show_status);
}

test "startup new cancelled shows the idle board" {
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(.{ .auto_restore = false, .auto_new = true, .difficulty = .easy }, null);
    _ = f.next(.start);
    const shown = f.next(.{ .generated = .cancelled });
    try std.testing.expectEqualStrings(startup_policy.IDLE_STARTUP_STATUS, shown.show_game.frame.status.?);
    try std.testing.expectEqual(Step.done, f.next(.ack));
}

test "startup new failure shows the idle board, then the error" {
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(.{ .auto_restore = false, .auto_new = true, .difficulty = .easy }, null);
    _ = f.next(.start);
    _ = f.next(.{ .generated = .{ .failed = "worker crashed" } });
    try std.testing.expectEqualStrings(step_mod.GENERATE_FAILED_MSG, f.next(.ack).prompt_message.text);
}

test "startup new with an invalid generated line is a generation failure" {
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(.{ .auto_restore = false, .auto_new = true, .difficulty = .easy }, null);
    _ = f.next(.start);
    _ = f.next(.{ .generated = .{ .line = "123" } });
    try std.testing.expect(f.next(.ack) == .prompt_message);
}

test "startup ends with an error on an unexpected answer" {
    var h = try Harness.init();
    defer h.deinit();
    var f = h.flow(restore_opts, test_file);
    _ = f.next(.start);
    try std.testing.expectEqualStrings(UNEXPECTED_INPUT_MSG, f.next(.ack).prompt_message.text);
}

test "startup prompts read as sentences that start with words, not the file name" {
    const sentence = @import("../../test/sentence.zig");
    var buf: [256]u8 = undefined;
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, RESTORE_FAILED_FMT, .{"game.sud"}));
    try sentence.expectSentence(UNEXPECTED_INPUT_MSG);
}
