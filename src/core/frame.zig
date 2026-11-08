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
    /// Draw pencil marks (`GameEngine.marksVisible`).
    marks_visible: bool = false,
    /// Digits toggle pencil marks (the pad's Pencil button); the terminal ignores it.
    pencil_mode: bool = false,

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
        .pencil_mode = engine.pencil_mode,
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

test "the frame carries the status line, marks_visible and Pencil mode; nothing selected shades nothing" {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const frame = build(&engine, config.Config.default(), "status line 1");
    try std.testing.expectEqualStrings("status line 1", frame.status.?);
    try std.testing.expectEqual(engine.marksVisible(), frame.marks_visible);
    try std.testing.expectEqual(engine.pencil_mode, frame.pencil_mode);
    try std.testing.expectEqual(@as(?board.CellMask, null), frame.region);
    try std.testing.expect(!frame.isSelected(0, 0));
}
