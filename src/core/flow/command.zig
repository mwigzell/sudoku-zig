// CommandFlow: one player command end to end — apply it, show the result, then
// persist settings and autosave as the command needs, in that order on every platform.
const std = @import("std");
const command = @import("../command.zig");
const config = @import("../config.zig");
const game_engine = @import("../engine/game_engine.zig");
const step_mod = @import("step.zig");
const file_session_mod = @import("file_session.zig");
const settings_mod = @import("settings.zig");
const autosave_mod = @import("autosave.zig");

const Step = step_mod.Step;
const Input = step_mod.Input;
const FileSession = file_session_mod.FileSession;
const SettingsFlow = settings_mod.SettingsFlow;
const AutosaveFlow = autosave_mod.AutosaveFlow;

pub const CommandFlow = struct {
    engine: *game_engine.GameEngine,
    session: *FileSession,
    cmd: command.Command,
    phase: Phase = .start,
    settings: SettingsFlow = undefined,
    autosave: AutosaveFlow = undefined,

    const Phase = enum { start, showing, persisting, autosaving, finished };

    /// Run `cmd` on `engine`; `session` is the file the follow-up autosave writes.
    pub fn init(engine: *game_engine.GameEngine, session: *FileSession, cmd: command.Command) CommandFlow {
        return .{ .engine = engine, .session = session, .cmd = cmd };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *CommandFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.finish(.{ .show_error = step_mod.UNEXPECTED_INPUT_MSG });
                switch (self.engine.exec(self.cmd)) {
                    .error_msg => |msg| return self.finish(.{ .show_error = msg }),
                    .ok => |ev| {
                        self.phase = .showing;
                        var shown = step_mod.showGame(self.engine, ev.msg, self.session.workingFile());
                        shown.show_game.cell = ev.cell;
                        return shown;
                    },
                }
            },
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
    try testing.expect(flow.next(.{ .persisted = .{ .failed = "disk full" } }) == .show_error);
}
