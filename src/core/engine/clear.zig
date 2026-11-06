const game_engine = @import("game_engine.zig");
const command = @import("../command.zig");
const fill_command = @import("fill.zig");
const board = @import("../board/board.zig");

/// Clear applies to a player-filled cell or an empty cell with marks: a given is fixed
/// and an empty cell without marks has nothing to clear.
pub fn canClear(view: board.Board.BoardView, row: u4, col: u4) bool {
    return !view.isGiven(row, col) and (view.get(row, col) != .zero or view.marks(row, col) != 0);
}

/// Execute a clear command on the game engine.
pub fn execute(engine: *game_engine.GameEngine, clear_data: command.ClearData) game_engine.Event {
    return engine.tryFill(clear_data.row, clear_data.col, .zero);
}

// ---------------------------------------------------------------------------
// Tests — verify clear handler seam
// ---------------------------------------------------------------------------

test "command.clear.execute clears a non-given cell" {
    const std = @import("std");
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const cell = @import("../board/cell.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    // Fill it first
    _ = fill_command.execute(&engine, command.FillData{
        .row = 0,
        .col = 2,
        .digit = cell.CellValue.five,
    });
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.five, v.get(0, 2));
    }

    // Now clear it
    const event = execute(&engine, command.ClearData{ .row = 0, .col = 2 });
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.zero, event.ok.board_view.get(0, 2));
}

test "canClear holds only for a player-filled cell" {
    const std = @import("std");
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const cell = @import("../board/cell.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    try std.testing.expect(!canClear(engine.eventBoard(), 0, 0));
    try std.testing.expect(!canClear(engine.eventBoard(), 0, 2));
    _ = fill_command.execute(&engine, command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.five });
    try std.testing.expect(canClear(engine.eventBoard(), 0, 2));
}

test "command.clear.execute fails on a given cell" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const event = execute(&engine, command.ClearData{ .row = 0, .col = 0 });
    switch (event) {
        .error_msg => {}, // expected
        .ok => return error.TestFailed,
    }
}

test "Clear on an empty cell with marks removes them all as one Undo step" {
    const std = @import("std");
    const puzzle_gen = @import("../puzzle_gen/mod.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .pencil = .{ .row = 0, .col = 2, .digit = .one } });
    _ = engine.exec(.{ .pencil = .{ .row = 0, .col = 2, .digit = .six } });
    const marked = engine.state.board.marksAt(0, 2);
    try std.testing.expect(canClear(engine.eventBoard(), 0, 2));

    const ev = execute(&engine, .{ .row = 0, .col = 2 });
    try std.testing.expect(ev == .ok);
    try std.testing.expectEqual(@as(board.MarkSet, 0), ev.ok.board_view.marks(0, 2));
    try std.testing.expect(!canClear(engine.eventBoard(), 0, 2));

    _ = engine.exec(.{ .undo = {} });
    try std.testing.expectEqual(marked, engine.state.board.marksAt(0, 2));
}
