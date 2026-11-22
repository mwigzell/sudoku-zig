// CommandFlow: one player command end to end — gather what a load needs or change the Config, apply it, show
// the result, then persist settings and autosave as the command needs, in that order on every platform.
// Save, Save As, Export and Copy run their write flow instead.
const std = @import("std");
const command = @import("../command.zig");
const config = @import("../config.zig");
const config_table = @import("../config_table.zig");
const game_engine = @import("../engine/game_engine.zig");
const hint_command = @import("../engine/hint.zig");
const board = @import("../board/board.zig");
const step_mod = @import("step.zig");
const file_session_mod = @import("file_session.zig");
const config_flow = @import("config.zig");
const autosave_mod = @import("autosave.zig");
const save_mod = @import("save.zig");
const export_mod = @import("export.zig");
const forget_mod = @import("forget.zig");
const startup_config = @import("../startup/config.zig");
const logger = @import("../logger.zig");

const log = logger.Logger(.flow);

const Step = step_mod.Step;
const Input = step_mod.Input;
const FileSession = file_session_mod.FileSession;
const ConfigFlow = config_flow.ConfigFlow;
const AutosaveFlow = autosave_mod.AutosaveFlow;
const SaveFlow = save_mod.SaveFlow;
const ExportFlow = export_mod.ExportFlow;

/// Shown when the platform could not read the chosen game; its reason goes to the log.
pub const OPEN_FAILED_MSG = "The game could not be opened.";
/// Shown when the platform could not read the chosen puzzle file; its reason goes to the log.
pub const IMPORT_FAILED_MSG = "The puzzle could not be imported.";
/// Shown when the platform could not read a puzzle from the clipboard; its reason goes to the log.
pub const PASTE_FAILED_MSG = "There is no puzzle on the clipboard to paste.";
/// Status a load that shows no game ends with: the last status no longer describes the board.
pub const LOAD_ENDED_STATUS = "";

/// The lead-in of a load whose pointer write the settings store refused: the game is on screen,
/// so what the player learns first is that the next launch will not reopen it.
const LOADED_NOT_REMEMBERED_LEAD = "The game was loaded, but the next launch will not reopen it. ";

/// Core's sentence for a load the settings read refused to remember: the game is loaded, and the
/// repair is the one an unreadable settings file needs.
pub const LOADED_SETTINGS_REFUSED_MSG = LOADED_NOT_REMEMBERED_LEAD ++ startup_config.SETTINGS_REFUSED_MSG;

/// Core's sentence for a load the store could not write the pointer for: the game is loaded, and
/// the repair is the space or the permission its settings write needs.
pub const LOADED_SETTINGS_WRITE_FAILED_MSG = LOADED_NOT_REMEMBERED_LEAD ++ startup_config.SETTINGS_WRITE_FAILED_MSG;

/// Core's sentence for a loaded game the settings store would not record as the current file, one
/// per cause so the repair the player reads is the one that applies.
pub fn loadedNotRememberedMsg(reason: forget_mod.Refusal) []const u8 {
    return switch (reason) {
        .settings_unreadable => LOADED_SETTINGS_REFUSED_MSG,
        .settings_unwritable => LOADED_SETTINGS_WRITE_FAILED_MSG,
    };
}

