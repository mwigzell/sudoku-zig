const std = @import("std");
const board = @import("board/board.zig");

/// Scratch buffer for assembling optional `.ok.msg` text during one exec step.
/// Start empty; append from any number of sources; pass `optional()` into Event.
pub const EventMsg = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn reset(self: *EventMsg) void {
        self.len = 0;
    }

    pub fn append(self: *EventMsg, part: []const u8) void {
        if (part.len == 0) return;
        if (self.len > 0) {
            const sep = "; ";
            const sep_take = @min(sep.len, self.buf.len - self.len);
            if (sep_take == 0) return;
            @memcpy(self.buf[self.len..][0..sep_take], sep[0..sep_take]);
            self.len += sep_take;
        }
        const take = @min(part.len, self.buf.len - self.len);
        if (take == 0) return;
        @memcpy(self.buf[self.len..][0..take], part[0..take]);
        self.len += take;
    }

    pub fn appendFmt(self: *EventMsg, comptime fmt: []const u8, args: anytype) void {
        var stack: [128]u8 = undefined;
        const part = std.fmt.bufPrint(&stack, fmt, args) catch return;
        self.append(part);
    }

    pub fn optional(self: *const EventMsg) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }

    pub fn slice(self: *const EventMsg) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Last cell the user mutated; drives native region highlight when enabled.
pub const CellCoord = struct {
    row: u4,
    col: u4,
};

/// Event union type — public output contract of GameEngine.exec().
pub const Event = union(enum) {
    ok: struct {
        board_view: board.Board.BoardView,
        msg: ?[]const u8,
        is_quit: bool,
        cell: ?CellCoord = null,
    },
    error_msg: []const u8,
};
const puzzle_gen = @import("puzzle_gen.zig");

test "EventMsg append joins multiple parts" {
    var msg: EventMsg = .{};
    msg.append("saved to: foo");
    msg.append("conflict in row, column, or box");
    try std.testing.expectEqualStrings("saved to: foo; conflict in row, column, or box", msg.slice());
    try std.testing.expectEqualStrings("saved to: foo; conflict in row, column, or box", msg.optional().?);
}

test "EventMsg optional is null when empty" {
    const msg: EventMsg = .{};
    try std.testing.expect(msg.optional() == null);
}

test "Event.ok is_quit defaults false" {
    var board_inst = try board.fromOneLineString(puzzle_gen.PuzzleGen.default());
    const view = board_inst.asView();

    const e: Event = .{ .ok = .{
        .board_view = view,
        .msg = null,
        .is_quit = false,
    } };
    switch (e) {
        .ok => |data| try std.testing.expect(!data.is_quit),
        .error_msg => return error.TestFailed,
    }
}

test "Event.ok cell defaults null and can carry last mutated cell" {
    var board_inst = try board.fromOneLineString(puzzle_gen.PuzzleGen.default());
    const view = board_inst.asView();

    const bare: Event = .{ .ok = .{
        .board_view = view,
        .msg = null,
        .is_quit = false,
    } };
    switch (bare) {
        .ok => |data| try std.testing.expect(data.cell == null),
        .error_msg => return error.TestFailed,
    }

    const with_cell: Event = .{ .ok = .{
        .board_view = view,
        .msg = null,
        .is_quit = false,
        .cell = .{ .row = 4, .col = 4 },
    } };
    switch (with_cell) {
        .ok => |data| {
            try std.testing.expectEqual(@as(u4, 4), data.cell.?.row);
            try std.testing.expectEqual(@as(u4, 4), data.cell.?.col);
        },
        .error_msg => return error.TestFailed,
    }
}

test "Event.ok is_quit can be set true" {
    var board_inst = try board.fromOneLineString(puzzle_gen.PuzzleGen.default());
    const view = board_inst.asView();

    const e: Event = .{ .ok = .{
        .board_view = view,
        .msg = null,
        .is_quit = true,
    } };
    switch (e) {
        .ok => |data| try std.testing.expect(data.is_quit),
        .error_msg => return error.TestFailed,
    }
}
