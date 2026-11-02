// SaveFlow: one write to a named target — check it, ask before replacing,
// write, then update the FileSession. Save, Save As and autosave all use it.
const std = @import("std");
const file_policy = @import("../file_policy.zig");
const step_mod = @import("step.zig");
const file_session_mod = @import("file_session.zig");
const logger = @import("../logger.zig");

const log = logger.Logger(.flow);

const Step = step_mod.Step;
const Input = step_mod.Input;
const FileSession = file_session_mod.FileSession;
const MAX_NAME_LEN = file_session_mod.MAX_NAME_LEN;

/// Shown when the save target name cannot be kept by the flow.
pub const NAME_TOO_LONG_MSG = "The file name is too long to save.";
/// Shown when the platform could not write the game; its reason goes to the log.
pub const SAVE_FAILED_MSG = "The game could not be saved.";

pub const SaveFlow = struct {
    session: *FileSession,
    intent: file_policy.WriteIntent,
    name_buf: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    text_buf: [MAX_NAME_LEN + 128]u8 = undefined,
    phase: Phase = .start,
    refused: bool = false,
    taken_text_len: usize = 0,

    const Phase = enum { start, naming, checking, asking, writing, asking_taken, picking, finished };

    /// A flow writing `name`; the first `next(.start)` checks the target.
    pub fn init(session: *FileSession, intent: file_policy.WriteIntent, name: []const u8) SaveFlow {
        var flow = SaveFlow{ .session = session, .intent = intent };
        flow.setName(name);
        return flow;
    }

    /// The Save or Save As the player asked for, to `path`, else the working file, else the
    /// platform's default target. A manual Save while autosave is on is refused, since every
    /// change is already written.
    pub fn forCommand(session: *FileSession, intent: file_policy.WriteIntent, path: ?[]const u8, auto_save: bool) SaveFlow {
        var flow = SaveFlow{ .session = session, .intent = intent, .refused = intent == .save and auto_save };
        if (path orelse session.workingFile()) |name| {
            flow.setName(name);
        } else {
            flow.phase = .naming;
        }
        return flow;
    }

    fn setName(self: *SaveFlow, name: []const u8) void {
        if (name.len > self.name_buf.len) return;
        std.mem.copyForwards(u8, self.name_buf[0..name.len], name);
        self.name_len = name.len;
    }

    fn targetName(self: *const SaveFlow) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn target(self: *const SaveFlow) step_mod.Target {
        const kind: step_mod.WriteKind = switch (self.intent) {
            .save => .save,
            .save_as => .save_as,
            .auto_save => .auto_save,
        };
        return .{ .name = self.targetName(), .kind = kind };
    }

    /// Skip the check and write now; only valid when the policy cannot ask.
    pub fn beginWrite(self: *SaveFlow) Step {
        self.phase = .writing;
        return .{ .write = self.target() };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *SaveFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.fail(step_mod.UNEXPECTED_INPUT_MSG);
                if (self.refused) return self.finish(.{ .show_status = file_policy.SAVE_WHILE_AUTO_SAVE_MSG });
                return self.check();
            },
            .naming => {
                if (input == .start) {
                    if (self.refused) return self.finish(.{ .show_status = file_policy.SAVE_WHILE_AUTO_SAVE_MSG });
                    return .resolve_default_target;
                }
                const name = switch (input) {
                    .default_target => |n| n,
                    else => return self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                };
                self.setName(name);
                return self.check();
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
                    .taken => |taken| self.askTaken(taken),
                    .failed => |reason| self.writeFailed(reason),
                };
            },
            .asking_taken => {
                const pick_existing = switch (input) {
                    .answered => |a| a,
                    else => return self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                };
                self.phase = .picking;
                if (pick_existing) return .pick_existing;
                return .{ .pick_new = self.targetName() };
            },
            .picking => {
                const wrote = switch (input) {
                    .wrote => |w| w,
                    else => return self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                };
                return switch (wrote) {
                    .ok => |written| self.succeeded(written),
                    .cancelled, .taken => self.repeatTakenAsk(),
                    .failed => |reason| self.writeFailed(reason),
                };
            },
            .finished => return .done,
        }
    }

    fn check(self: *SaveFlow) Step {
        if (self.name_len == 0) return self.fail(NAME_TOO_LONG_MSG);
        self.phase = .checking;
        return .{ .check_target = self.target() };
    }

    /// The platform's file belongs to an earlier install: ask whether to pick it or choose a new name.
    fn askTaken(self: *SaveFlow, taken: step_mod.Taken) Step {
        if (taken.name.len > 0 and taken.name.len <= self.name_buf.len) {
            std.mem.copyForwards(u8, self.name_buf[0..taken.name.len], taken.name);
            self.name_len = taken.name.len;
        }
        const text = std.fmt.bufPrint(&self.text_buf, file_policy.TAKEN_FMT, .{ self.targetName(), taken.dir }) catch
            return self.fail(NAME_TOO_LONG_MSG);
        self.taken_text_len = text.len;
        return self.repeatTakenAsk();
    }

    /// Until a picker writes a file there is nowhere to autosave, so a closed picker asks again.
    fn repeatTakenAsk(self: *SaveFlow) Step {
        self.phase = .asking_taken;
        return .{ .ask = .{
            .title = file_policy.TAKEN_TITLE,
            .text = self.text_buf[0..self.taken_text_len],
            .ok_label = file_policy.TAKEN_PICK_LABEL,
            .cancel_label = file_policy.TAKEN_NEW_NAME_LABEL,
        } };
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

    fn writeFailed(self: *SaveFlow, reason: []const u8) Step {
        log.info("write of {s} failed: {s}", .{ self.targetName(), reason });
        return self.fail(SAVE_FAILED_MSG);
    }

    fn fail(self: *SaveFlow, msg: []const u8) Step {
        return self.finish(.{ .show_error = msg });
    }

    fn finish(self: *SaveFlow, terminal: Step) Step {
        self.phase = .finished;
        return terminal;
    }
};

