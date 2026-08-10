const std = @import("std");
const game_engine = @import("game_engine.zig");
const command = @import("../command.zig");
const cell = @import("../cell.zig");

/// Execute a fill command on the game engine.
pub fn execute(engine: *game_engine.GameEngine, fill_data: command.FillData) anyerror!game_engine.Event {
    return engine.tryFill(fill_data.row, fill_data.col, fill_data.digit);
}

// ---------------------------------------------------------------------------
// Tests — verify fill handler seam
// ---------------------------------------------------------------------------

test "command.fill.execute fills a non-given cell" {
    var engine = try game_engine.GameEngine.init(
        @import("../puzzle_gen.zig").PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    const event = try execute(&engine, command.FillData{
        .row = 0,
        .col = 2,
        .digit = cell.CellValue.seven,
    });
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.seven, event.ok.board_view.get(0, 2));
}

test "command.fill.execute fails on a given cell" {
    var engine = try game_engine.GameEngine.init(
        @import("../puzzle_gen.zig").PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    const event = try execute(&engine, command.FillData{

        .row = 0,
        .col = 0,
        .digit = cell.CellValue.nine,
    });
    switch (event) {
        .error_msg => {}, // expected
        .ok => return error.TestFailed,
    }
}

test "command.fill.execute records mutation in history" {
    var engine = try game_engine.GameEngine.init(
        @import("../puzzle_gen.zig").PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    _ = try execute(&engine, command.FillData{

        .row = 0,
        .col = 2,
        .digit = cell.CellValue.five,
    });

    try std.testing.expectEqual(@as(usize, 1), engine.history.count());
}
