// Pencil marks: toggling one mark, and Pencil mode, which turns digit entry into mark toggles.
const std = @import("std");
const game_engine = @import("game_engine.zig");
const command = @import("../command.zig");
const board = @import("../board/board.zig");
const cell = @import("../board/cell.zig");
const mutation_history = @import("mutation_history.zig");
const logger = @import("../logger.zig");

const log = logger.Logger(.engine);

/// Status line when a mark replaces a player's digit: the digit, then the cell label (e.g. C3).
pub const REPLACED_BY_MARK_FMT = "The {d} in {s} was replaced by a pencil mark.";

/// Toggle one mark. A given is refused; a player's digit in the cell is replaced by the mark.
/// The toggle is one history step.
pub fn execute(engine: *game_engine.GameEngine, data: command.PencilData) game_engine.Event {
    if (engine.state.board.isGiven(data.row, data.col)) return engine.errorEvent(game_engine.PUZZLE_CELL_MSG);
    const toggle: mutation_history.MarkToggle = .{
        .row = data.row,
        .col = data.col,
        .digit = data.digit,
        .old_value = engine.state.board.getCellValue(data.row, data.col),
    };
    engine.state.history.truncateFuture();
    engine.state.history.pushMark(toggle) catch |err| {
        log.err("history push failed: {s}", .{@errorName(err)});
        return engine.errorEvent(game_engine.MOVE_NOT_RECORDED_MSG);
    };
    // A fresh mark says what it did; a redo names the redo instead, so the replay stays silent.
    appendToggledMsg(engine, toggle);
    return applyForward(engine, toggle);
}

/// Flip Pencil mode. It is session state: not saved, and kept across New, Open and restore.
pub fn toggleMode(engine: *game_engine.GameEngine) game_engine.Event {
    engine.pencil_mode = !engine.pencil_mode;
    return engine.finishOkEvent(engine.state.board.asView(), false, null);
}

/// Make a recorded toggle (a new mark or Redo): remove the replaced digit, then flip the mark.
/// The caller says what the toggle did; this only replays it, so a redo is not named twice.
pub fn applyForward(
    engine: *game_engine.GameEngine,
    toggle: mutation_history.MarkToggle,
) game_engine.Event {
    engine.marks_changed = true;
    if (toggle.old_value != .zero) {
        engine.state.board.setCell(toggle.row, toggle.col, .zero) catch |err| {
            return engine.eventFromSetCellError(toggle.row, toggle.col, err);
        };
    }
    engine.state.board.toggleMark(toggle.row, toggle.col, toggle.digit);
    if (toggle.old_value == .zero) return finishMarkOnly(engine, toggle);
    // A mark that replaced a digit says what became of that digit as well.
    var label_buf: [2]u8 = undefined;
    appendMarkMsg(engine, REPLACED_BY_MARK_FMT, .{
        @backingInt(toggle.old_value),
        board.formatCellLabel(&label_buf, toggle.row, toggle.col),
    });
    return engine.finishOkAfterCellEdit(toggle.row, toggle.col);
}

/// Undo a toggle: flip the mark back, then restore the digit it replaced.
pub fn applyBackward(engine: *game_engine.GameEngine, toggle: mutation_history.MarkToggle) game_engine.Event {
    engine.marks_changed = true;
    engine.state.board.toggleMark(toggle.row, toggle.col, toggle.digit);
    if (toggle.old_value == .zero) return finishMarkOnly(engine, toggle);
    engine.state.board.setCell(toggle.row, toggle.col, toggle.old_value) catch |err| {
        return engine.eventFromSetCellError(toggle.row, toggle.col, err);
    };
    return engine.finishOkAfterCellEdit(toggle.row, toggle.col);
}

/// A mark alone changes no digit, so there is no conflict, solvability or win to report.
fn finishMarkOnly(engine: *game_engine.GameEngine, toggle: mutation_history.MarkToggle) game_engine.Event {
    return engine.finishOkEvent(engine.state.board.asView(), false, .{ .row = toggle.row, .col = toggle.col });
}

/// Say whether `toggle` is taking a mark off or putting it on, read from the cell before the flip.
fn appendToggledMsg(engine: *game_engine.GameEngine, toggle: mutation_history.MarkToggle) void {
    const marked = engine.state.board.marksAt(toggle.row, toggle.col) & markBit(toggle.digit) != 0;
    // One label buffer for both fragments: a returned label dies with the function's frame.
    var label_buf: [2]u8 = undefined;
    const args = .{ @backingInt(toggle.digit), board.formatCellLabel(&label_buf, toggle.row, toggle.col) };
    if (marked) {
        appendMarkMsg(engine, game_engine.MARK_REMOVED_FMT, args);
    } else {
        appendMarkMsg(engine, game_engine.MARKED_FMT, args);
    }
}

/// The cell's bit for one digit's mark.
fn markBit(digit: cell.CellValue) board.MarkSet {
    return @as(board.MarkSet, 1) << @intCast(board.markPlane(digit));
}

