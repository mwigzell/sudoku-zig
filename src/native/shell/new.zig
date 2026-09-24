/// New-game command handler — starts a fresh board from the generated puzzle string (medium fallback) and clears the undo history.
const std = @import("std");
const game_engine = @import("../../engine/game_engine.zig");
const cell = @import("../../board/cell.zig");
const command = @import("../../command.zig");
const PuzzleGen = @import("../../puzzle_gen.zig").PuzzleGen;

pub fn execute(engine: *game_engine.GameEngine, data: command.NewData) game_engine.Event {
    const puzzle_str = if (data.puzzle) |p| p else PuzzleGen.medium()[0..81];
    const event = engine.newFromOneLinePuzzle(puzzle_str);
    if (data.puzzle) |p| std.heap.page_allocator.free(p);
    return event;
}

// ---------------------------------------------------------------------------
// Tests — new-game command handler seam
// ---------------------------------------------------------------------------

test "command.new.execute loads the chosen puzzle and clears history" {
    var engine = try game_engine.GameEngine.init(
        PuzzleGen.default(),
        @import("../../config.zig").Config.default(),
    );
    defer engine.deinit();

    const puzzle = std.heap.page_allocator.dupe(u8, PuzzleGen.easy()) catch return error.TestFailed;
    const event = execute(&engine, command.NewData{ .puzzle = puzzle });
    switch (event) {
        .ok => try std.testing.expectEqual(@as(usize, 0), engine.state.history.count()),
        .error_msg => return error.TestFailed,
    }

    // easy puzzle: "003..." → A1/A2 empty, A3 given with value 3
    try std.testing.expect(!engine.state.board.isGiven(0, 0));
    try std.testing.expect(engine.state.board.isGiven(0, 2));
    try std.testing.expectEqual(cell.CellValue.three, engine.state.board.getCellValue(0, 2));
}

test "command.new.execute falls back to medium when puzzle is null" {
    var engine = try game_engine.GameEngine.init(
        PuzzleGen.default(),
        @import("../../config.zig").Config.default(),
    );
    defer engine.deinit();

    const event = execute(&engine, command.NewData{ .puzzle = null });
    switch (event) {
        .ok => try std.testing.expectEqual(@as(usize, 0), engine.state.history.count()),
        .error_msg => return error.TestFailed,
    }
}

test "command.new.execute rejects invalid puzzle without mutating state" {
    var engine = try game_engine.GameEngine.init(
        PuzzleGen.default(),
        @import("../../config.zig").Config.default(),
    );
    defer engine.deinit();

    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 2, .digit = cell.CellValue.seven } });
    const before = @import("../../board/board.zig").toFlat(engine.state.board);

    const bad = std.heap.page_allocator.dupe(u8, "too short") catch return error.TestFailed;
    const event = execute(&engine, command.NewData{ .puzzle = bad });
    switch (event) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }
    try std.testing.expectEqual(before, @import("../../board/board.zig").toFlat(engine.state.board));
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());
}