pub const CommandFlow = struct {
    engine: *game_engine.GameEngine,
    session: *FileSession,
    /// The player's Config, held beside the engine; `set_config` changes it here.
    cfg: *config.Config,
    cmd: command.Command,
    phase: Phase = .start,
    persist: ConfigFlow = undefined,
    autosave: AutosaveFlow = undefined,
    write: Write = undefined,

    const Phase = enum { start, gathering, writing, showing, persisting, autosaving, clearing, finished };
    const Write = union(enum) { save: SaveFlow, @"export": ExportFlow };

    /// Run `cmd` on `engine` under `cfg`; `session` is the file the follow-up autosave writes.
    pub fn init(engine: *game_engine.GameEngine, session: *FileSession, cfg: *config.Config, cmd: command.Command) CommandFlow {
        return .{ .engine = engine, .session = session, .cfg = cfg, .cmd = cmd };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *CommandFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.finish(step_mod.promptError(step_mod.UNEXPECTED_INPUT_MSG));
                return self.gather();
            },
            .gathering => return self.gathered(input),
            .writing => return self.continueWrite(input),
            .showing => {
                if (input != .ack) return self.finish(step_mod.promptError(step_mod.UNEXPECTED_INPUT_MSG));
                self.persist = ConfigFlow.afterCommand(self.cfg.*, self.cmd);
                self.phase = .persisting;
                return self.continuePersist(.start);
            },
            .persisting => return self.continuePersist(input),
            .autosaving => return self.continueAutosave(input),
            .clearing => return self.finish(.{ .show_status = LOAD_ENDED_STATUS }),
            .finished => return .done,
        }
    }

    /// Ask the platform for what a load needs, unless the command already carries it.
    fn gather(self: *CommandFlow) Step {
        const step: Step = switch (self.cmd) {
            .new => |data| if (data.puzzle) |line|
                return self.load(.new_game, line)
            else
                .{ .generate_game = data.difficulty orelse self.cfg.difficulty },
            .open => |data| .{ .open = data.path },
            .import => |data| .{ .import_puzzle = data.path },
            .paste => |data| if (data.line) |line| return self.load(.paste, line) else .paste_puzzle,
            .save => |data| return self.startWrite(.{ .save = SaveFlow.forCommand(self.session, .save, data.path, self.cfg.auto_save) }),
            .save_as => |data| return self.startWrite(.{ .save = SaveFlow.forCommand(self.session, .save_as, data.path, self.cfg.auto_save) }),
            .@"export" => |data| return self.startWrite(.{ .@"export" = ExportFlow.toFile(data.path) }),
            .copy => return self.startWrite(.{ .@"export" = ExportFlow.toClipboard() }),
            .set_config => |change| return self.setConfig(change),
            else => return self.show(self.engine.exec(self.cmd)),
        };
        self.phase = .gathering;
        return step;
    }

    /// Load what the platform gathered; backing out ends the command quietly.
    fn gathered(self: *CommandFlow, input: Input) Step {
        const unexpected: Step = step_mod.promptError(step_mod.UNEXPECTED_INPUT_MSG);
        switch (self.cmd) {
            .new => {
                if (input != .generated) return self.finish(unexpected);
                return switch (input.generated) {
                    .line => |line| self.load(.new_game, line),
                    .cancelled => self.finish(.{ .show_status = LOAD_ENDED_STATUS }),
                    .failed => |reason| self.failed(step_mod.GENERATE_FAILED_MSG, reason),
                };
            },
            .open, .import, .paste => {
                if (input != .read) return self.finish(unexpected);
                return switch (input.read) {
                    .file => |file| switch (self.cmd) {
                        .open => self.load(.{ .open = file.name }, file.bytes),
                        .import => self.load(.import, file.bytes),
                        else => self.load(.paste, file.bytes),
                    },
                    .cancelled => self.finish(.{ .show_status = LOAD_ENDED_STATUS }),
                    .failed => |reason| self.failed(switch (self.cmd) {
                        .open => OPEN_FAILED_MSG,
                        .import => IMPORT_FAILED_MSG,
                        else => PASTE_FAILED_MSG,
                    }, reason),
                };
            },
            else => return self.finish(unexpected),
        }
    }

    /// Change one Config field and hand the engine its fields again; a refused change shows core's sentence.
    fn setConfig(self: *CommandFlow, change: config_table.Change) Step {
        config_table.apply(self.cfg, change) catch |err| {
            log.warn("set_config {s} refused: {s}", .{ change.field, @errorName(err) });
            return self.finish(step_mod.promptError(switch (err) {
                error.UnknownField => config_table.UNKNOWN_FIELD_MSG,
                error.BadValue => config_table.BAD_VALUE_MSG,
            }));
        };
        logger.min_level = self.cfg.log_level;
        self.engine.useConfig(self.cfg.*);
        if (change.field.len == "warn_solvability".len and std.mem.eql(u8, change.field, "warn_solvability") and change.value.on) {
            return self.show(self.engine.solvabilityWarningOn());
        }
        return self.show(self.engine.unchanged());
    }

    /// Replace the game from `data` and record the load, so later writes know whose file this is.
    fn load(self: *CommandFlow, loaded: file_session_mod.Load, data: []const u8) Step {
        const ev = switch (loaded) {
            .new_game => self.engine.newFromOneLinePuzzle(data),
            .open => |name| self.engine.openFromSave(data, name),
            .import => self.engine.fromPuzzle(data),
            .paste => self.engine.pasteFromLine(data),
        };
        if (ev == .error_msg) {
            self.phase = .clearing;
            return step_mod.promptError(ev.error_msg);
        }
        if (ev == .ok) {
            self.session.noteLoad(loaded);
            if (self.cmd == .new) {
                if (self.cmd.new.difficulty) |d| self.cfg.difficulty = d;
            }
        }
        var step = self.show(ev);
        if (step == .show_game) step.show_game.loaded = true;
        return step;
    }

    fn show(self: *CommandFlow, ev: game_engine.Event) Step {
        switch (ev) {
            .error_msg => |msg| return self.finish(step_mod.promptError(msg)),
            .ok => |ok| {
                self.phase = .showing;
                return step_mod.showGame(self.engine, self.cfg.*, ok.msg, self.session.currentFile());
            },
        }
    }

    fn startWrite(self: *CommandFlow, write: Write) Step {
        self.write = write;
        self.phase = .writing;
        return self.continueWrite(.start);
    }

    fn continueWrite(self: *CommandFlow, input: Input) Step {
        const step = switch (self.write) {
            .save => |*f| f.next(input),
            .@"export" => |*f| f.next(input),
        };
        return if (step_mod.isTerminal(step)) self.finish(step) else step;
    }

    fn continuePersist(self: *CommandFlow, input: Input) Step {
        const step = self.persist.next(input);
        switch (step) {
            .done => {},
            .show_status, .prompt_message => return self.finish(step),
            else => return step,
        }
        self.autosave = AutosaveFlow.afterCommand(self.session, self.cfg.auto_save, self.cmd, self.engine.lastExecChanged());
        self.phase = .autosaving;
        return self.continueAutosave(.start);
    }

    fn continueAutosave(self: *CommandFlow, input: Input) Step {
        const step = self.autosave.next(input);
        return if (step_mod.isTerminal(step)) self.finish(step) else step;
    }

    /// A load the platform could not gather: show the error, then clear the status once it is answered.
    fn failed(self: *CommandFlow, msg: []const u8, reason: []const u8) Step {
        log.err("{s} failed: {s}", .{ @tagName(self.cmd), reason });
        self.phase = .clearing;
        return step_mod.promptError(msg);
    }

    fn finish(self: *CommandFlow, terminal: Step) Step {
        self.phase = .finished;
        return terminal;
    }
};

