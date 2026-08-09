const std = @import("std");
const game_engine = @import("game_engine.zig");

/// Execute quit — returns ok with is_quit = true.
pub fn execute(engine: *game_engine.GameEngine) game_engine.Event {
    return game_engine.Event{ .ok = .{
        .board_view = engine.board.asView(),
        .msg = null,
        .is_quit = true,
    } };
}

test "command.quit.execute returns ok with is_quit true" {
    var engine = try game_engine.GameEngine.init(
        @import("../puzzle_gen.zig").PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    const event = execute(&engine);
    switch (event) {
        .ok => |data| try std.testing.expect(data.is_quit),
        .error_msg => return error.TestFailed,
    }
}
