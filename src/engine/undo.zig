const std = @import("std");
const game_engine = @import("game_engine.zig");
const cell = @import("../board/cell.zig");
const board = @import("../board/board.zig");

/// Execute an undo command on the game engine.
pub fn execute(engine: *game_engine.GameEngine) game_engine.Event {
    if (engine.state.history.pointer == 0) {
        return game_engine.Event{ .error_msg = "nothing to undo" };
    }
    engine.state.history.pointer -= 1;
    const entry = engine.state.history.entries.items[engine.state.history.pointer];
    switch (entry) {
        .cell => |c| {
            engine.state.board.setCell(c.row, c.col, c.old_value) catch |err| {
                return engine.eventFromSetCellError(c.row, c.col, err);
            };
            return engine.finishOkAfterCellEdit(c.row, c.col);
        },
        .solve_batch => |snap| {
            engine.state.board = board.fromFlat(snap.flat, .{ .given_bits = snap.given_bits }) catch {
                return engine.errorEvent("could not restore board");
            };
            engine.state.board.validate();
            return engine.finishOkEvent(engine.state.board.asView(), false, null);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests — verify undo handler seam
// ---------------------------------------------------------------------------

test "command.undo.execute fails when no history" {
    const puzzle_gen = @import("../puzzle_gen.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const event = execute(&engine);
    switch (event) {
        .error_msg => |msg| try std.testing.expectEqualStrings(msg, "nothing to undo"),
        .ok => return error.TestFailed,
    }
}

test "command.undo.execute reverses a fill" {
    const puzzle_gen = @import("../puzzle_gen.zig");
    const command = @import("../command.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    // Fill A3 with seven
    _ = engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.seven, v.get(0, 2));
    }

    // Undo the fill
    const event = execute(&engine);
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.zero, event.ok.board_view.get(0, 2));
}

test "command.undo.execute restores the before snapshot of one solve" {
    const puzzle_gen = @import("../puzzle_gen.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const before_flat = engine.state.board.toFlat();
    const before_given = engine.state.board.given_bits;
    try engine.state.board.setCell(0, 0, .four);
    try engine.state.history.pushSolve(.{ .given_bits = before_given, .flat = before_flat });

    const event = execute(&engine);
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(before_flat, engine.state.board.toFlat());
    try std.testing.expectEqual(before_given, engine.state.board.given_bits);
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.pointer);
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.entries.items.len);
}