const testing = std.testing;
const puzzle_gen = @import("../puzzle_gen/mod.zig");

fn testEngine(cfg: config.Config) !game_engine.GameEngine {
    return game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), cfg);
}

test "a config change shows the new setting, then persists it, and does not autosave" {
    var cfg = config.Config.default();
    cfg.auto_save = false;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .set_config = .{ .field = "auto_save", .value = .{ .on = true } } });

    const shown = flow.next(.start).show_game;
    try testing.expect(shown.config.auto_save);
    try testing.expect(flow.next(.ack).persist_config.auto_save);
    try testing.expect(flow.next(.{ .persisted = .ok }) == .done);
}

test "a move shows the board and the edited cell, then autosaves to the default target" {
    var cfg = config.Config.default();
    cfg.auto_save = true;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .fill = .{ .row = 0, .col = 0, .digit = .four } });

    const shown = flow.next(.start).show_game;
    try testing.expectEqual(@as(u4, 0), shown.frame.selected.?.row);
    try testing.expect(shown.legend.undo);
    try testing.expect(flow.next(.ack) == .resolve_default_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .default_target = "sudoku.sud" }).autosave.name);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "sudoku.sud" } }) == .done);
}

test "a rewind that cannot act changes nothing and does not autosave" {
    var cfg = config.Config.default();
    cfg.auto_save = true;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .rewind = {} });

    const shown = flow.next(.start).show_game;
    try testing.expect(!shown.legend.rewind);
    // No bookmark, so Rewind cannot act: no write, no default target, no binding.
    try testing.expect(flow.next(.ack) == .done);
}

test "a no-op rewind writes nothing even when a file is already bound" {
    var cfg = config.Config.default();
    cfg.auto_save = true;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    session.setCurrentFile("game.sud");
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .rewind = {} });

    _ = flow.next(.start).show_game;
    // Bound file or not, a rewind that cannot act must not write it.
    try testing.expect(flow.next(.ack) == .done);
}

test "a rewind that acts autosaves the rewound game" {
    var cfg = config.Config.default();
    cfg.auto_save = true;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = engine.exec(.{ .bookmark = {} });
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .rewind = {} });

    _ = flow.next(.start).show_game;
    try testing.expect(flow.next(.ack) == .resolve_default_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .default_target = "sudoku.sud" }).autosave.name);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "sudoku.sud" } }) == .done);
}

