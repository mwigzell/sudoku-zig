const std = @import("std");
const game_engine = @import("game_engine.zig");
const command = @import("../command.zig");
const cell = @import("../board/cell.zig");
const config = @import("../config.zig");
const puzzle_gen = @import("../puzzle_gen/mod.zig");
const board = @import("../board/board.zig");
const mutation_history = @import("mutation_history.zig");

/// A digit can go in any cell but a given: givens are fixed.
pub fn canFill(view: board.Board.BoardView, row: u4, col: u4) bool {
    return !view.isGiven(row, col);
}

/// What a fill or clear does to marks: the cell loses its own, and a placed digit
/// leaves the marks of its row, column and box. Returns the cells it cleared, for Undo.
pub fn clearMarks(b: *board.Board, row: u4, col: u4, digit: cell.CellValue) board.CellMask {
    b.setMarks(row, col, 0);
    if (digit == .zero) return 0;
    return b.clearPeerMarks(row, col, digit);
}

/// Undo `clearMarks` for a recorded edit: the cell's marks and the cleared peers come back.
pub fn restoreMarks(b: *board.Board, m: mutation_history.CellMutation) void {
    b.setMarks(m.row, m.col, m.old_marks);
    if (m.new_value != .zero) b.restoreMarks(m.new_value, m.cleared_peers);
}

/// Execute a fill command on the game engine.
pub fn execute(engine: *game_engine.GameEngine, fill_data: command.FillData) game_engine.Event {
    return engine.tryFill(fill_data.row, fill_data.col, fill_data.digit);
}

// ---------------------------------------------------------------------------
// Tests — verify fill handler seam
// ---------------------------------------------------------------------------

test "command.fill.execute fills a non-given cell" {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const event = execute(&engine, command.FillData{
        .row = 0,
        .col = 2,
        .digit = cell.CellValue.seven,
    });
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(cell.CellValue.seven, event.ok.board_view.get(0, 2));
}

test "command.fill.execute fails on a given cell" {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const event = execute(&engine, command.FillData{
        .row = 0,
        .col = 0,
        .digit = cell.CellValue.nine,
    });
    switch (event) {
        .error_msg => {}, // expected
        .ok => return error.TestFailed,
    }
}

test "canFill holds for every cell but a given" {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    try std.testing.expect(!canFill(engine.eventBoard(), 0, 0));
    try std.testing.expect(canFill(engine.eventBoard(), 0, 2));
    _ = execute(&engine, command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.five });
    try std.testing.expect(canFill(engine.eventBoard(), 0, 2));
}

test "command.fill.execute records mutation in history" {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = execute(&engine, command.FillData{
        .row = 0,
        .col = 2,
        .digit = cell.CellValue.five,
    });

    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());
}

test "a fill replaces the cell's marks and clears its digit's marks from row, column and box; Undo and Redo follow" {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    // Default puzzle: C1 (0,2) is empty, with empty peers D1 (row), C5 (column) and B2 (box); E5 is not a peer.
    const marks = [_]command.PencilData{
        .{ .row = 0, .col = 2, .digit = .three },
        .{ .row = 0, .col = 2, .digit = .eight },
        .{ .row = 0, .col = 3, .digit = .eight },
        .{ .row = 0, .col = 3, .digit = .three },
        .{ .row = 4, .col = 2, .digit = .eight },
        .{ .row = 1, .col = 1, .digit = .eight },
        .{ .row = 4, .col = 4, .digit = .eight },
    };
    for (marks) |m| _ = engine.exec(.{ .pencil = m });
    const before = engine.state.board.mark_bits;
    const eight = board.markPlane(.eight);

    const ev = execute(&engine, .{ .row = 0, .col = 2, .digit = .eight });
    try std.testing.expect(ev == .ok);
    try std.testing.expectEqual(@as(board.MarkSet, 0), engine.state.board.marksAt(0, 2));
    try std.testing.expectEqual(board.cellBit(4, 4), engine.state.board.mark_bits[eight]);
    try std.testing.expectEqual(@as(board.MarkSet, 1) << @intCast(board.markPlane(.three)), engine.state.board.marksAt(0, 3));
    const after = engine.state.board.mark_bits;

    _ = engine.exec(.{ .undo = {} });
    try std.testing.expectEqual(cell.CellValue.zero, engine.state.board.getCellValue(0, 2));
    try std.testing.expectEqual(before, engine.state.board.mark_bits);
    _ = engine.exec(.{ .redo = {} });
    try std.testing.expectEqual(cell.CellValue.eight, engine.state.board.getCellValue(0, 2));
    try std.testing.expectEqual(after, engine.state.board.mark_bits);
}