const testing = std.testing;

fn expectCheck(step: Step, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, step.check_target.name);
}

test "save to a new file writes without asking and reports where it saved" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save, "/docs/game.sud");
    try expectCheck(flow.next(.start), "/docs/game.sud");
    const write = flow.next(.{ .target_checked = false }).write;
    try testing.expectEqualStrings("/docs/game.sud", write.name);
    try testing.expectEqual(step_mod.WriteKind.save, write.kind);
    const end = flow.next(.{ .wrote = .{ .ok = "/docs/game.sud" } });
    try testing.expectEqualStrings(std.fmt.comptimePrint(file_policy.SAVED_TO_FMT, .{"/docs/game.sud"}), end.show_status);
    try testing.expectEqualStrings("/docs/game.sud", session.workingFile().?);
    try testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
}

test "a manual save while autosave is on writes nothing and says why" {
    var session = FileSession{};
    var flow = SaveFlow.forCommand(&session, .save, "game.sud", true);
    try testing.expectEqualStrings(file_policy.SAVE_WHILE_AUTO_SAVE_MSG, flow.next(.start).show_status);
    try testing.expect(session.workingFile() == null);
}

test "save as while autosave is on still writes" {
    var session = FileSession{};
    var flow = SaveFlow.forCommand(&session, .save_as, "game.sud", true);
    try expectCheck(flow.next(.start), "game.sud");
}

test "a save with no path writes the working file, else asks for the default target" {
    var session = FileSession{};
    var fresh = SaveFlow.forCommand(&session, .save, null, false);
    try testing.expect(fresh.next(.start) == .resolve_default_target);
    try expectCheck(fresh.next(.{ .default_target = "sudoku.sud" }), "sudoku.sud");

    session.setWorkingFile("game.sud");
    var continued = SaveFlow.forCommand(&session, .save_as, null, false);
    try expectCheck(continued.next(.start), "game.sud");
}

