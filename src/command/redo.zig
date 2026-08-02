const std = @import("std");
const game_engine = @import("../game_engine.zig");
const cell = @import("../cell.zig");

/// Execute a redo command on the game engine.
pub fn execute(engine: *game_engine.GameEngine) anyerror!game_engine.Event {
    if (engine.history.pointer >= engine.history.entries.items.len) {
        return game_engine.Event{ .error_msg = "nothing to redo" };
    }
    const entry = engine.history.entries.items[engine.history.pointer];
    engine.board.setCell(entry.row, entry.col, entry.new_value) catch |err| {
        var buf: [80]u8 = undefined;
        return game_engine.Event{ .error_msg = std.fmt.bufPrint(&buf, "redo fail: {s}", .{@errorName(err)}) catch "redo failed" };
    };
    engine.board.refreshConflictsForCell(entry.row, entry.col);
    engine.history.pointer += 1;
    return game_engine.Event{ .ok = .{ .board_view = engine.board.asView(), .msg = null } };
}

// ---------------------------------------------------------------------------
// Tests — verify redo handler seam
// ---------------------------------------------------------------------------

test "command.redo.execute fails when nothing to redo" {
    const puzzle_gen = @import("../puzzle_gen.zig");
    const command = @import("parse.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    // Fill some cells but never undo — no future to redo
    _ = try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });

    const event = try execute(&engine);
    switch (event) {
        .error_msg => |msg| try std.testing.expectEqualStrings(msg, "nothing to redo"),
        .ok => return error.TestFailed,
    }
}

test "command.redo.execute re-applies an undone fill" {
    const puzzle_gen = @import("../puzzle_gen.zig");
    const command = @import("parse.zig");
    const undo_command = @import("undo.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    // Fill A3 with seven, then undo
    _ = try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });
    var event = try undo_command.execute(&engine);
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.zero, event.ok.board_view.get(0, 2));

    // Redo — should re-apply seven
    event = try execute(&engine);
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.seven, event.ok.board_view.get(0, 2));
}
