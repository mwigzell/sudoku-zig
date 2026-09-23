const std = @import("std");
const game_engine = @import("game_engine.zig");
const cell = @import("../board/cell.zig");
const board = @import("../board/board.zig");
const solver = @import("../solver.zig");

/// Execute a redo command on the game engine.
pub fn execute(engine: *game_engine.GameEngine) game_engine.Event {
    if (engine.state.history.pointer >= engine.state.history.entries.items.len) {
        return game_engine.Event{ .error_msg = "nothing to redo" };
    }
    const entry = engine.state.history.entries.items[engine.state.history.pointer];
    switch (entry) {
        .cell => |c| {
            const was_solved = engine.state.board.isSolved();
            engine.state.board.setCell(c.row, c.col, c.new_value) catch |err| {
                return engine.eventFromSetCellError(c.row, c.col, err);
            };
            engine.state.history.pointer += 1;
            return engine.finishOkAfterCellEdit(c.row, c.col, was_solved);
        },
        .solve_batch => |snap| {
            engine.state.board = board.fromFlat(snap.flat, .{ .given_bits = snap.given_bits }) catch {
                return engine.errorEvent("could not restore board");
            };
            const solved = solver.solve(engine.state.board) catch {
                return engine.errorEvent("could not redo solve");
            };
            switch (solved) {
                .none => return engine.errorEvent("could not redo solve"),
                .solution => |grid| {
                    for (grid, 0..) |digit, i| {
                        const row: u4 = @intCast(i / 9);
                        const col: u4 = @intCast(i % 9);
                        if (engine.state.board.getCellValue(row, col) == cell.rawToCellValue(digit)) continue;
                        engine.state.board.setCell(row, col, cell.rawToCellValue(digit)) catch |err| {
                            return engine.eventFromSetCellError(row, col, err);
                        };
                    }
                },
            }
            engine.state.history.pointer += 1;
            engine.state.board.validate();
            return engine.finishOkEvent(engine.state.board.asView(), false, null);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests — verify redo handler seam
// ---------------------------------------------------------------------------

test "command.redo.execute fails when nothing to redo" {
    const puzzle_gen = @import("../puzzle_gen.zig");
    const command = @import("../command.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    // Fill some cells but never undo — no future to redo
    _ = engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });

    const event = execute(&engine);
    switch (event) {
        .error_msg => |msg| try std.testing.expectEqualStrings(msg, "nothing to redo"),
        .ok => return error.TestFailed,
    }
}

test "command.redo.execute re-applies an undone fill" {
    const puzzle_gen = @import("../puzzle_gen.zig");
    const command = @import("../command.zig");
    const undo_command = @import("undo.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    // Fill A3 with seven, then undo
    _ = engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });
    var event = undo_command.execute(&engine);
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.zero, event.ok.board_view.get(0, 2));

    // Redo — should re-apply seven
    event = execute(&engine);
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.seven, event.ok.board_view.get(0, 2));
}

test "command.redo.execute re-solves a solve batch to the captured grid" {
    const puzzle_gen = @import("../puzzle_gen.zig");
    const undo_command = @import("undo.zig");
    const solution = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const before_flat = board.toFlat(engine.state.board);
    const before_given = engine.state.board.given_bits;
    for (solution, 0..) |ch, i| {
        const digit = ch - '0';
        if (before_flat[i] == digit) continue;
        const row: u4 = @intCast(i / 9);
        const col: u4 = @intCast(i % 9);
        try engine.state.board.setCell(row, col, cell.rawToCellValue(digit));
    }
    try engine.state.history.pushSolve(.{ .given_bits = before_given, .flat = before_flat });

    var event = undo_command.execute(&engine);
    if (event != .ok) return error.TestFailed;

    event = execute(&engine);
    if (event != .ok) return error.TestFailed;
    var expected: [81]u8 = undefined;
    for (solution, 0..) |ch, i| expected[i] = ch - '0';
    try std.testing.expectEqual(expected, board.toFlat(engine.state.board));
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);
}
