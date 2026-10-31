// SaveFlow: one write to a named target — check it, ask before replacing,
// write, then update the FileSession. Save, Save As and autosave all use it.
const std = @import("std");
const file_policy = @import("../file_policy.zig");
const step_mod = @import("step.zig");
const file_session_mod = @import("file_session.zig");

const Step = step_mod.Step;
const Input = step_mod.Input;
const FileSession = file_session_mod.FileSession;
const MAX_NAME_LEN = file_session_mod.MAX_NAME_LEN;

/// Shown when the save target name cannot be kept by the flow.
pub const NAME_TOO_LONG_MSG = "The file name is too long to save.";

pub const SaveFlow = struct {
    session: *FileSession,
    intent: file_policy.WriteIntent,
    name_buf: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    text_buf: [MAX_NAME_LEN + 128]u8 = undefined,
    phase: Phase = .start,

    const Phase = enum { start, checking, asking, writing, finished };

    /// A flow writing `name`; the first `next(.start)` checks the target.
    pub fn init(session: *FileSession, intent: file_policy.WriteIntent, name: []const u8) SaveFlow {
        var flow = SaveFlow{ .session = session, .intent = intent };
        if (name.len <= flow.name_buf.len) {
            std.mem.copyForwards(u8, flow.name_buf[0..name.len], name);
            flow.name_len = name.len;
        }
        return flow;
    }

    fn targetName(self: *const SaveFlow) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Skip the check and write now; only valid when the policy cannot ask.
    pub fn beginWrite(self: *SaveFlow) Step {
        self.phase = .writing;
        return .{ .write = self.targetName() };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *SaveFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.fail(step_mod.UNEXPECTED_INPUT_MSG);
                if (self.name_len == 0) return self.fail(NAME_TOO_LONG_MSG);
                self.phase = .checking;
                return .{ .check_target = self.targetName() };
            },
            .checking => {
                const exists = switch (input) {
                    .target_checked => |e| e,
                    else => return self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                };
                const decision = file_policy.evaluateOverwritePolicy(.{
                    .intent = self.intent,
                    .target_exists = exists,
                    .write_context = self.session.write_context,
                });
                return switch (decision) {
                    .write => self.beginWrite(),
                    .require_replace_confirm => self.askReplace(),
                };
            },
            .asking => {
                const yes = switch (input) {
                    .answered => |a| a,
                    else => return self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                };
                if (yes) return self.beginWrite();
                return self.finish(self.declinedStep());
            },
            .writing => {
                const wrote = switch (input) {
                    .wrote => |w| w,
                    else => return self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                };
                return switch (wrote) {
                    .ok => |written| self.succeeded(written),
                    .cancelled => self.finish(.done),
                    .failed => |msg| self.fail(msg),
                };
            },
            .finished => return .done,
        }
    }

    fn askReplace(self: *SaveFlow) Step {
        self.phase = .asking;
        const text = std.fmt.bufPrint(&self.text_buf, file_policy.REPLACE_CONFIRM_FMT, .{std.fs.path.basename(self.targetName())}) catch
            return self.fail(NAME_TOO_LONG_MSG);
        return .{ .ask = .{
            .title = file_policy.REPLACE_CONFIRM_TITLE,
            .text = text,
            .ok_label = file_policy.REPLACE_CONFIRM_OK_LABEL,
            .cancel_label = file_policy.REPLACE_CONFIRM_CANCEL_LABEL,
        } };
    }

    fn declinedStep(self: *const SaveFlow) Step {
        return switch (self.intent) {
            .save, .save_as => .{ .show_status = file_policy.WRITE_CANCELLED_MSG },
            .auto_save => .done,
        };
    }

    fn succeeded(self: *SaveFlow, written: []const u8) Step {
        self.session.setWorkingFile(written);
        self.session.apply(switch (self.intent) {
            .save => .save_success,
            .save_as => .save_as_success,
            .auto_save => .auto_save_success,
        });
        return switch (self.intent) {
            .save, .save_as => blk: {
                const text = std.fmt.bufPrint(&self.text_buf, file_policy.SAVED_TO_FMT, .{written}) catch
                    break :blk self.finish(.{ .show_status = written });
                break :blk self.finish(.{ .show_status = text });
            },
            .auto_save => self.finish(.done),
        };
    }

    fn fail(self: *SaveFlow, msg: []const u8) Step {
        const len = @min(msg.len, self.text_buf.len);
        std.mem.copyForwards(u8, self.text_buf[0..len], msg[0..len]);
        return self.finish(.{ .show_error = self.text_buf[0..len] });
    }

    fn finish(self: *SaveFlow, terminal: Step) Step {
        self.phase = .finished;
        return terminal;
    }
};

