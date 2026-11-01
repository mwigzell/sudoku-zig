// CommandFlow: one player command end to end — gather what a load needs, apply it, show
// the result, then persist settings and autosave as the command needs, in that order on every platform.
// Save, Save As, Export and Copy run their write flow instead.
const std = @import("std");
const command = @import("../command.zig");
const config = @import("../config.zig");
const game_engine = @import("../engine/game_engine.zig");
const step_mod = @import("step.zig");
const file_session_mod = @import("file_session.zig");
const settings_mod = @import("settings.zig");
const autosave_mod = @import("autosave.zig");
const save_mod = @import("save.zig");
const export_mod = @import("export.zig");
const logger = @import("../logger.zig");

const log = logger.Logger(.flow);

const Step = step_mod.Step;
const Input = step_mod.Input;
const FileSession = file_session_mod.FileSession;
const SettingsFlow = settings_mod.SettingsFlow;
const AutosaveFlow = autosave_mod.AutosaveFlow;
const SaveFlow = save_mod.SaveFlow;
const ExportFlow = export_mod.ExportFlow;

/// Shown when the platform could not read the chosen game; its reason goes to the log.
pub const OPEN_FAILED_MSG = "The game could not be opened.";
/// Shown when the platform could not read the chosen puzzle file; its reason goes to the log.
pub const IMPORT_FAILED_MSG = "The puzzle could not be imported.";
/// Shown when the platform could not read a puzzle from the clipboard; its reason goes to the log.
pub const PASTE_FAILED_MSG = "There is no puzzle on the clipboard to paste.";

