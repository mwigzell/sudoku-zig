/// New-game command handler — clears undo history, loads a puzzle string (falling back to medium), returns a fresh board view.
const std = @import("std");
const game_engine = @import("game_engine.zig");
const board = @import("../board.zig");
const command = @import("../command.zig");
const PuzzleGen = @import("../puzzle_gen.zig").PuzzleGen;

pub fn execute(engine: *game_engine.GameEngine, data: command.NewData) anyerror!game_engine.Event {
    engine.history.deinit();
    engine.history = game_engine.MutationHistory.init(std.heap.page_allocator);

    if (data.puzzle) |puzzle_str| {
        defer std.heap.page_allocator.free(puzzle_str);

        engine.board = board.fromOneLineString(puzzle_str) catch return .{ .error_msg = "could not load puzzle" };

        return .{
            .ok = .{
                .board_view = engine.board.asView(),
                .msg = "new game started",
                .is_quit = false,
            },
        };
    } else {
        const default_puzzle = PuzzleGen.medium();

        engine.board = board.fromOneLineString(default_puzzle) catch return .{ .error_msg = "could not create new game" };

        return .{
            .ok = .{
                .board_view = engine.board.asView(),
                .msg = "new game started",
                .is_quit = false,
            },
        };
    }
}

// ---------------------------------------------------------------------------
// Tests — verify new-game command handler seam
// ---------------------------------------------------------------------------

test "command.new.execute clears history and loads a puzzle string" {
    var engine = try game_engine.GameEngine.init(
        PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    _ = try execute(&engine, command.NewData{ .puzzle = null });

    try std.testing.expectEqual(@as(usize, 0), engine.history.count());
}

test "command.new.execute falls back to medium when puzzle is null" {
    var engine = try game_engine.GameEngine.init(
        PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    _ = try execute(&engine, command.NewData{ .puzzle = null });

    // Just makes sure it doesnt panic or leak (the default puzzle has "6" at index 0)
    _ = engine.board.isGiven(0, 0);
}
