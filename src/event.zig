const board = @import("board.zig");

/// Event union type — public output contract of GameEngine.exec().
pub const Event = union(enum) {
    ok: struct {
        board_view: board.Board.BoardView,
        msg: ?[]const u8,
    },
    error_msg: []const u8,
};
