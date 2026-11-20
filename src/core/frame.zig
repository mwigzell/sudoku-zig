//! Frame — one draw's worth of state, built by core so no front end works any of it out.

// Board window, cell coordinates, core's region rule, and the engine and Config the builder reads.
const std = @import("std");
const board = @import("board/board.zig");
const conflict = @import("board/conflict.zig");
const event = @import("event.zig");
const game_engine = @import("engine/game_engine.zig");
const config = @import("config.zig");

/// Everything a renderer needs to draw the game once.
pub const Frame = struct {
    /// The puzzle: values, givens, conflicts, marks.
    board: board.Board.BoardView,
    /// Status line; null shows none.
    status: ?[]const u8 = null,
    /// The selected cell; null when nothing is selected.
    selected: ?event.CellCoord = null,
    /// The selected cell's row, column and box; null when Show Region is off or nothing is selected.
    region: ?board.CellMask = null,
    /// Should the board be drawn with marks in its cells (`GameEngine.marksVisible`)? This is the
    /// large-board size, not the drawing rule: which marks a cell shows is `drawnMarks`.
    marks_visible: bool = false,
    /// The Pencil switch (the pad's Pencil button); the terminal keeps no switch.
    /// Not the Auto Pencil setting: it shows and hides marks, and in the manual game it also
    /// makes a digit toggle a mark.
    is_pencil: bool = false,
    /// The Auto Pencil setting: the marks are the board's candidates, and Pencil only shows and
    /// hides them. Off is the manual game, where the marks are the player's own.
    auto_pencil: bool = false,

    /// Is (row, col) the selected cell?
    pub fn isSelected(self: Frame, row: u4, col: u4) bool {
        const sel = self.selected orelse return false;
        return sel.row == row and sel.col == col;
    }

    /// Is (row, col) shaded as part of the selected cell's region?
    pub fn inRegion(self: Frame, row: u4, col: u4) bool {
        const mask = self.region orelse return false;
        return mask & board.cellBit(row, col) != 0;
    }

    /// The marks drawn in every cell, row by row: the one drawing rule, answered for the whole
    /// board in a single pass so no front end derives it.
    ///
    /// Auto Pencil on draws the board's candidates wherever Pencil is on; Auto Pencil off draws the
    /// player's marks wherever Pencil or Show Pencil Marks asks for them. A cell holding a digit
    /// draws none.
    pub fn drawnMarks(self: Frame) [board.CELL_COUNT]board.MarkSet {
        // Every cell starts with no marks; the loop below fills the ones that draw some.
        var drawn: [board.CELL_COUNT]board.MarkSet = undefined;
        for (&drawn) |*cell_marks| cell_marks.* = 0;
        // Auto Pencil on draws nothing with Pencil off; the manual game draws for either switch.
        const draw = if (self.auto_pencil) self.is_pencil else self.is_pencil or self.marks_visible;
        if (!draw) return drawn;
        for (0..board.DIMENSION_SIZE) |r| {
            for (0..board.DIMENSION_SIZE) |c| {
                const row: u4 = @intCast(r);
                const col: u4 = @intCast(c);
                if (self.board.get(row, col) != .zero) continue;
                const idx = @as(usize, @intCast(row)) * board.DIMENSION_SIZE + @as(usize, @intCast(col));
                drawn[idx] = if (self.auto_pencil) self.board.candidates(row, col) else self.board.marks(row, col);
            }
        }
        return drawn;
    }
};

/// Build the frame for the engine's current game and selection, with this status line;
/// `cfg` is the player's Config (Show Region shades the selected cell's units).
pub fn build(engine: *game_engine.GameEngine, cfg: config.Config, status: ?[]const u8) Frame {
    const selected = engine.selected;
    return .{
        .board = engine.eventBoard(),
        .status = status,
        .selected = selected,
        .region = if (selected) |sel| (if (cfg.show_region) conflict.unitsMask(sel.row, sel.col) else null) else null,
        .marks_visible = engine.marksVisible(),
        .is_pencil = engine.is_pencil,
        .auto_pencil = cfg.auto_pencil,
    };
}

const puzzle_gen = @import("puzzle_gen/mod.zig");

test "the frame shades the selected cell's row, column and box only while Show Region is on" {
    var cfg = config.Config.default();
    cfg.show_region = true;
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    defer engine.deinit();

    engine.selected = .{ .row = 4, .col = 4 };
    const on = build(&engine, cfg, null);
    try std.testing.expect(on.isSelected(4, 4));
    try std.testing.expect(on.inRegion(4, 0));
    try std.testing.expect(on.inRegion(0, 4));
    try std.testing.expect(on.inRegion(3, 3));
    try std.testing.expect(!on.inRegion(0, 0));

    cfg.show_region = false;
    const off = build(&engine, cfg, null);
    try std.testing.expect(off.isSelected(4, 4));
    try std.testing.expectEqual(@as(?board.CellMask, null), off.region);
}

