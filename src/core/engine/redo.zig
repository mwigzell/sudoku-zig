const std = @import("std");
const game_engine = @import("game_engine.zig");
const cell = @import("../board/cell.zig");
const board = @import("../board/board.zig");
const solver = @import("../solver.zig");
const pencil_command = @import("pencil.zig");
const fill_command = @import("fill.zig");

/// Execute a redo command on the game engine.
pub fn execute(engine: *game_engine.GameEngine) game_engine.Event {
    if (engine.state.history.pointer >= engine.state.history.entries.items.len) {
        return game_engine.Event{ .error_msg = game_engine.NOTHING_TO_REDO_MSG };
    }
    // Redo does not go through `exec`, so it starts its own line rather than appending to the last command's.
    engine.beginEventMsg();
    const entry = engine.state.history.entries.items[engine.state.history.pointer];
    switch (entry) {
        // Every redo names what it replayed, from the history entry behind it.
        .cell => |c| {
            engine.state.board.setCell(c.row, c.col, c.new_value) catch |err| {
                return engine.eventFromSetCellError(c.row, c.col, err);
            };
            // Redo replays the edit on the board Undo restored, so it clears the same marks it recorded.
            _ = fill_command.clearMarks(&engine.state.board, c.row, c.col, c.new_value);
            engine.state.history.pointer += 1;
            appendRedoneMsgFmt(engine, game_engine.REDID_MOVE_FMT, c.row, c.col);
            return engine.finishOkAfterCellEdit(c.row, c.col);
        },
        .solve_batch => |snap| {
            engine.state.board = board.fromFlat(snap.flat, .{ .given_bits = snap.given_bits }) catch {
                return engine.errorEvent(game_engine.REDO_FAILED_MSG);
            };
            engine.state.board.mark_bits = snap.mark_bits;
            const solved = solver.solve(engine.state.board) catch {
                return engine.errorEvent(game_engine.REDO_FAILED_MSG);
            };
            switch (solved) {
                .none => return engine.errorEvent(game_engine.REDO_FAILED_MSG),
                .solution => |grid| if (engine.placeSolution(grid)) |failed| return failed,
            }
            engine.state.history.pointer += 1;
            engine.state.board.validate();
            engine.appendEventMsg(game_engine.REDID_SOLVE_MSG);
            return engine.finishOkEvent(engine.state.board.asView(), false, null);
        },
        .mark => |m| {
            engine.state.history.pointer += 1;
            appendRedoneMsgFmt(engine, game_engine.REDID_MARK_FMT, m.row, m.col);
            // The redo names the mark; the replay itself stays silent, so it is not said twice.
            return pencil_command.applyForward(engine, m);
        },
    }
}

/// Append `fmt` naming the cell a command touched; `{s}` is its label (e.g. C3).
fn appendRedoneMsgFmt(engine: *game_engine.GameEngine, comptime fmt: []const u8, row: u4, col: u4) void {
    var label_buf: [2]u8 = undefined;
    engine.appendEventMsgFmt(fmt, .{board.formatCellLabel(&label_buf, row, col)});
}

// ---------------------------------------------------------------------------
// Tests — verify redo handler seam
// ---------------------------------------------------------------------------

test "a redo of a mark names only the redo, not what the mark did" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const config = @import("../config.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    // B1 is empty in the easy puzzle; mark it, undo the mark, then redo it.
    _ = engine.exec(.{ .pencil = .{ .row = 0, .col = 1, .digit = .eight } });
    _ = engine.exec(.{ .undo = {} });
    const redone = engine.exec(.{ .redo = {} });
    var label_buf: [2]u8 = undefined;
    var text_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&text_buf, game_engine.REDID_MARK_FMT, .{board.formatCellLabel(&label_buf, 0, 1)}),
        redone.ok.msg.?,
    );
}

test "a redo after an undo starts its own line instead of appending to it" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const config = @import("../config.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    // The undo leaves its sentence on the line; the redo is a separate command and must not join it.
    _ = engine.exec(.{ .pencil = .{ .row = 0, .col = 1, .digit = .eight } });
    const undone = engine.exec(.{ .undo = {} });
    try std.testing.expect(std.mem.indexOf(u8, undone.ok.msg.?, game_engine.UNDID_MARK_FMT[0..7]) != null);
    const redone = engine.exec(.{ .redo = {} });
    var label_buf: [2]u8 = undefined;
    var text_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&text_buf, game_engine.REDID_MARK_FMT, .{board.formatCellLabel(&label_buf, 0, 1)}),
        redone.ok.msg.?,
    );
}

test "command.redo.execute fails when nothing to redo" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const command = @import("../command.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    // Fill some cells but never undo — no future to redo
    _ = engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });

    const event = execute(&engine);
    switch (event) {
        .error_msg => |msg| try std.testing.expectEqualStrings(msg, game_engine.NOTHING_TO_REDO_MSG),
        .ok => return error.TestFailed,
    }
}

test "command.redo.execute re-applies an undone fill" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
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
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
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
    // The undo was its own command, so the redo starts a fresh line instead of appending to it.
    const want = game_engine.REDID_SOLVE_MSG;
    try std.testing.expectEqualStrings(want, event.ok.msg.?);
    try std.testing.expectEqualStrings(want, engine.durableStatus().?);
}

test "Solve clears every mark as player fills would; Undo restores them and Redo clears them again" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    var marked: usize = 0;
    for (0..board.CELL_COUNT) |i| {
        const row: u4 = @intCast(i / board.DIMENSION_SIZE);
        const col: u4 = @intCast(i % board.DIMENSION_SIZE);
        if (engine.state.board.getCellValue(row, col) != .zero) continue;
        _ = engine.exec(.{ .pencil = .{ .row = row, .col = col, .digit = .four } });
        marked += 1;
        if (marked == 3) break;
    }
    const before = engine.state.board.mark_bits;
    const no_marks: [board.DIMENSION_SIZE]board.CellMask = @splat(0);

    try std.testing.expect(engine.exec(.{ .solve_for_me = {} }) == .ok);
    try std.testing.expectEqual(no_marks, engine.state.board.mark_bits);
    _ = engine.exec(.{ .undo = {} });
    try std.testing.expectEqual(before, engine.state.board.mark_bits);
    _ = engine.exec(.{ .redo = {} });
    try std.testing.expectEqual(no_marks, engine.state.board.mark_bits);
}
