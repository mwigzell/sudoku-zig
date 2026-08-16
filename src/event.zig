const std = @import("std");
const board = @import("board.zig");

/// Event union type — public output contract of GameEngine.exec().
pub const Event = union(enum) {
    ok: struct {
        board_view: board.Board.BoardView,
        msg: ?[]const u8,
        is_quit: bool,
    },
    error_msg: []const u8,
};
const puzzle_gen = @import("puzzle_gen.zig");

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