test "the frame carries the status line, marks_visible and Pencil; nothing selected shades nothing" {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const frame = build(&engine, config.Config.default(), "status line 1");
    try std.testing.expectEqualStrings("status line 1", frame.status.?);
    try std.testing.expectEqual(engine.marksVisible(), frame.marks_visible);
    try std.testing.expectEqual(engine.is_pencil, frame.is_pencil);
    try std.testing.expectEqual(@as(?board.CellMask, null), frame.region);
    try std.testing.expect(!frame.isSelected(0, 0));
}

// --- drawn marks -----------------------------------------------------------

/// The default puzzle: A1 (0,0) is a given, C1 (0,2) and B2 (1,1) are empty.
const GIVEN: event.CellCoord = .{ .row = 0, .col = 0 };
const EMPTY: event.CellCoord = .{ .row = 0, .col = 2 };

fn cellIndex(row: u4, col: u4) usize {
    return @as(usize, @intCast(row)) * board.DIMENSION_SIZE + @as(usize, @intCast(col));
}

/// The drawn marks of one cell, as `drawnMarks` reports them.
fn drawnAt(frame: Frame, row: u4, col: u4) board.MarkSet {
    return frame.drawnMarks()[cellIndex(row, col)];
}

/// A board the player has filled at C1 and marked at B2, with Pencil left off.
fn playedEngine(cfg: config.Config) !game_engine.GameEngine {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    _ = engine.exec(.{ .fill = .{ .row = EMPTY.row, .col = EMPTY.col, .digit = .five } });
    _ = engine.exec(.{ .pencil = .{ .row = 1, .col = 1, .digit = .seven } });
    // The mark command selects B2; a later command leaves the selection where it is.
    _ = engine.exec(.{ .select = .{ .row = 8, .col = 8 } });
    return engine;
}

test "drawn marks: the four combinations of Auto Pencil and Show Pencil Marks, with Pencil off" {
    var cfg = config.Config.default();
    cfg.auto_pencil = true;
    cfg.show_marks = true;
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    defer engine.deinit();
    const candidates = engine.eventBoard().candidates(1, 1);
    // A fresh game holds no player's marks, so Auto Pencil off draws nothing either way.
    try std.testing.expectEqual(@as(board.MarkSet, 0), engine.eventBoard().marks(1, 1));

    // Auto Pencil on, Pencil off: nothing drawn, whatever Show Pencil Marks says.
    try std.testing.expectEqual(@as(board.MarkSet, 0), drawnAt(build(&engine, cfg, null), 1, 1));
    // Auto Pencil on, Pencil on: the board's candidates, Show Pencil Marks ignored.
    engine.is_pencil = true;
    try std.testing.expectEqual(candidates, drawnAt(build(&engine, cfg, null), 1, 1));
    cfg.show_marks = false;
    try std.testing.expectEqual(candidates, drawnAt(build(&engine, cfg, null), 1, 1));

    // Auto Pencil off, Pencil on: the player's marks, which a fresh game does not have.
    cfg.auto_pencil = false;
    try std.testing.expectEqual(@as(board.MarkSet, 0), drawnAt(build(&engine, cfg, null), 1, 1));
    // Auto Pencil off, Show Pencil Marks on, Pencil off: the player's marks.
    engine.is_pencil = false;
    cfg.show_marks = true;
    try std.testing.expectEqual(@as(board.MarkSet, 0), drawnAt(build(&engine, cfg, null), 1, 1));
    // Auto Pencil off, both off: nothing.
    cfg.show_marks = false;
    try std.testing.expectEqual(@as(board.MarkSet, 0), drawnAt(build(&engine, cfg, null), 1, 1));
}

test "drawn marks: a filled cell reports none in every combination" {
    const cfg = config.Config.default();
    var engine = try playedEngine(cfg);
    defer engine.deinit();
    try std.testing.expectEqual(.five, engine.eventBoard().get(EMPTY.row, EMPTY.col));

    for ([_]bool{ true, false }) |auto| for ([_]bool{ true, false }) |pencil| for ([_]bool{ true, false }) |show| {
        var combo = cfg;
        combo.auto_pencil = auto;
        combo.show_marks = show;
        engine.is_pencil = pencil;
        try std.testing.expectEqual(@as(board.MarkSet, 0), drawnAt(build(&engine, combo, null), EMPTY.row, EMPTY.col));
        // A given holds a digit too.
        try std.testing.expectEqual(@as(board.MarkSet, 0), drawnAt(build(&engine, combo, null), GIVEN.row, GIVEN.col));
    };
}

test "drawn marks: Auto Pencil off with Pencil on draws an unselected empty cell's marks" {
    const cfg = config.Config.default();
    var engine = try playedEngine(cfg);
    defer engine.deinit();
    // Show Pencil Marks is on by default; Pencil alone has to draw the marks.
    try std.testing.expect(!cfg.auto_pencil);
    engine.is_pencil = true;
    try std.testing.expect(engine.is_pencil);
    // B2 holds the player's mark and is not the selected cell.
    const selected = engine.selected.?;
    try std.testing.expect(selected.row != 1 or selected.col != 1);

    const mark_seven: board.MarkSet = @as(board.MarkSet, 1) << @intCast(board.markPlane(.seven));
    try std.testing.expectEqual(mark_seven, engine.eventBoard().marks(1, 1));
    try std.testing.expectEqual(mark_seven, drawnAt(build(&engine, cfg, null), 1, 1));
}