const testing = std.testing;

fn expectCheck(step: Step, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, step.check_target);
}

test "save to a new file writes without asking and reports where it saved" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save, "/docs/game.sud");
    try expectCheck(flow.next(.start), "/docs/game.sud");
    try testing.expectEqualStrings("/docs/game.sud", flow.next(.{ .target_checked = false }).write);
    const end = flow.next(.{ .wrote = .{ .ok = "/docs/game.sud" } });
    try testing.expectEqualStrings("saved to: /docs/game.sud", end.show_status);
    try testing.expectEqualStrings("/docs/game.sud", session.workingFile().?);
    try testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
}

test "save onto an existing file while detached asks before writing" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save, "/docs/game.sud");
    _ = flow.next(.start);
    const ask = flow.next(.{ .target_checked = true }).ask;
    try testing.expectEqualStrings(file_policy.REPLACE_CONFIRM_TITLE, ask.title);
    try testing.expectEqualStrings("game.sud already exists. Do you want to replace it?", ask.text);
    try testing.expectEqualStrings(file_policy.REPLACE_CONFIRM_OK_LABEL, ask.ok_label);
    try testing.expectEqualStrings(file_policy.REPLACE_CONFIRM_CANCEL_LABEL, ask.cancel_label);
    try testing.expectEqualStrings("/docs/game.sud", flow.next(.{ .answered = true }).write);
}

test "declining the replace question cancels the save without writing" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save_as, "game.sud");
    _ = flow.next(.start);
    _ = flow.next(.{ .target_checked = true });
    try testing.expectEqualStrings(file_policy.WRITE_CANCELLED_MSG, flow.next(.{ .answered = false }).show_status);
    try testing.expect(session.workingFile() == null);
    try testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
}

test "save onto an existing file while continuing writes without asking" {
    var session = FileSession{ .write_context = .continuation };
    var flow = SaveFlow.init(&session, .save, "game.sud");
    _ = flow.next(.start);
    try testing.expectEqualStrings("game.sud", flow.next(.{ .target_checked = true }).write);
}

test "write failure shows the error and leaves the session alone" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save, "game.sud");
    _ = flow.next(.start);
    _ = flow.next(.{ .target_checked = false });
    try testing.expectEqualStrings("disk full", flow.next(.{ .wrote = .{ .failed = "disk full" } }).show_error);
    try testing.expect(session.workingFile() == null);
    try testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
}

test "a cancelled platform picker ends the save silently" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save_as, "game.sud");
    _ = flow.next(.start);
    _ = flow.next(.{ .target_checked = false });
    try testing.expect(flow.next(.{ .wrote = .cancelled }) == .done);
}

test "the platform's written name becomes the working file" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save_as, "game.sud");
    _ = flow.next(.start);
    _ = flow.next(.{ .target_checked = false });
    try testing.expectEqualStrings("saved to: game (1).sud", flow.next(.{ .wrote = .{ .ok = "game (1).sud" } }).show_status);
    try testing.expectEqualStrings("game (1).sud", session.workingFile().?);
}

test "save and save as record their own success events" {
    var session = FileSession{};
    var save = SaveFlow.init(&session, .save, "a.sud");
    _ = save.next(.start);
    _ = save.next(.{ .target_checked = false });
    _ = save.next(.{ .wrote = .{ .ok = "a.sud" } });
    try testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);

    session.apply(.new_game_success);
    var save_as = SaveFlow.init(&session, .save_as, "b.sud");
    _ = save_as.next(.start);
    _ = save_as.next(.{ .target_checked = false });
    _ = save_as.next(.{ .wrote = .{ .ok = "b.sud" } });
    try testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
    try testing.expectEqualStrings("b.sud", session.workingFile().?);
}

test "an unexpected input ends the flow with an error" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save, "game.sud");
    _ = flow.next(.start);
    try testing.expectEqualStrings(step_mod.UNEXPECTED_INPUT_MSG, flow.next(.{ .answered = true }).show_error);
    try testing.expect(flow.next(.start) == .done);
}
