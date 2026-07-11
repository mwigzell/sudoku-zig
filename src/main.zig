const board = @import("board.zig");

pub fn main() void {
    const empty = board.Board.init();
    _ = empty;
}