test "a rejected command shows the engine's error and nothing else" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .fill = .{ .row = 0, .col = 2, .digit = .four } });
    try testing.expect(flow.next(.start) == .prompt_message);
    try testing.expect(flow.next(.ack) == .done);
}

test "a failed config write ends the command with the error" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .set_config = .{ .field = "theme", .value = .{ .choice = "light" } } });
    _ = flow.next(.start);
    _ = flow.next(.ack);
    try testing.expectEqualStrings(config_flow.PERSIST_FAILED_MSG, flow.next(.{ .persisted = .{ .failed = "disk full" } }).prompt_message.text);
}

test "set_config changes the Config held beside the engine, and the engine takes its fields" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    const before_level = logger.min_level;
    defer logger.min_level = before_level;
    for ([_]config_table.Change{
        .{ .field = "warn_solvability", .value = .{ .on = true } },
        .{ .field = "show_marks", .value = .{ .on = false } },
        .{ .field = "log_level", .value = .{ .choice = "debug" } },
    }) |change| {
        var flow = CommandFlow.init(&engine, &session, &cfg, .{ .set_config = change });
        const shown = flow.next(.start).show_game.config;
        try testing.expectEqual(cfg, shown);
    }
    try testing.expectEqual(logger.Severity.debug, logger.min_level);
    try testing.expect(engine.warn_dead_moves and engine.warn_unsolvable_load);
    try testing.expect(!engine.show_marks);
}

test "toggling warn_solvability on over a dead board appends the no-solution sentence" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    // A dead board: a cell whose row, column and box together already hold all nine digits.
    const flat: [81]u8 = .{
        0, 0, 3, 4, 2, 1, 6, 0, 0, 9, 0, 0, 3, 7, 5, 0, 0, 1, 0, 0, 1, 8, 9, 6, 4, 0, 0,
        0, 0, 8, 1, 0, 2, 9, 0, 0, 7, 0, 0, 5, 0, 4, 1, 0, 8, 0, 0, 6, 7, 0, 8, 2, 0, 0,
        0, 0, 2, 6, 0, 9, 5, 0, 0, 8, 0, 0, 2, 0, 3, 0, 0, 9, 0, 0, 5, 0, 1, 7, 3, 0, 0,
    };
    const given_bits: board.CellMask = 0x54949b0d901361b25254;
    engine.state.board = try board.fromFlat(flat, .{ .given_bits = given_bits });
    engine.state.board.validate();
    // The prior command left its message in the scratch buffer; the toggle appends to it.
    engine.appendEventMsg("existing message");

    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .set_config = .{ .field = "warn_solvability", .value = .{ .on = true } } });
    const shown = flow.next(.start).show_game;
    try testing.expectEqualStrings("existing message " ++ hint_command.no_solution_msg, shown.frame.status.?);
}

test "toggling warn_solvability on again appends nothing when the sentence is already showing" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    const flat: [81]u8 = .{
        0, 0, 3, 4, 2, 1, 6, 0, 0, 9, 0, 0, 3, 7, 5, 0, 0, 1, 0, 0, 1, 8, 9, 6, 4, 0, 0,
        0, 0, 8, 1, 0, 2, 9, 0, 0, 7, 0, 0, 5, 0, 4, 1, 0, 8, 0, 0, 6, 7, 0, 8, 2, 0, 0,
        0, 0, 2, 6, 0, 9, 5, 0, 0, 8, 0, 0, 2, 0, 3, 0, 0, 9, 0, 0, 5, 0, 1, 7, 3, 0, 0,
    };
    const given_bits: board.CellMask = 0x54949b0d901361b25254;
    engine.state.board = try board.fromFlat(flat, .{ .given_bits = given_bits });
    engine.state.board.validate();
    engine.appendEventMsg("existing message");

    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .set_config = .{ .field = "warn_solvability", .value = .{ .on = true } } });
    _ = flow.next(.start);
    // Toggle on again: the sentence is already showing, so nothing is appended.
    var flow2 = CommandFlow.init(&engine, &session, &cfg, .{ .set_config = .{ .field = "warn_solvability", .value = .{ .on = true } } });
    const shown2 = flow2.next(.start).show_game;
    try testing.expectEqualStrings("existing message " ++ hint_command.no_solution_msg, shown2.frame.status.?);
}