/// Append one status fragment for a mark command.
fn appendMarkMsg(engine: *game_engine.GameEngine, comptime fmt: []const u8, args: anytype) void {
    engine.appendEventMsgFmt(fmt, args);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const config = @import("../config.zig");
const puzzle_gen = @import("../puzzle_gen/mod.zig");

/// Default puzzle: A1 (0,0) is a given and C1 (0,2) is empty.
const GIVEN_ROW: u4 = 0;
const GIVEN_COL: u4 = 0;
const EMPTY_ROW: u4 = 0;
const EMPTY_COL: u4 = 2;

fn testEngine() !game_engine.GameEngine {
    return game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
}

test "a mark toggles on and off in an empty cell, one history step each" {
    var engine = try testEngine();
    defer engine.deinit();

    const on = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .five } });
    try std.testing.expect(on == .ok);
    try std.testing.expectEqual(markBit(.five), on.ok.board_view.marks(EMPTY_ROW, EMPTY_COL));
    try std.testing.expectEqual(cell.CellValue.zero, on.ok.board_view.get(EMPTY_ROW, EMPTY_COL));
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());

    const off = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .five } });
    try std.testing.expect(off == .ok);
    try std.testing.expectEqual(@as(board.MarkSet, 0), off.ok.board_view.marks(EMPTY_ROW, EMPTY_COL));
    try std.testing.expectEqual(@as(usize, 2), engine.state.history.count());
}

test "a mark that contradicts its row is allowed and flags no conflict" {
    var engine = try testEngine();
    defer engine.deinit();
    const first = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .five } });
    const row_given = first.ok.board_view.get(GIVEN_ROW, GIVEN_COL);

    const ev = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = row_given } });
    try std.testing.expect(ev == .ok);
    try std.testing.expectEqual(markBit(.five) | markBit(row_given), ev.ok.board_view.marks(EMPTY_ROW, EMPTY_COL));
    try std.testing.expect(!ev.ok.board_view.isConflictingRowCol(EMPTY_ROW, EMPTY_COL));
    try std.testing.expect(!ev.ok.board_view.isConflictingRowCol(GIVEN_ROW, GIVEN_COL));
}

test "a mark on a given is refused and records nothing" {
    var engine = try testEngine();
    defer engine.deinit();

    const ev = engine.exec(.{ .pencil = .{ .row = GIVEN_ROW, .col = GIVEN_COL, .digit = .five } });
    try std.testing.expectEqualStrings(game_engine.PUZZLE_CELL_MSG, ev.error_msg);
    try std.testing.expectEqual(@as(board.MarkSet, 0), engine.state.board.marksAt(GIVEN_ROW, GIVEN_COL));
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.count());
}

test "a mark on a player's digit replaces it, says so, and Undo puts the digit back" {
    var engine = try testEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .seven } });

    const ev = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .five } });
    try std.testing.expect(ev == .ok);
    try std.testing.expectEqual(cell.CellValue.zero, ev.ok.board_view.get(EMPTY_ROW, EMPTY_COL));
    try std.testing.expectEqual(markBit(.five), ev.ok.board_view.marks(EMPTY_ROW, EMPTY_COL));
    var want_buf: [160]u8 = undefined;
    var label_buf: [2]u8 = undefined;
    const label = board.formatCellLabel(&label_buf, EMPTY_ROW, EMPTY_COL);
    var marked_buf: [64]u8 = undefined;
    var replaced_buf: [96]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "{s} {s}", .{
        try std.fmt.bufPrint(&marked_buf, game_engine.MARKED_FMT, .{ 5, label }),
        try std.fmt.bufPrint(&replaced_buf, REPLACED_BY_MARK_FMT, .{ 7, label }),
    });
    try std.testing.expectEqualStrings(want, ev.ok.msg.?);

    const undone = engine.exec(.{ .undo = {} });
    try std.testing.expect(undone == .ok);
    try std.testing.expectEqual(cell.CellValue.seven, undone.ok.board_view.get(EMPTY_ROW, EMPTY_COL));
    try std.testing.expectEqual(@as(board.MarkSet, 0), undone.ok.board_view.marks(EMPTY_ROW, EMPTY_COL));

    const redone = engine.exec(.{ .redo = {} });
    try std.testing.expect(redone == .ok);
    try std.testing.expectEqual(cell.CellValue.zero, redone.ok.board_view.get(EMPTY_ROW, EMPTY_COL));
    try std.testing.expectEqual(markBit(.five), redone.ok.board_view.marks(EMPTY_ROW, EMPTY_COL));
}

test "Undo and Redo of a mark on an empty cell remove and restore it" {
    var engine = try testEngine();
    defer engine.deinit();
    _ = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .three } });

    _ = engine.exec(.{ .undo = {} });
    try std.testing.expectEqual(@as(board.MarkSet, 0), engine.state.board.marksAt(EMPTY_ROW, EMPTY_COL));
    _ = engine.exec(.{ .redo = {} });
    try std.testing.expectEqual(markBit(.three), engine.state.board.marksAt(EMPTY_ROW, EMPTY_COL));
}

