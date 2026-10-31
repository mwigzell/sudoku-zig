// AutosaveFlow: after a state-changing command, write the game to the working
// file (or the platform default) through the same steps as Save.
const std = @import("std");
const file_policy = @import("../file_policy.zig");
const step_mod = @import("step.zig");
const file_session_mod = @import("file_session.zig");
const save_mod = @import("save.zig");

const Step = step_mod.Step;
const Input = step_mod.Input;
const FileSession = file_session_mod.FileSession;
const SaveFlow = save_mod.SaveFlow;

pub const AutosaveFlow = struct {
    session: *FileSession,
    auto_save: bool,
    command_name: []const u8,
    kind: Kind,
    phase: Phase = .start,
    save: SaveFlow = undefined,

    const Kind = enum { after_command, flush };
    const Phase = enum { start, resolving, saving, finished };

    /// Autosave after `command_name` ran; skipped when autosave is off or the command does not change the game.
    pub fn afterCommand(session: *FileSession, auto_save: bool, command_name: []const u8) AutosaveFlow {
        return .{ .session = session, .auto_save = auto_save, .command_name = command_name, .kind = .after_command };
    }

    /// Final write when the app is closing: only continues an existing working file, since nobody can be asked.
    pub fn flush(session: *FileSession, auto_save: bool) AutosaveFlow {
        return .{ .session = session, .auto_save = auto_save, .command_name = "", .kind = .flush };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *AutosaveFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.finish(.{ .show_error = step_mod.UNEXPECTED_INPUT_MSG });
                if (!self.auto_save) return self.finish(.done);
                return switch (self.kind) {
                    .after_command => self.startAfterCommand(),
                    .flush => self.startFlush(),
                };
            },
            .resolving => {
                const name = switch (input) {
                    .default_target => |n| n,
                    else => return self.finish(.{ .show_error = step_mod.UNEXPECTED_INPUT_MSG }),
                };
                return self.saveTo(name);
            },
            .saving => {
                const step = self.save.next(input);
                return switch (step) {
                    .show_status, .show_error, .done => self.finish(step),
                    else => step,
                };
            },
            .finished => return .done,
        }
    }

    fn startAfterCommand(self: *AutosaveFlow) Step {
        if (!file_policy.commandTriggersAutoSaveByName(self.command_name)) return self.finish(.done);
        const working = self.session.workingFile();
        switch (file_policy.autoSaveTarget(.{ .has_working_file = working != null })) {
            .working_file => return self.saveTo(working.?),
            .default_visible => {
                self.phase = .resolving;
                return .resolve_default_target;
            },
        }
    }

    fn startFlush(self: *AutosaveFlow) Step {
        if (self.session.write_context != .continuation) return self.finish(.done);
        const working = self.session.workingFile() orelse return self.finish(.done);
        self.save = SaveFlow.init(self.session, .auto_save, working);
        self.phase = .saving;
        return self.save.beginWrite();
    }

    fn saveTo(self: *AutosaveFlow, name: []const u8) Step {
        self.save = SaveFlow.init(self.session, .auto_save, name);
        self.phase = .saving;
        return self.next(.start);
    }

    fn finish(self: *AutosaveFlow, terminal: Step) Step {
        self.phase = .finished;
        return terminal;
    }
};

const testing = std.testing;

test "autosave off does nothing" {
    var session = FileSession{};
    var flow = AutosaveFlow.afterCommand(&session, false, "fill");
    try testing.expect(flow.next(.start) == .done);
}

test "commands that do not change the game do not autosave" {
    var session = FileSession{};
    var flow = AutosaveFlow.afterCommand(&session, true, "set_theme");
    try testing.expect(flow.next(.start) == .done);
}

test "with no working file autosave asks the platform for its default target" {
    var session = FileSession{};
    var flow = AutosaveFlow.afterCommand(&session, true, "fill");
    try testing.expect(flow.next(.start) == .resolve_default_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .default_target = "sudoku.sud" }).check_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .target_checked = false }).write);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "sudoku.sud" } }) == .done);
    try testing.expectEqualStrings("sudoku.sud", session.workingFile().?);
    try testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
}

test "autosave follows the working file" {
    var session = FileSession{ .write_context = .continuation };
    session.setWorkingFile("/docs/game.sud");
    var flow = AutosaveFlow.afterCommand(&session, true, "undo");
    try testing.expectEqualStrings("/docs/game.sud", flow.next(.start).check_target);
    try testing.expectEqualStrings("/docs/game.sud", flow.next(.{ .target_checked = true }).write);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "/docs/game.sud" } }) == .done);
}

test "autosave onto an existing file after New asks first and keeps it when declined" {
    var session = FileSession{};
    session.setWorkingFile("game.sud");
    session.apply(.new_game_success);
    var flow = AutosaveFlow.afterCommand(&session, true, "paste");
    _ = flow.next(.start);
    try testing.expectEqualStrings("game.sud already exists. Do you want to replace it?", flow.next(.{ .target_checked = true }).ask.text);
    try testing.expect(flow.next(.{ .answered = false }) == .done);
    try testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
}

test "autosave write failure is shown" {
    var session = FileSession{};
    session.setWorkingFile("game.sud");
    var flow = AutosaveFlow.afterCommand(&session, true, "fill");
    _ = flow.next(.start);
    _ = flow.next(.{ .target_checked = false });
    try testing.expectEqualStrings("AccessDenied", flow.next(.{ .wrote = .{ .failed = "AccessDenied" } }).show_error);
}

test "flush continues the working file without checking" {
    var session = FileSession{ .write_context = .continuation };
    session.setWorkingFile("game.sud");
    var flow = AutosaveFlow.flush(&session, true);
    try testing.expectEqualStrings("game.sud", flow.next(.start).write);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "game.sud" } }) == .done);
}

test "flush never writes a detached game, since nobody can be asked" {
    var session = FileSession{};
    session.setWorkingFile("game.sud");
    var flow = AutosaveFlow.flush(&session, true);
    try testing.expect(flow.next(.start) == .done);
}

test "flush with autosave off does nothing" {
    var session = FileSession{ .write_context = .continuation };
    session.setWorkingFile("game.sud");
    var flow = AutosaveFlow.flush(&session, false);
    try testing.expect(flow.next(.start) == .done);
}