test "a refused set_config shows core's sentence, changes nothing and persists nothing" {
    var cfg = config.Config.default();
    const before = cfg;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    for ([_]struct { change: config_table.Change, msg: []const u8 }{
        .{ .change = .{ .field = "nope", .value = .{ .on = true } }, .msg = config_table.UNKNOWN_FIELD_MSG },
        .{ .change = .{ .field = "theme", .value = .{ .choice = "pink" } }, .msg = config_table.BAD_VALUE_MSG },
    }) |case| {
        var flow = CommandFlow.init(&engine, &session, &cfg, .{ .set_config = case.change });
        try testing.expectEqualStrings(case.msg, flow.next(.start).prompt_message.text);
        try testing.expect(flow.next(.ack) == .done);
    }
    try testing.expectEqual(before, cfg);
}

test "open asks for a game file, loads the pick and makes it the current file" {
    var cfg = config.Config.default();
    cfg.auto_save = false;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    const saved = try engine.toSaveFormat(testing.allocator);
    defer testing.allocator.free(saved);
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });

    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .open = .{ .path = null } });
    try testing.expect(flow.next(.start).open == null);
    const shown = flow.next(.{ .read = .{ .file = .{ .bytes = saved, .name = "game.sud" } } }).show_game;
    try testing.expect(shown.loaded);
    try testing.expectEqualStrings("game.sud", shown.file.?);
    try testing.expect(!shown.legend.undo);
    try testing.expectEqualStrings("game.sud", session.currentFile().?);
    try testing.expect(flow.next(.ack) == .done);
}

test "a typed path rides the import step; backing out of the picker clears the status" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    const before = engine.state.board;
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .import = .{ .path = "puzzle.txt" } });
    try testing.expectEqualStrings("puzzle.txt", flow.next(.start).import_puzzle.?);
    try testing.expectEqualStrings(LOAD_ENDED_STATUS, flow.next(.{ .read = .cancelled }).show_status);
    try testing.expect(@import("../board/board.zig").equal(engine.state.board, before));
}

test "an import that is not a puzzle shows the error and keeps the board" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    const before = engine.state.board;
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .import = .{ .path = null } });
    _ = flow.next(.start);
    try testing.expect(flow.next(.{ .read = .{ .file = .{ .bytes = "123", .name = "bad.txt" } } }) == .prompt_message);
    try testing.expectEqualStrings(LOAD_ENDED_STATUS, flow.next(.{ .pressed = 0 }).show_status);
    try testing.expect(@import("../board/board.zig").equal(engine.state.board, before));
}

test "an open the platform could not read shows the error, then clears the status" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .open = .{ .path = null } });
    _ = flow.next(.start);
    try testing.expectEqualStrings(OPEN_FAILED_MSG, flow.next(.{ .read = .{ .failed = "disk gone" } }).prompt_message.text);
    try testing.expectEqualStrings(LOAD_ENDED_STATUS, flow.next(.{ .pressed = 0 }).show_status);
    try testing.expect(flow.next(.ack) == .done);
}

test "paste with a line skips the clipboard; without one it reads the clipboard" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    const line = puzzle_gen.PuzzleGen.medium();

    var typed = CommandFlow.init(&engine, &session, &cfg, .{ .paste = .{ .line = line } });
    const shown = typed.next(.start).show_game;
    try testing.expect(shown.loaded);
    try testing.expectEqualStrings(game_engine.PASTED_MSG, shown.frame.status.?);

    var clipboard = CommandFlow.init(&engine, &session, &cfg, .{ .paste = .{ .line = null } });
    try testing.expect(clipboard.next(.start) == .paste_puzzle);
    try testing.expectEqualStrings(PASTE_FAILED_MSG, clipboard.next(.{ .read = .{ .failed = "denied" } }).prompt_message.text);
}

test "new generates at the chosen difficulty, which the game then keeps" {
    var cfg = config.Config.default();
    cfg.difficulty = .hard;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    session.setCurrentFile("game.sud");
    session.apply(.open_success);

    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .new = .{ .difficulty = .easy } });
    try testing.expectEqual(puzzle_gen.Difficulty.easy, flow.next(.start).generate_game);
    const shown = flow.next(.{ .generated = .{ .line = puzzle_gen.PuzzleGen.easy() } }).show_game;
    try testing.expect(shown.loaded);
    try testing.expectEqual(puzzle_gen.Difficulty.easy, shown.config.difficulty);
    try testing.expectEqual(@import("../file_policy.zig").WriteContext.detached, session.write_context);
}

