const std = @import("std");
const game_engine = @import("game_engine.zig");
const cell = @import("../board/cell.zig");

/// Execute an undo command on the game engine.
pub fn execute(engine: *game_engine.GameEngine) anyerror!game_engine.Event {
    if (engine.history.pointer == 0) {
        return game_engine.Event{ .error_msg = "nothing to undo" };
    }
    engine.history.pointer -= 1;
    const entry = engine.history.entries.items[engine.history.pointer];
    engine.board.setCell(entry.row, entry.col, entry.old_value) catch |err| {
        var buf: [80]u8 = undefined;
        return game_engine.Event{ .error_msg = std.fmt.bufPrint(&buf, "undo fail: {s}", .{@errorName(err)}) catch "undo failed" };
    };
    engine.board.refreshConflictsForCell(entry.row, entry.col);
    return game_engine.Event{ .ok = .{ .board_view = engine.board.asView(), .msg = null, .is_quit = false } };
}

// ---------------------------------------------------------------------------
// Tests — verify undo handler seam
// ---------------------------------------------------------------------------

test "command.undo.execute fails when no history" {
    const puzzle_gen = @import("../puzzle_gen.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const event = try execute(&engine);
    switch (event) {
        .error_msg => |msg| try std.testing.expectEqualStrings(msg, "nothing to undo"),
        .ok => return error.TestFailed,
    }
}

test "command.undo.execute reverses a fill" {
    const puzzle_gen = @import("../puzzle_gen.zig");
    const command = @import("../command.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    // Fill A3 with seven
    _ = try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.seven, v.get(0, 2));
    }

    // Undo the fill
    const event = try execute(&engine);
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.zero, event.ok.board_view.get(0, 2));
}