test "a refused save does not ask for a target" {
    var session = FileSession{};
    var flow = SaveFlow.forCommand(&session, .save, null, true);
    try testing.expectEqualStrings(file_policy.SAVE_WHILE_AUTO_SAVE_MSG, flow.next(.start).show_status);
}

const taken_ask_text = "The file sudoku.sud in Documents was saved by an earlier install. Pick it to keep autosaving there, or choose a new name.";

fn takenAsk(flow: *SaveFlow) !void {
    _ = flow.next(.start);
    _ = flow.next(.{ .target_checked = false });
    const ask = flow.next(.{ .wrote = .{ .taken = .{ .name = "sudoku.sud", .dir = "Documents" } } }).ask;
    try testing.expectEqualStrings(file_policy.TAKEN_TITLE, ask.title);
    try testing.expectEqualStrings(taken_ask_text, ask.text);
    try testing.expectEqualStrings(file_policy.TAKEN_PICK_LABEL, ask.ok_label);
    try testing.expectEqualStrings(file_policy.TAKEN_NEW_NAME_LABEL, ask.cancel_label);
}

test "a file taken by an earlier install asks, and Pick it writes the picked file" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .auto_save, "sudoku.sud");
    try takenAsk(&flow);
    try testing.expect(flow.next(.{ .answered = true }) == .pick_existing);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "sudoku.sud" } }) == .done);
    try testing.expectEqualStrings("sudoku.sud", session.workingFile().?);
    try testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
}

test "New name suggests the taken file's name, and the new file becomes the working file" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .auto_save, "sudoku.sud");
    try takenAsk(&flow);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .answered = false }).pick_new);
    try testing.expect(flow.next(.{ .wrote = .{ .ok = "mine.sud" } }) == .done);
    try testing.expectEqualStrings("mine.sud", session.workingFile().?);
}

test "closing the picker asks again, since there is nowhere else to autosave" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .auto_save, "sudoku.sud");
    try takenAsk(&flow);
    _ = flow.next(.{ .answered = true });
    try testing.expectEqualStrings(taken_ask_text, flow.next(.{ .wrote = .cancelled }).ask.text);
    try testing.expectEqualStrings("sudoku.sud", flow.next(.{ .answered = false }).pick_new);
    try testing.expectEqualStrings(SAVE_FAILED_MSG, flow.next(.{ .wrote = .{ .failed = "disk full" } }).show_error);
    try testing.expect(session.workingFile() == null);
}

test "save onto an existing file while detached asks before writing" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save, "/docs/game.sud");
    _ = flow.next(.start);
    const ask = flow.next(.{ .target_checked = true }).ask;
    try testing.expectEqualStrings(file_policy.REPLACE_CONFIRM_TITLE, ask.title);
    try testing.expectEqualStrings(std.fmt.comptimePrint(file_policy.REPLACE_CONFIRM_FMT, .{"game.sud"}), ask.text);
    try testing.expectEqualStrings(file_policy.REPLACE_CONFIRM_OK_LABEL, ask.ok_label);
    try testing.expectEqualStrings(file_policy.REPLACE_CONFIRM_CANCEL_LABEL, ask.cancel_label);
    try testing.expectEqualStrings("/docs/game.sud", flow.next(.{ .answered = true }).write.name);
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
    try testing.expectEqualStrings("game.sud", flow.next(.{ .target_checked = true }).write.name);
}

test "write failure shows the error and leaves the session alone" {
    var session = FileSession{};
    var flow = SaveFlow.init(&session, .save, "game.sud");
    _ = flow.next(.start);
    _ = flow.next(.{ .target_checked = false });
    try testing.expectEqualStrings(SAVE_FAILED_MSG, flow.next(.{ .wrote = .{ .failed = "disk full" } }).show_error);
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
    try testing.expectEqualStrings(std.fmt.comptimePrint(file_policy.SAVED_TO_FMT, .{"game (1).sud"}), flow.next(.{ .wrote = .{ .ok = "game (1).sud" } }).show_status);
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
