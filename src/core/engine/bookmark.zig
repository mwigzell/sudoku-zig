// The one pinned history position: Set Bookmark pins the current move, Rewind undoes back to it.
const std = @import("std");
const game_engine = @import("game_engine.zig");
const undo_command = @import("undo.zig");

/// Status text after Set Bookmark; `{d}` is the move number the bookmark sits at.
pub const BOOKMARK_SET_FMT = "Bookmark set at move {d}.";
/// Status text after a rewind; `{d}` is the move number of the bookmark.
pub const REWOUND_FMT = "Rewound to the bookmark at move {d}.";
/// Status text when an undo lands on the bookmark; `{d}` is the move it pins.
pub const AT_BOOKMARK_FMT = "At the bookmark (move {d}). The next undo drops it.";
/// Status text when an undo crosses the bookmark; `{d}` is the move it pinned before it went.
pub const BOOKMARK_CLEARED_FMT = "Bookmark at move {d} cleared: undone past it.";

/// Pin the current history position, replacing any earlier bookmark; reports the move.
pub fn set(engine: *game_engine.GameEngine) game_engine.Event {
    // The save file stores the pointer in a u16, so the bookmark carries the same range.
    const move: u16 = @intCast(engine.state.history.pointer);
    engine.state.bookmark = move;
    engine.beginEventMsg();
    engine.appendEventMsgFmt(BOOKMARK_SET_FMT, .{move});
    return engine.finishOkEvent(engine.state.board.asView(), false, null);
}

/// Whether Rewind can act in this game: a bookmark sits behind the current move.
pub fn canRewind(engine: *const game_engine.GameEngine) bool {
    const bookmark = engine.state.bookmark orelse return false;
    return bookmark < engine.state.history.pointer;
}

/// Undo back to the bookmark in one step. Redo still replays the undone moves one at a time.
/// Not offered means nothing changes and nothing is reported.
pub fn rewind(engine: *game_engine.GameEngine) game_engine.Event {
    if (!canRewind(engine)) return engine.unchanged();
    // The same single undo, repeated until the pointer rests on the bookmark.
    while (engine.state.history.pointer > engine.state.bookmark.?) {
        const undone = undo_command.execute(engine);
        if (undone != .ok) return undone;
    }
    const bookmark = engine.state.bookmark.?;
    // Rewind undoes one move at a time, so this reset replaces the notices those undos produced.
    engine.beginEventMsg();
    engine.appendEventMsgFmt(REWOUND_FMT, .{bookmark});
    return engine.finishOkEvent(engine.state.board.asView(), false, null);
}

// ---------------------------------------------------------------------------
// Tests (co-located)
// ---------------------------------------------------------------------------

const board_mod = @import("../board/board.zig");
const cell_mod = @import("../board/cell.zig");
const config = @import("../config.zig");
const puzzle_gen = @import("../puzzle_gen/mod.zig");

fn initEngine() !game_engine.GameEngine {
    return game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
}

/// Fail the test unless the event is `.ok`; return it so the caller can read its board and text.
fn expectOk(e: game_engine.Event) !game_engine.Event {
    if (e != .ok) return error.TestFailed;
    return e;
}

/// Copy the durable status so a later command cannot overwrite the bytes being compared.
fn copyStatus(engine: *const game_engine.GameEngine) ![]u8 {
    return std.testing.allocator.dupe(u8, engine.durableStatus() orelse return error.TestFailed);
}

test "set pins the current move and names it in the status" {
    var engine = try initEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });

    const ev = try expectOk(set(&engine));
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(BOOKMARK_SET_FMT, .{1}), ev.ok.msg.?);
    try std.testing.expectEqual(@as(?u16, 1), engine.state.bookmark);
    // Bookmarking the move you are on leaves nothing to rewind to.
    try std.testing.expect(!canRewind(&engine));
}

test "bookmarking again moves the bookmark to the newer move" {
    var engine = try initEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = set(&engine);
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });

    const ev = try expectOk(set(&engine));
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(BOOKMARK_SET_FMT, .{2}), ev.ok.msg.?);
    try std.testing.expectEqual(@as(?u16, 2), engine.state.bookmark);
    try std.testing.expect(!canRewind(&engine));
}

