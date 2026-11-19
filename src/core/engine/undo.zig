const std = @import("std");
const game_engine = @import("game_engine.zig");
const cell = @import("../board/cell.zig");
const board = @import("../board/board.zig");
const pencil_command = @import("pencil.zig");
const fill_command = @import("fill.zig");
const bookmark_command = @import("bookmark.zig");

/// Execute an undo command on the game engine.
pub fn execute(engine: *game_engine.GameEngine) game_engine.Event {
    if (engine.state.history.pointer == 0) {
        return game_engine.Event{ .error_msg = game_engine.NOTHING_TO_UNDO_MSG };
    }
    engine.state.history.pointer -= 1;
    const notice = bookmarkNoticeAfterUndo(engine);
    const entry = engine.state.history.entries.items[engine.state.history.pointer];
    switch (entry) {
        .cell => |c| {
            engine.state.board.setCell(c.row, c.col, c.old_value) catch |err| {
                return engine.eventFromSetCellError(c.row, c.col, err);
            };
            fill_command.restoreMarks(&engine.state.board, c);
            appendBookmarkNotice(engine, notice);
            return engine.finishOkAfterCellEdit(c.row, c.col);
        },
        .solve_batch => |snap| {
            engine.state.board = board.fromFlat(snap.flat, .{ .given_bits = snap.given_bits }) catch {
                return engine.errorEvent(game_engine.UNDO_FAILED_MSG);
            };
            engine.state.board.mark_bits = snap.mark_bits;
            engine.state.board.validate();
            engine.beginEventMsg();
            appendBookmarkNotice(engine, notice);
            return engine.finishOkEvent(engine.state.board.asView(), false, null, true);
        },
        .mark => |m| {
            appendBookmarkNotice(engine, notice);
            return pencil_command.applyBackward(engine, m);
        },
    }
}

/// What this undo owes the player about the bookmark it just moved away from.
const BookmarkNotice = union(enum) {
    none,
    /// Landed exactly on the bookmark; another undo exists, so it can still be lost.
    landed: u16,
    /// Crossed the bookmark; it is now forgotten.
    cleared: u16,
};

/// The pointer is the only history value that goes down, so this is the one place a bookmark
/// can end up ahead of it. Crossing it forgets it; landing on it keeps it, and is worth a
/// warning only when another undo exists to lose it.
fn bookmarkNoticeAfterUndo(engine: *game_engine.GameEngine) BookmarkNotice {
    const bookmark = engine.state.bookmark orelse return .none;
    const pointer = engine.state.history.pointer;
    if (bookmark > pointer) {
        engine.state.bookmark = null;
        return .{ .cleared = bookmark };
    }
    if (bookmark == pointer and pointer > 0) return .{ .landed = bookmark };
    return .none;
}

/// Append the notice to the command's status text; every front end shows `ok.msg` unchanged.
fn appendBookmarkNotice(engine: *game_engine.GameEngine, notice: BookmarkNotice) void {
    switch (notice) {
        .none => {},
        .landed => |move| engine.appendEventMsgFmt(bookmark_command.AT_BOOKMARK_FMT, .{move}),
        .cleared => |move| engine.appendEventMsgFmt(bookmark_command.BOOKMARK_CLEARED_FMT, .{move}),
    }
}

// ---------------------------------------------------------------------------
// Tests — verify undo handler seam
// ---------------------------------------------------------------------------

test "command.undo.execute fails when no history" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const event = execute(&engine);
    switch (event) {
        .error_msg => |msg| try std.testing.expectEqualStrings(msg, game_engine.NOTHING_TO_UNDO_MSG),
        .ok => return error.TestFailed,
    }
}

test "command.undo.execute reverses a fill" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
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
    const puzzle_gen = @import("../puzzle_gen/mod.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const before_flat = board.toFlat(engine.state.board);
    const before_given = engine.state.board.given_bits;
    try engine.state.board.setCell(0, 0, .four);
    try engine.state.history.pushSolve(.{ .given_bits = before_given, .flat = before_flat });

    const event = execute(&engine);
    if (event != .ok) return error.TestFailed;
    try std.testing.expectEqual(before_flat, board.toFlat(engine.state.board));
    try std.testing.expectEqual(before_given, engine.state.board.given_bits);
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.pointer);
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.entries.items.len);
}

test "command.undo.execute clears stale win status when solve-batch undo unsolves board" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const command = @import("../command.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    _ = engine.exec(command.Command{ .solve_for_me = {} });
    try std.testing.expect(engine.durableStatus() != null);
    try std.testing.expect(std.mem.indexOf(u8, engine.durableStatus().?, "You win!") != null);

    const event = execute(&engine);
    try std.testing.expect(event == .ok);
    try std.testing.expect(event.ok.msg == null);
    try std.testing.expect(engine.durableStatus() == null);
    try std.testing.expect(!engine.state.board.isSolved());
}

test "an undo that leaves the pointer below the bookmark discards it" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const config = @import("../config.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });
    _ = engine.exec(.{ .bookmark = {} });
    _ = engine.exec(.{ .fill = .{ .row = 1, .col = 1, .digit = .nine } });
    try std.testing.expect(engine.getLegend(false).rewind);

    // The pointer lands on the bookmark: it stays, and Rewind greys.
    _ = execute(&engine);
    try std.testing.expectEqual(@as(?u16, 2), engine.state.bookmark);
    try std.testing.expect(!engine.getLegend(false).rewind);

    // One step further is below it, so the bookmark is forgotten.
    _ = execute(&engine);
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);
    try std.testing.expectEqual(@as(?u16, null), engine.state.bookmark);
    try std.testing.expect(!engine.getLegend(false).rewind);
}

test "an undo that lands on the bookmark warns the next one drops it" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const config = @import("../config.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = engine.exec(.{ .bookmark = {} }); // pins move 1
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });

    const event = engine.exec(.{ .undo = {} }); // pointer 2 -> 1, resting on the bookmark
    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint(bookmark_command.AT_BOOKMARK_FMT, .{1}),
        event.ok.msg.?,
    );
    try std.testing.expectEqual(@as(?u16, 1), engine.state.bookmark);
}

test "the undo past the bookmark says it was cleared" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const config = @import("../config.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = engine.exec(.{ .bookmark = {} }); // pins move 1
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });
    _ = engine.exec(.{ .undo = {} }); // lands on the bookmark

    const event = engine.exec(.{ .undo = {} }); // pointer 1 -> 0, crossing it
    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint(bookmark_command.BOOKMARK_CLEARED_FMT, .{1}),
        event.ok.msg.?,
    );
    try std.testing.expectEqual(@as(?u16, null), engine.state.bookmark);
}

test "a bookmark at move zero is kept, with no next-undo claim" {
    const puzzle_gen = @import("../puzzle_gen/mod.zig");
    const config = @import("../config.zig");

    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .bookmark = {} }); // pins move 0: nothing to rewind to
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });

    const event = engine.exec(.{ .undo = {} }); // pointer 1 -> 0: landing, not crossing
    try std.testing.expectEqual(@as(?u16, 0), engine.state.bookmark);
    try std.testing.expect(event.ok.msg == null);
}

test "the two bookmark notices read as sentences" {
    const sentence = @import("../../test/sentence.zig");
    var buf: [160]u8 = undefined;
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, bookmark_command.AT_BOOKMARK_FMT, .{12}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, bookmark_command.BOOKMARK_CLEARED_FMT, .{12}));
}