pub const CommandFlow = struct {
    engine: *game_engine.GameEngine,
    session: *FileSession,
    cmd: command.Command,
    phase: Phase = .start,
    settings: SettingsFlow = undefined,
    autosave: AutosaveFlow = undefined,
    write: Write = undefined,

    const Phase = enum { start, gathering, writing, showing, persisting, autosaving, finished };
    const Write = union(enum) { save: SaveFlow, @"export": ExportFlow };

    /// Run `cmd` on `engine`; `session` is the file the follow-up autosave writes.
    pub fn init(engine: *game_engine.GameEngine, session: *FileSession, cmd: command.Command) CommandFlow {
        return .{ .engine = engine, .session = session, .cmd = cmd };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *CommandFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.finish(.{ .show_error = step_mod.UNEXPECTED_INPUT_MSG });
                return self.gather();
            },
            .gathering => return self.gathered(input),
            .writing => return self.continueWrite(input),
            .showing => {
                if (input != .ack) return self.finish(.{ .show_error = step_mod.UNEXPECTED_INPUT_MSG });
                self.settings = SettingsFlow.afterCommand(self.engine.getConfig(), @tagName(self.cmd));
                self.phase = .persisting;
                return self.continueSettings(.start);
            },
            .persisting => return self.continueSettings(input),
            .autosaving => return self.continueAutosave(input),
            .finished => return .done,
        }
    }

    /// Ask the platform for what a load needs, unless the command already carries it.
    fn gather(self: *CommandFlow) Step {
        const step: Step = switch (self.cmd) {
            .new => |data| if (data.puzzle) |line|
                return self.load(.new_game, line)
            else
                .{ .generate = data.difficulty orelse self.engine.cfg.difficulty },
            .open => |data| .{ .pick_open = .{ .kind = .game, .path = data.path } },
            .import => |data| .{ .pick_open = .{ .kind = .puzzle, .path = data.path } },
            .paste => |data| if (data.line) |line| return self.load(.paste, line) else .read_clipboard,
            .save => |data| return self.startWrite(.{ .save = SaveFlow.forCommand(self.session, .save, data.path, self.engine.cfg.auto_save) }),
            .save_as => |data| return self.startWrite(.{ .save = SaveFlow.forCommand(self.session, .save_as, data.path, self.engine.cfg.auto_save) }),
            .@"export" => |data| return self.startWrite(.{ .@"export" = ExportFlow.toFile(data.path) }),
            .copy => return self.startWrite(.{ .@"export" = ExportFlow.toClipboard() }),
            else => return self.show(self.engine.exec(self.cmd)),
        };
        self.phase = .gathering;
        return step;
    }

    /// Load what the platform gathered; backing out ends the command quietly.
    fn gathered(self: *CommandFlow, input: Input) Step {
        const unexpected: Step = .{ .show_error = step_mod.UNEXPECTED_INPUT_MSG };
        switch (self.cmd) {
            .new => {
                if (input != .generated) return self.finish(unexpected);
                return switch (input.generated) {
                    .line => |line| self.load(.new_game, line),
                    .cancelled => self.finish(.done),
                    .failed => |reason| self.failed(step_mod.GENERATE_FAILED_MSG, reason),
                };
            },
            .open, .import => {
                if (input != .picked) return self.finish(unexpected);
                return switch (input.picked) {
                    .file => |file| switch (self.cmd) {
                        .open => self.load(.{ .open = file.name }, file.bytes),
                        else => self.load(.import, file.bytes),
                    },
                    .cancelled => self.finish(.done),
                    .failed => |reason| self.failed(if (self.cmd == .open) OPEN_FAILED_MSG else IMPORT_FAILED_MSG, reason),
                };
            },
            .paste => {
                if (input != .file_read) return self.finish(unexpected);
                return switch (input.file_read) {
                    .bytes => |text| self.load(.paste, text),
                    .failed => |reason| self.failed(PASTE_FAILED_MSG, reason),
                };
            },
            else => return self.finish(unexpected),
        }
    }

    /// Replace the game from `data` and record the load, so later writes know whose file this is.
    fn load(self: *CommandFlow, loaded: file_session_mod.Load, data: []const u8) Step {
        const ev = switch (loaded) {
            .new_game => self.engine.newFromOneLinePuzzle(data),
            .open => |name| self.engine.openFromSave(data, name),
            .import => self.engine.importFromLine(data),
            .paste => self.engine.pasteFromLine(data),
        };
        if (ev == .ok) {
            self.session.noteLoad(loaded);
            if (self.cmd == .new) {
                if (self.cmd.new.difficulty) |d| self.engine.cfg.difficulty = d;
            }
        }
        var step = self.show(ev);
        if (step == .show_game) step.show_game.loaded = true;
        return step;
    }

    fn show(self: *CommandFlow, ev: game_engine.Event) Step {
        switch (ev) {
            .error_msg => |msg| return self.finish(.{ .show_error = msg }),
            .ok => |ok| {
                self.phase = .showing;
                var shown = step_mod.showGame(self.engine, ok.msg, self.session.workingFile());
                shown.show_game.cell = ok.cell;
                return shown;
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
        return switch (step) {
            .show_status, .show_error, .done => self.finish(step),
            else => step,
        };
    }

    fn continueSettings(self: *CommandFlow, input: Input) Step {
        const step = self.settings.next(input);
        switch (step) {
            .done => {},
            .show_status, .show_error => return self.finish(step),
            else => return step,
        }
        self.autosave = AutosaveFlow.afterCommand(self.session, self.engine.cfg.auto_save, @tagName(self.cmd));
        self.phase = .autosaving;
        return self.continueAutosave(.start);
    }

    fn continueAutosave(self: *CommandFlow, input: Input) Step {
        const step = self.autosave.next(input);
        return switch (step) {
            .show_status, .show_error, .done => self.finish(step),
            else => step,
        };
    }

    fn failed(self: *CommandFlow, msg: []const u8, reason: []const u8) Step {
        log.info("{s} failed: {s}", .{ @tagName(self.cmd), reason });
        return self.finish(.{ .show_error = msg });
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

test "a toggle shows the new setting, then persists it, and does not autosave" {
    var cfg = config.Config.default();
    cfg.auto_save = false;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, .{ .toggle_auto_save = {} });

    const shown = flow.next(.start).show_game;
    try testing.expect(shown.config.auto_save);
    try testing.expect(flow.next(.ack).persist_settings.auto_save);
    try testing.expect(flow.next(.{ .persisted = .ok }) == .done);
}

test "a move shows the board and the edited cell, then autosaves to the default target" {
    var cfg = config.Config.default();
    cfg.auto_save = true;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, .{ .fill = .{ .row = 0, .col = 0, .digit = .four } });

    const shown = flow.next(.start).show_game;
    try testing.expectEqual(@as(u4, 0), shown.cell.?.row);
    try testing.expect(shown.legend.undo);
    try testing.expect(flow.next(.ack) == .resolve_default_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .default_target = "sudoku.sud" }).check_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .target_checked = false }).write);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "sudoku.sud" } }) == .done);
}

test "a rejected command shows the engine's error and nothing else" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, .{ .fill = .{ .row = 0, .col = 2, .digit = .four } });
    try testing.expect(flow.next(.start) == .show_error);
    try testing.expect(flow.next(.ack) == .done);
}

test "a failed settings write ends the command with the error" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, .{ .set_theme = .light });
    _ = flow.next(.start);
    _ = flow.next(.ack);
    try testing.expectEqualStrings(settings_mod.PERSIST_FAILED_MSG, flow.next(.{ .persisted = .{ .failed = "disk full" } }).show_error);
}

test "open asks for a game file, loads the pick and makes it the working file" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    const saved = try engine.toSaveFormat(testing.allocator);
    defer testing.allocator.free(saved);
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });

    var flow = CommandFlow.init(&engine, &session, .{ .open = .{ .path = null } });
    const pick = flow.next(.start).pick_open;
    try testing.expectEqual(step_mod.OpenKind.game, pick.kind);
    try testing.expect(pick.path == null);
    const shown = flow.next(.{ .picked = .{ .file = .{ .bytes = saved, .name = "game.sud" } } }).show_game;
    try testing.expect(shown.loaded);
    try testing.expectEqualStrings("game.sud", shown.file.?);
    try testing.expect(!shown.legend.undo);
    try testing.expectEqualStrings("game.sud", session.workingFile().?);
    try testing.expect(flow.next(.ack) == .done);
}