test "in Pencil mode a fill toggles a mark instead; the mode survives a new game" {
    var engine = try testEngine();
    defer engine.deinit();
    try std.testing.expect(!engine.pencil_mode);

    _ = engine.exec(.{ .toggle_pencil_mode = {} });
    try std.testing.expect(engine.pencil_mode);
    const ev = engine.exec(.{ .fill = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .four } });
    try std.testing.expect(ev == .ok);
    try std.testing.expectEqual(cell.CellValue.zero, ev.ok.board_view.get(EMPTY_ROW, EMPTY_COL));
    try std.testing.expectEqual(markBit(.four), ev.ok.board_view.marks(EMPTY_ROW, EMPTY_COL));

    _ = engine.newFromOneLinePuzzle(puzzle_gen.PuzzleGen.default());
    try std.testing.expect(engine.pencil_mode);
    try std.testing.expectEqual(@as(board.MarkSet, 0), engine.state.board.marksAt(EMPTY_ROW, EMPTY_COL));
}

test "marks are visible with the setting on, in Pencil mode, or right after a mark, its Undo or its Redo" {
    var cfg = config.Config.default();
    try std.testing.expect(cfg.show_marks);
    cfg.show_marks = false;
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    defer engine.deinit();
    try std.testing.expect(!engine.marksVisible());

    _ = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .two } });
    try std.testing.expect(engine.marksVisible());
    _ = engine.exec(.{ .fill = .{ .row = 1, .col = 1, .digit = .two } });
    try std.testing.expect(!engine.marksVisible());
    _ = engine.exec(.{ .undo = {} });
    try std.testing.expect(!engine.marksVisible());
    _ = engine.exec(.{ .undo = {} });
    try std.testing.expect(engine.marksVisible());
    _ = engine.exec(.{ .redo = {} });
    try std.testing.expect(engine.marksVisible());

    _ = engine.exec(.{ .toggle_pencil_mode = {} });
    try std.testing.expect(engine.marksVisible());
    _ = engine.exec(.{ .toggle_pencil_mode = {} });
    try std.testing.expect(!engine.marksVisible());

    cfg.show_marks = true;
    engine.useConfig(cfg);
    try std.testing.expect(engine.marksVisible());
}

test "a command that says nothing leaves the durable status alone" {
    var engine = try testEngine();
    defer engine.deinit();

    _ = engine.exec(.{ .hint = .{ .row = EMPTY_ROW, .col = EMPTY_COL } });
    const after_hint = engine.durableStatus().?;

    // A select writes nothing, so the hint sentence is still the line.
    const selected = engine.exec(.{ .select = .{ .row = EMPTY_ROW, .col = EMPTY_COL } });
    try std.testing.expect(selected == .ok);
    try std.testing.expectEqualStrings(after_hint, selected.ok.msg.?);
    try std.testing.expectEqualStrings(after_hint, engine.durableStatus().?);
}

test "a mark, its undo and its redo each say what they did" {
    var engine = try testEngine();
    defer engine.deinit();
    var label_buf: [2]u8 = undefined;
    var want_buf: [64]u8 = undefined;
    const label = board.formatCellLabel(&label_buf, EMPTY_ROW, EMPTY_COL);

    const on = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .three } });
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&want_buf, game_engine.MARKED_FMT, .{ 3, label }),
        on.ok.msg.?,
    );

    const off = engine.exec(.{ .pencil = .{ .row = EMPTY_ROW, .col = EMPTY_COL, .digit = .three } });
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&want_buf, game_engine.MARK_REMOVED_FMT, .{ 3, label }),
        off.ok.msg.?,
    );

    const undone = engine.exec(.{ .undo = {} });
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&want_buf, game_engine.UNDID_MARK_FMT, .{label}),
        undone.ok.msg.?,
    );

    const redone = engine.exec(.{ .redo = {} });
    // The redo names the mark once: the toggle's own "Removed 3 from …" would say it a second time.
    var redo_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&redo_buf, game_engine.REDID_MARK_FMT, .{label}),
        redone.ok.msg.?,
    );
}

test "the eight cell sentences read as sentences" {
    const sentence = @import("../../test/sentence.zig");
    var buf: [64]u8 = undefined;
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, game_engine.FILLED_FMT, .{ "E5", 3 }));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, game_engine.CLEARED_FMT, .{"E5"}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, game_engine.MARKED_FMT, .{ 3, "E5" }));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, game_engine.MARK_REMOVED_FMT, .{ 3, "E5" }));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, game_engine.UNDID_MOVE_FMT, .{"E5"}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, game_engine.UNDID_MARK_FMT, .{"E5"}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, game_engine.REDID_MOVE_FMT, .{"E5"}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, game_engine.REDID_MARK_FMT, .{"E5"}));
}
