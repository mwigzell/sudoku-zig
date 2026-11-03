// ExportFlow: hand the puzzle to the platform, either as a file (Export) or on
// the clipboard (Copy), and report the outcome.
const std = @import("std");
const step_mod = @import("step.zig");
const file_session_mod = @import("file_session.zig");
const logger = @import("../logger.zig");

const log = logger.Logger(.flow);

const Step = step_mod.Step;
const Input = step_mod.Input;

/// Status after Export; `{s}` is the written file.
pub const EXPORTED_TO_FMT = "The puzzle was exported to {s}.";
/// Status after Copy.
pub const COPIED_MSG: []const u8 = "The puzzle line was copied.";
/// Export target when the player names none.
pub const DEFAULT_EXPORT_FILE: []const u8 = "puzzle.txt";
/// Shown when the platform could not write the puzzle file; its reason goes to the log.
pub const EXPORT_FAILED_MSG = "The puzzle could not be exported.";
/// Shown when the platform could not copy the puzzle; its reason goes to the log.
pub const COPY_FAILED_MSG = "The puzzle could not be copied.";

pub const ExportFlow = struct {
    target: Target,
    name_buf: [file_session_mod.MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    text_buf: [file_session_mod.MAX_NAME_LEN + 32]u8 = undefined,
    phase: Phase = .start,

    const Target = enum { file, clipboard };
    const Phase = enum { start, exporting, finished };

    /// Export the puzzle to `path`, else to the default file.
    pub fn toFile(path: ?[]const u8) ExportFlow {
        var flow = ExportFlow{ .target = .file };
        const name = path orelse DEFAULT_EXPORT_FILE;
        const len = @min(name.len, flow.name_buf.len);
        std.mem.copyForwards(u8, flow.name_buf[0..len], name[0..len]);
        flow.name_len = len;
        return flow;
    }

    /// Copy the puzzle to the clipboard.
    pub fn toClipboard() ExportFlow {
        return .{ .target = .clipboard };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *ExportFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.fail(step_mod.UNEXPECTED_INPUT_MSG);
                self.phase = .exporting;
                return switch (self.target) {
                    .file => .{ .export_puzzle = self.name_buf[0..self.name_len] },
                    .clipboard => .copy_puzzle,
                };
            },
            .exporting => switch (self.target) {
                .file => switch (input) {
                    .wrote => |wrote| return switch (wrote) {
                        .ok => |written| self.exported(written),
                        .cancelled => self.finish(.done),
                        .failed => |reason| self.failedWith(EXPORT_FAILED_MSG, reason),
                        .exists, .taken => self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                    },
                    else => return self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                },
                .clipboard => switch (input) {
                    .copied => |copied| return switch (copied) {
                        .ok => self.finish(.{ .show_status = COPIED_MSG }),
                        .failed => |reason| self.failedWith(COPY_FAILED_MSG, reason),
                    },
                    else => return self.fail(step_mod.UNEXPECTED_INPUT_MSG),
                },
            },
            .finished => return .done,
        }
    }

    fn exported(self: *ExportFlow, written: []const u8) Step {
        const text = std.fmt.bufPrint(&self.text_buf, EXPORTED_TO_FMT, .{written}) catch return self.finish(.{ .show_status = written });
        return self.finish(.{ .show_status = text });
    }

    fn failedWith(self: *ExportFlow, msg: []const u8, reason: []const u8) Step {
        log.err("{s} failed: {s}", .{ @tagName(self.target), reason });
        return self.fail(msg);
    }

    fn fail(self: *ExportFlow, msg: []const u8) Step {
        return self.finish(.{ .show_error = msg });
    }

    fn finish(self: *ExportFlow, terminal: Step) Step {
        self.phase = .finished;
        return terminal;
    }
};

const testing = std.testing;

test "export writes the named file and reports where" {
    var flow = ExportFlow.toFile("puzzle.txt");
    try testing.expectEqualStrings("puzzle.txt", flow.next(.start).export_puzzle);
    try testing.expectEqualStrings(std.fmt.comptimePrint(EXPORTED_TO_FMT, .{"/docs/puzzle.txt"}), flow.next(.{ .wrote = .{ .ok = "/docs/puzzle.txt" } }).show_status);
    try testing.expect(flow.next(.start) == .done);
}

test "export with no file writes the default file" {
    var flow = ExportFlow.toFile(null);
    try testing.expectEqualStrings(DEFAULT_EXPORT_FILE, flow.next(.start).export_puzzle);
}

test "a closed export picker ends quietly; a failed write shows the error" {
    var cancelled = ExportFlow.toFile("puzzle.txt");
    _ = cancelled.next(.start);
    try testing.expect(cancelled.next(.{ .wrote = .cancelled }) == .done);
    var failed = ExportFlow.toFile("puzzle.txt");
    _ = failed.next(.start);
    try testing.expectEqualStrings(EXPORT_FAILED_MSG, failed.next(.{ .wrote = .{ .failed = "AccessDenied" } }).show_error);
}

test "copy hands over the puzzle and reports it, or shows why it could not" {
    var flow = ExportFlow.toClipboard();
    try testing.expect(flow.next(.start) == .copy_puzzle);
    try testing.expectEqualStrings(COPIED_MSG, flow.next(.{ .copied = .ok }).show_status);
    var denied = ExportFlow.toClipboard();
    _ = denied.next(.start);
    try testing.expectEqualStrings(COPY_FAILED_MSG, denied.next(.{ .copied = .{ .failed = "copy: clipboard write denied" } }).show_error);
}

test "a wrong answer ends the export with an error" {
    var flow = ExportFlow.toClipboard();
    _ = flow.next(.start);
    try testing.expectEqualStrings(step_mod.UNEXPECTED_INPUT_MSG, flow.next(.ack).show_error);
}
