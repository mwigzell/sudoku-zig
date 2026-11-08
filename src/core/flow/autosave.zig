// AutosaveFlow: after a state-changing command, write the game to the current
// file (or the platform default) through the same steps as Save.
const std = @import("std");
const file_policy = @import("../file_policy.zig");
const command = @import("../command.zig");
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
    kind: Kind,
    phase: Phase = .start,
    save: SaveFlow = undefined,

    const Kind = union(enum) { after_command: command.CommandTag, flush };
    const Phase = enum { start, resolving, saving, finished };

    /// Autosave after `tag` ran; skipped when autosave is off or the command does not change the game.
    pub fn afterCommand(session: *FileSession, auto_save: bool, tag: command.CommandTag) AutosaveFlow {
        return .{ .session = session, .auto_save = auto_save, .kind = .{ .after_command = tag } };
    }

    /// Final write when the app is closing: only continues an existing current file, since nobody can be asked.
    pub fn flush(session: *FileSession, auto_save: bool) AutosaveFlow {
        return .{ .session = session, .auto_save = auto_save, .kind = .flush };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *AutosaveFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.finish(step_mod.promptError(step_mod.UNEXPECTED_INPUT_MSG));
                if (!self.auto_save) return self.finish(.done);
                return switch (self.kind) {
                    .after_command => |tag| self.startAfterCommand(tag),
                    .flush => self.startFlush(),
                };
            },
            .resolving => {
                const name = switch (input) {
                    .default_target => |n| n,
                    else => return self.finish(step_mod.promptError(step_mod.UNEXPECTED_INPUT_MSG)),
                };
                return self.saveTo(name);
            },
            .saving => {
                const step = self.save.next(input);
                return if (step_mod.isTerminal(step)) self.finish(step) else step;
            },
            .finished => return .done,
        }
    }

    fn startAfterCommand(self: *AutosaveFlow, tag: command.CommandTag) Step {
        if (!file_policy.commandTriggersAutoSave(tag)) return self.finish(.done);
        if (self.session.currentFile()) |current| return self.saveTo(current);
        self.phase = .resolving;
        return .resolve_default_target;
    }

    fn startFlush(self: *AutosaveFlow) Step {
        if (self.session.write_context != .continuation) return self.finish(.done);
        const current = self.session.currentFile() orelse return self.finish(.done);
        self.save = SaveFlow.flush(self.session, current);
        self.phase = .saving;
        return self.next(.start);
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
    var flow = AutosaveFlow.afterCommand(&session, false, .fill);
    try testing.expect(flow.next(.start) == .done);
}

test "commands that do not change the game do not autosave" {
    var session = FileSession{};
    var flow = AutosaveFlow.afterCommand(&session, true, .set_config);
    try testing.expect(flow.next(.start) == .done);
}

test "with no current file autosave asks the platform for its default target" {
    var session = FileSession{};
    var flow = AutosaveFlow.afterCommand(&session, true, .fill);
    try testing.expect(flow.next(.start) == .resolve_default_target);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .default_target = "sudoku.sud" }).autosave.name);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "sudoku.sud" } }) == .done);
    try testing.expectEqualStrings("sudoku.sud", session.currentFile().?);
    try testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
}

test "autosave follows the current file" {
    var session = FileSession{ .write_context = .continuation };
    session.setCurrentFile("/docs/game.sud");
    var flow = AutosaveFlow.afterCommand(&session, true, .undo);
    try testing.expectEqualStrings("/docs/game.sud", flow.next(.start).autosave.name);
    const write = flow.next(.{ .wrote = .exists }).autosave;
    try testing.expectEqualStrings("/docs/game.sud", write.name);
    try testing.expect(write.replace);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "/docs/game.sud" } }) == .done);
}

test "autosave onto an existing file after New asks first and keeps it when declined" {
    var session = FileSession{};
    session.setCurrentFile("game.sud");
    session.apply(.new_game_success);
    var flow = AutosaveFlow.afterCommand(&session, true, .paste);
    _ = flow.next(.start);
    try testing.expectEqualStrings(std.fmt.comptimePrint(file_policy.REPLACE_CONFIRM_FMT, .{"game.sud"}), flow.next(.{ .wrote = .exists }).prompt_message.text);
    try testing.expect(flow.next(.{ .pressed = step_mod.QUESTION_CANCEL }) == .done);
    try testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
}

test "autosave write failure is shown" {
    var session = FileSession{};
    session.setCurrentFile("game.sud");
    var flow = AutosaveFlow.afterCommand(&session, true, .fill);
    _ = flow.next(.start);
    try testing.expectEqualStrings(save_mod.SAVE_FAILED_MSG, flow.next(.{ .wrote = .{ .failed = "AccessDenied" } }).prompt_message.text);
}

test "flush writes the current file's restore copy" {
    var session = FileSession{ .write_context = .continuation };
    session.setCurrentFile("game.sud");
    var flow = AutosaveFlow.flush(&session, true);
    try testing.expectEqualStrings("game.sud", flow.next(.start).flush);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "game.sud" } }) == .done);
}

test "flush never writes a detached game, since nobody can be asked" {
    var session = FileSession{};
    session.setCurrentFile("game.sud");
    var flow = AutosaveFlow.flush(&session, true);
    try testing.expect(flow.next(.start) == .done);
}

test "flush with autosave off does nothing" {
    var session = FileSession{ .write_context = .continuation };
    session.setCurrentFile("game.sud");
    var flow = AutosaveFlow.flush(&session, false);
    try testing.expect(flow.next(.start) == .done);
}
