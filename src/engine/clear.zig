const game_engine = @import("game_engine.zig");
const command = @import("../command.zig");
const fill_command = @import("fill.zig");

/// Execute a clear command on the game engine.
pub fn execute(engine: *game_engine.GameEngine, clear_data: command.ClearData) anyerror!game_engine.Event {
    return engine.tryFill(clear_data.row, clear_data.col, .zero);
}

// ---------------------------------------------------------------------------
// Tests — verify clear handler seam
// ---------------------------------------------------------------------------

test "command.clear.execute clears a non-given cell" {
    const std = @import("std");
    const puzzle_gen = @import("../puzzle_gen.zig");
    const cell = @import("../cell.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    // Fill it first
    _ = try fill_command.execute(&engine, command.FillData{
        .row = 0,
        .col = 2,
        .digit = cell.CellValue.five,
    });
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.five, v.get(0, 2));
    }

    // Now clear it
    const event = try execute(&engine, command.ClearData{ .row = 0, .col = 2 });
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.zero, event.ok.board_view.get(0, 2));
}

test "command.clear.execute fails on a given cell" {
    const std = @import("std");
    const puzzle_gen = @import("../puzzle_gen.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const event = try execute(&engine, command.ClearData{ .row = 0, .col = 0 });
    switch (event) {
        .error_msg => {}, // expected
        .ok => return error.TestFailed,
    }
}