test "save with no current file asks for the default target, writes it and reports where" {
    var cfg = config.Config.default();
    cfg.auto_save = false;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, &cfg, .{ .save = .{ .path = null } });
    try testing.expect(flow.next(.start) == .resolve_default_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .default_target = "sudoku.sud" }).save.name);
    try testing.expectEqualStrings(std.fmt.comptimePrint(@import("../file_policy.zig").SAVED_TO_FMT, .{"sudoku.sud"}), flow.next(.{ .wrote = .{ .ok = "sudoku.sud" } }).show_status);
    try testing.expect(flow.next(.ack) == .done);
    try testing.expectEqualStrings("sudoku.sud", session.currentFile().?);
}

test "save as suggests the current file; export and copy hand over the puzzle" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    session.setCurrentFile("game.sud");
    var save_as = CommandFlow.init(&engine, &session, &cfg, .{ .save_as = .{ .path = null } });
    try testing.expectEqualStrings("game.sud", save_as.next(.start).save_as.name);

    var exported = CommandFlow.init(&engine, &session, &cfg, .{ .@"export" = .{ .path = null } });
    try testing.expectEqualStrings(export_mod.DEFAULT_EXPORT_FILE, exported.next(.start).export_puzzle);
    try testing.expectEqualStrings(std.fmt.comptimePrint(export_mod.EXPORTED_TO_FMT, .{"puzzle.txt"}), exported.next(.{ .wrote = .{ .ok = "puzzle.txt" } }).show_status);

    var copied = CommandFlow.init(&engine, &session, &cfg, .{ .copy = {} });
    try testing.expect(copied.next(.start) == .copy_puzzle);
    try testing.expectEqualStrings(export_mod.COPIED_MSG, copied.next(.{ .copied = .ok }).show_status);
    try testing.expectEqualStrings("game.sud", session.currentFile().?);
}

test "stopping generation ends New by clearing the status; a wrong answer is an error" {
    var cfg = config.Config.default();
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var stopped = CommandFlow.init(&engine, &session, &cfg, .{ .new = .{} });
    _ = stopped.next(.start);
    try testing.expectEqualStrings(LOAD_ENDED_STATUS, stopped.next(.{ .generated = .cancelled }).show_status);

    var wrong = CommandFlow.init(&engine, &session, &cfg, .{ .new = .{} });
    _ = wrong.next(.start);
    try testing.expectEqualStrings(step_mod.UNEXPECTED_INPUT_MSG, wrong.next(.ack).prompt_message.text);
}

test "every message a command can show in a dialog reads as a sentence" {
    const sentence = @import("../../test/sentence.zig");
    for ([_][]const u8{
        OPEN_FAILED_MSG,
        IMPORT_FAILED_MSG,
        PASTE_FAILED_MSG,
        step_mod.GENERATE_FAILED_MSG,
        step_mod.UNEXPECTED_INPUT_MSG,
        save_mod.SAVE_FAILED_MSG,
        save_mod.NAME_TOO_LONG_MSG,
        export_mod.EXPORT_FAILED_MSG,
        export_mod.COPY_FAILED_MSG,
        config_flow.PERSIST_FAILED_MSG,
    }) |msg| try sentence.expectSentence(msg);
}

test "a load that cannot be remembered says the game is loaded and names its repair" {
    const sentence = @import("../../test/sentence.zig");
    try sentence.expectSentence(LOADED_SETTINGS_REFUSED_MSG);
    try testing.expect(std.mem.indexOf(u8, LOADED_SETTINGS_REFUSED_MSG, "The game was loaded") != null);
    try testing.expect(std.mem.indexOf(u8, LOADED_SETTINGS_REFUSED_MSG, "the next launch will not reopen it") != null);
    // The cause's own repair travels with the news that the game was loaded.
    try testing.expect(std.mem.indexOf(u8, LOADED_SETTINGS_REFUSED_MSG, "Repair or delete") != null);
    try sentence.expectSentence(LOADED_SETTINGS_WRITE_FAILED_MSG);
    try testing.expect(std.mem.indexOf(u8, LOADED_SETTINGS_WRITE_FAILED_MSG, "disk has space") != null);
    try testing.expect(std.mem.indexOf(u8, LOADED_SETTINGS_WRITE_FAILED_MSG, "Repair or delete") == null);
    try testing.expectEqualStrings(LOADED_SETTINGS_REFUSED_MSG, loadedNotRememberedMsg(.settings_unreadable));
    try testing.expectEqualStrings(LOADED_SETTINGS_WRITE_FAILED_MSG, loadedNotRememberedMsg(.settings_unwritable));
}