test "rewind undoes back to the bookmark in one step and leaves Redo one move at a time" {
    var engine = try initEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = set(&engine);
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });
    _ = engine.exec(.{ .fill = .{ .row = 1, .col = 1, .digit = .nine } });
    try std.testing.expect(canRewind(&engine));

    const ev = try expectOk(rewind(&engine));
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(REWOUND_FMT, .{1}), ev.ok.msg.?);
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);
    try std.testing.expectEqual(cell_mod.CellValue.four, ev.ok.board_view.get(0, 0));
    try std.testing.expectEqual(cell_mod.CellValue.zero, ev.ok.board_view.get(0, 3));
    try std.testing.expectEqual(cell_mod.CellValue.zero, ev.ok.board_view.get(1, 1));
    try std.testing.expect(!canRewind(&engine));

    const redone = try expectOk(engine.exec(.{ .redo = {} }));
    try std.testing.expectEqual(cell_mod.CellValue.nine, redone.ok.board_view.get(0, 3));
    try std.testing.expectEqual(cell_mod.CellValue.zero, redone.ok.board_view.get(1, 1));
    try std.testing.expectEqual(@as(usize, 2), engine.state.history.pointer);
}

test "rewind puts back the pencil marks the undone moves cleared" {
    var engine = try initEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .pencil = .{ .row = 0, .col = 3, .digit = .seven } });
    const marked = engine.state.board.marksAt(0, 3);
    try std.testing.expect(marked != 0);
    _ = set(&engine);

    // Filling a seven in the same row clears that mark, as a player fill does.
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .seven } });
    try std.testing.expectEqual(@as(board_mod.MarkSet, 0), engine.state.board.marksAt(0, 3));

    _ = try expectOk(rewind(&engine));
    try std.testing.expectEqual(marked, engine.state.board.marksAt(0, 3));
}

test "a rewind that is not offered changes nothing and reports nothing" {
    var engine = try initEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .hint = .{} });
    const before = try copyStatus(&engine);
    defer std.testing.allocator.free(before);

    // No bookmark at all.
    _ = try expectOk(rewind(&engine));
    try std.testing.expectEqualStrings(before, engine.durableStatus().?);
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.pointer);

    // A bookmark at the move the player is on.
    _ = set(&engine);
    const set_status = try copyStatus(&engine);
    defer std.testing.allocator.free(set_status);
    _ = try expectOk(rewind(&engine));
    try std.testing.expectEqualStrings(set_status, engine.durableStatus().?);
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.pointer);
}

test "a new move after a rewind drops the undone moves and leaves the bookmark usable" {
    var engine = try initEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = set(&engine);
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });
    _ = try expectOk(rewind(&engine));

    _ = engine.exec(.{ .fill = .{ .row = 4, .col = 4, .digit = .one } });
    try std.testing.expectEqual(@as(usize, 2), engine.state.history.pointer);
    try std.testing.expectEqual(@as(?u16, 1), engine.state.bookmark);
    try std.testing.expect(canRewind(&engine));

    _ = try expectOk(rewind(&engine));
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);
    try std.testing.expectEqual(cell_mod.CellValue.zero, engine.state.board.getCellValue(4, 4));
}

test "a bookmark before a solve rewinds the whole solve in one step" {
    var engine = try initEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = set(&engine);
    _ = engine.exec(.{ .solve_for_me = {} });
    try std.testing.expect(engine.state.board.isSolved());

    _ = try expectOk(rewind(&engine));
    try std.testing.expect(!engine.state.board.isSolved());
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);
}

test "the two bookmark confirmations read as sentences" {
    const sentence = @import("../../test/sentence.zig");
    var buf: [128]u8 = undefined;
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, BOOKMARK_SET_FMT, .{12}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, REWOUND_FMT, .{12}));
}

test "a rewind reports itself once, not the notices of the undos it replayed" {
    var engine = try initEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 0, .digit = .four } });
    _ = set(&engine);
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 3, .digit = .nine } });
    _ = engine.exec(.{ .fill = .{ .row = 1, .col = 1, .digit = .four } });
    _ = engine.exec(.{ .fill = .{ .row = 2, .col = 2, .digit = .nine } });

    // Four moves down to the bookmark is four undos, each naming its cell; the rewind replaces
    // all of that with its own single sentence.
    const event = try expectOk(rewind(&engine));
    var buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, REWOUND_FMT, .{1});
    try std.testing.expectEqualStrings(want, event.ok.msg.?);
}