test "a typed path rides the pick step; backing out of the picker ends quietly" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    const before = engine.state.board;
    var flow = CommandFlow.init(&engine, &session, .{ .import = .{ .path = "puzzle.txt" } });
    const pick = flow.next(.start).pick_open;
    try testing.expectEqual(step_mod.OpenKind.puzzle, pick.kind);
    try testing.expectEqualStrings("puzzle.txt", pick.path.?);
    try testing.expect(flow.next(.{ .picked = .cancelled }) == .done);
    try testing.expect(@import("../board/board.zig").equal(engine.state.board, before));
}

test "an import that is not a puzzle shows the error and keeps the board" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    const before = engine.state.board;
    var flow = CommandFlow.init(&engine, &session, .{ .import = .{ .path = null } });
    _ = flow.next(.start);
    try testing.expect(flow.next(.{ .picked = .{ .file = .{ .bytes = "123", .name = "bad.txt" } } }) == .show_error);
    try testing.expect(@import("../board/board.zig").equal(engine.state.board, before));
}

test "paste with a line skips the clipboard; without one it reads the clipboard" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    const line = puzzle_gen.PuzzleGen.medium();

    var typed = CommandFlow.init(&engine, &session, .{ .paste = .{ .line = line } });
    const shown = typed.next(.start).show_game;
    try testing.expect(shown.loaded);
    try testing.expectEqualStrings("The puzzle was pasted.", shown.status.?);

    var clipboard = CommandFlow.init(&engine, &session, .{ .paste = .{ .line = null } });
    try testing.expect(clipboard.next(.start) == .read_clipboard);
    try testing.expectEqualStrings(PASTE_FAILED_MSG, clipboard.next(.{ .file_read = .{ .failed = "denied" } }).show_error);
}

test "new generates at the chosen difficulty, which the game then keeps" {
    var cfg = config.Config.default();
    cfg.difficulty = .hard;
    var engine = try testEngine(cfg);
    defer engine.deinit();
    var session = FileSession{};
    session.setWorkingFile("game.sud");
    session.apply(.open_success);

    var flow = CommandFlow.init(&engine, &session, .{ .new = .{ .difficulty = .easy } });
    try testing.expectEqual(puzzle_gen.Difficulty.easy, flow.next(.start).generate);
    const shown = flow.next(.{ .generated = .{ .line = puzzle_gen.PuzzleGen.easy() } }).show_game;
    try testing.expect(shown.loaded);
    try testing.expectEqual(puzzle_gen.Difficulty.easy, shown.config.difficulty);
    try testing.expectEqual(@import("../file_policy.zig").WriteContext.detached, session.write_context);
}

test "save with no working file asks for the default target, writes it and reports where" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    var flow = CommandFlow.init(&engine, &session, .{ .save = .{ .path = null } });
    try testing.expect(flow.next(.start) == .resolve_default_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .default_target = "sudoku.sud" }).check_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .target_checked = false }).write);
    try testing.expectEqualStrings("The game was saved to sudoku.sud.", flow.next(.{ .wrote = .{ .ok = "sudoku.sud" } }).show_status);
    try testing.expect(flow.next(.ack) == .done);
    try testing.expectEqualStrings("sudoku.sud", session.workingFile().?);
}

test "save as suggests the working file; export and copy hand over the line" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    session.setWorkingFile("game.sud");
    var save_as = CommandFlow.init(&engine, &session, .{ .save_as = .{ .path = null } });
    try testing.expectEqualStrings("game.sud", save_as.next(.start).check_target);

    var exported = CommandFlow.init(&engine, &session, .{ .@"export" = .{ .path = null } });
    try testing.expectEqualStrings(export_mod.DEFAULT_EXPORT_FILE, exported.next(.start).write);
    try testing.expectEqualStrings("The puzzle was exported to puzzle.txt.", exported.next(.{ .wrote = .{ .ok = "puzzle.txt" } }).show_status);

    var copied = CommandFlow.init(&engine, &session, .{ .copy = {} });
    try testing.expect(copied.next(.start) == .copy_line);
    try testing.expectEqualStrings(export_mod.COPIED_MSG, copied.next(.{ .copied = .ok }).show_status);
    try testing.expectEqualStrings("game.sud", session.workingFile().?);
}

test "stopping generation ends New quietly; a wrong answer is an error" {
    var engine = try testEngine(config.Config.default());
    defer engine.deinit();
    var session = FileSession{};
    var stopped = CommandFlow.init(&engine, &session, .{ .new = .{} });
    _ = stopped.next(.start);
    try testing.expect(stopped.next(.{ .generated = .cancelled }) == .done);

    var wrong = CommandFlow.init(&engine, &session, .{ .new = .{} });
    _ = wrong.next(.start);
    try testing.expectEqualStrings(step_mod.UNEXPECTED_INPUT_MSG, wrong.next(.ack).show_error);
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
        settings_mod.PERSIST_FAILED_MSG,
    }) |msg| try sentence.expectSentence(msg);
}
