const cell = @import("../../core/board/cell.zig");
const board = @import("../../core/board/board.zig");
const std = @import("std");

pub const CellSelection = struct {
    row: u4,
    col: u4,
};

pub fn inPeerRegion(selection: ?CellSelection, row: u4, col: u4) bool {
    const sel = selection orelse return false;
    if (row == sel.row or col == sel.col) return true;
    const sel_box_row: u4 = @intCast(@divTrunc(@as(usize, @intCast(sel.row)), 3) * 3);
    const sel_box_col: u4 = @intCast(@divTrunc(@as(usize, @intCast(sel.col)), 3) * 3);
    const cell_box_row: u4 = @intCast(@divTrunc(@as(usize, @intCast(row)), 3) * 3);
    const cell_box_col: u4 = @intCast(@divTrunc(@as(usize, @intCast(col)), 3) * 3);
    return sel_box_row == cell_box_row and sel_box_col == cell_box_col;
}

// ---------------------------------------------------------------------------
/// Plain styler — produces unadorned layout identical to original cellRow output.
pub const PlainStyler = struct {
    /// Fill the passed buffer with a formatted row string for `row_idx`.
    pub fn formatRow(self: *PlainStyler, row_idx: usize, view: board.Board.BoardView, selection: ?CellSelection, buf: []u8) ![]u8 {
        _ = self;
        _ = selection;
        const rv = board.Board.asRow(@intCast(row_idx));
        const vals = view.resolve(&rv.indices);

        return std.fmt.bufPrint(
            buf,
            "{d}│ {c} {c} {c} │ {c} {c} {c} │ {c} {c} {c} │\n",
            .{
                row_idx + 1,
                cell.displayChar(vals[0]),
                cell.displayChar(vals[1]),
                cell.displayChar(vals[2]),
                cell.displayChar(vals[3]),
                cell.displayChar(vals[4]),
                cell.displayChar(vals[5]),
                cell.displayChar(vals[6]),
                cell.displayChar(vals[7]),
                cell.displayChar(vals[8]),
            },
        );
    }

    /// One text line of board row `row_idx` in the large board (pencil marks shown).
    pub fn formatLargeLine(self: *PlainStyler, row_idx: usize, line: usize, view: board.Board.BoardView, selection: ?CellSelection, buf: []u8) ![]u8 {
        _ = self;
        return largeLine(row_idx, line, view, selection, false, buf);
    }
};

// Tests (co-located) — PlainStyler produces bit-for-bit identical output
// ---------------------------------------------------------------------------

test "PlainStyler formats empty board row 0 identically to cellRow" {
    var b = board.Board.init();
    const view = b.asView();

    var buf: [64]u8 = undefined;
    var styler = PlainStyler{};
    const line = try styler.formatRow(0, view, null, &buf);

    try std.testing.expectEqualStrings("1│       │       │       │\n", line);
}

// ============================================================================
/// ANSI constants — Dim ON (givens) / Reset
const DIM_ON = "\x1b[2m";
const CONFLICT_ON = "\x1b[7m";
const REGION_ON = "\x1b[48;5;238m";
const SELECT_ON = "\x1b[48;5;237m";
const RESET = "\x1b[0m";

// ---------------------------------------------------------------------------
/// Private helper: build styled string for one cell position
/// Writes the display character (optionally CSI-wrapped) into `out` buffer.
fn style_cell(
    val: cell.CellValue,
    is_given: bool,
    is_conflict: bool,
    in_region: bool,
    is_selected: bool,
    out: []u8,
) usize {
    var offset: usize = 0;
    const use_conflict = is_conflict and val != .zero and !is_given;
    if (!use_conflict) {
        if (is_selected) {
            @memcpy(out[offset..][0..SELECT_ON.len], SELECT_ON);
            offset += SELECT_ON.len;
        } else if (in_region) {
            @memcpy(out[offset..][0..REGION_ON.len], REGION_ON);
            offset += REGION_ON.len;
        }
    }

    if (is_given and val != .zero) {
        @memcpy(out[offset..][0..DIM_ON.len], DIM_ON);
        offset += DIM_ON.len;
        out[offset] = cell.displayChar(val);
        offset += 1;
        @memcpy(out[offset..][0..RESET.len], RESET);
        offset += RESET.len;
        return offset;
    }
    if (use_conflict) {
        @memcpy(out[offset..][0..CONFLICT_ON.len], CONFLICT_ON);
        offset += CONFLICT_ON.len;
        out[offset] = cell.displayChar(val);
        offset += 1;
        @memcpy(out[offset..][0..RESET.len], RESET);
        offset += RESET.len;
        return offset;
    }

    out[offset] = cell.displayChar(val);
    offset += 1;
    if (offset > 1) {
        @memcpy(out[offset..][0..RESET.len], RESET);
        offset += RESET.len;
    }
    return offset;
}

// ---------------------------------------------------------------------------
/// The large board, drawn while pencil marks are shown: each cell is a block of
/// LARGE_CELL_LINES lines of LARGE_CELL_COLS columns holding its 3×3 marks.
pub const LARGE_CELL_LINES = board.BOX_DIMENSION;
/// Columns of a large cell: a space, one slot per mark on the line, a space.
pub const LARGE_CELL_COLS = board.BOX_DIMENSION + 2;
/// An unset mark's slot.
const UNSET_MARK = "·";
/// Bytes of one line of a large cell's text (every slot unset at most).
const LARGE_CELL_TEXT_MAX = 2 + board.BOX_DIMENSION * UNSET_MARK.len;

/// Line `line` of the cell at (row, col): its marks for that line of the 3×3 grid, `·` for
/// an unset one; a filled cell shows only its digit, in the middle of the middle line.
fn largeCellText(view: board.Board.BoardView, row: u4, col: u4, line: usize, out: *[LARGE_CELL_TEXT_MAX]u8) []const u8 {
    const value = view.get(row, col);
    if (value != .zero) {
        const shown: u8 = if (line == LARGE_CELL_LINES / 2) cell.displayChar(value) else ' ';
        return std.fmt.bufPrint(out, "  {c}  ", .{shown}) catch unreachable;
    }
    const marks = view.marks(row, col);
    var len: usize = 0;
    out[len] = ' ';
    len += 1;
    for (0..board.BOX_DIMENSION) |slot| {
        const plane = line * board.BOX_DIMENSION + slot;
        if (marks & (@as(board.MarkSet, 1) << @intCast(plane)) != 0) {
            out[len] = '1' + @as(u8, @intCast(plane));
            len += 1;
        } else {
            @memcpy(out[len..][0..UNSET_MARK.len], UNSET_MARK);
            len += UNSET_MARK.len;
        }
    }
    out[len] = ' ';
    return out[0 .. len + 1];
}

/// ANSI codes for a whole large cell, in style_cell's order: a conflicting entry is reversed,
/// otherwise the selection or region shading, with givens dimmed.
fn largeCellStyle(view: board.Board.BoardView, row: u4, col: u4, selection: ?CellSelection) []const u8 {
    const value = view.get(row, col);
    const given = view.isGiven(row, col) and value != .zero;
    if (!given and value != .zero and view.isConflictingRowCol(row, col)) return CONFLICT_ON;
    const selected = if (selection) |sel| sel.row == row and sel.col == col else false;
    if (selected) return if (given) SELECT_ON ++ DIM_ON else SELECT_ON;
    if (inPeerRegion(selection, row, col)) return if (given) REGION_ON ++ DIM_ON else REGION_ON;
    return if (given) DIM_ON else "";
}

/// One text line of board row `row_idx` in the large board; the row number sits on the
/// middle line. `styled` adds the ANSI cell styling.
fn largeLine(row_idx: usize, line: usize, view: board.Board.BoardView, selection: ?CellSelection, styled: bool, buf: []u8) ![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    const row: u4 = @intCast(row_idx);
    if (line == LARGE_CELL_LINES / 2) try w.print("{d}│", .{row_idx + 1}) else try w.writeAll(" │");
    for (0..board.DIMENSION_SIZE) |c| {
        const col: u4 = @intCast(c);
        var text_buf: [LARGE_CELL_TEXT_MAX]u8 = undefined;
        const style = if (styled) largeCellStyle(view, row, col, selection) else "";
        try w.writeAll(style);
        try w.writeAll(largeCellText(view, row, col, line, &text_buf));
        if (style.len > 0) try w.writeAll(RESET);
        if (c % board.BOX_DIMENSION == board.BOX_DIMENSION - 1) try w.writeAll("│");
    }
    try w.writeAll("\n");
    return w.buffered();
}

test "large board: a marked empty cell shows its marks in place, a filled cell only its digit" {
    var b = board.Board.init();
    b.toggleMark(0, 0, .one);
    b.toggleMark(0, 0, .five);
    b.toggleMark(0, 0, .nine);
    try b.setCell(0, 1, .seven);
    const view = b.asView();
    var buf: [512]u8 = undefined;
    var plain = PlainStyler{};
    const empty_box = " ···  ···  ··· │";
    try std.testing.expectEqualStrings(
        " │ 1··       ··· │" ++ empty_box ++ empty_box ++ "\n",
        try plain.formatLargeLine(0, 0, view, null, &buf),
    );
    try std.testing.expectEqualStrings(
        "1│ ·5·   7   ··· │" ++ empty_box ++ empty_box ++ "\n",
        try plain.formatLargeLine(0, 1, view, null, &buf),
    );
}

// ---------------------------------------------------------------------------
/// AnsiStyler — fills buffer with formatted row string for `row_idx`.
pub const AnsiStyler = struct {
    /// Fill the passed buffer with a formatted row string for `row_idx`.
    pub fn formatRow(self: *AnsiStyler, row_idx: usize, view: board.Board.BoardView, selection: ?CellSelection, buf: []u8) ![]u8 {
        _ = self;
        const rv = board.Board.asRow(@intCast(row_idx));
        const row: u4 = @intCast(row_idx);

        const vals = view.resolve(&rv.indices);
        var gives: [9]bool = undefined;
        var conflicts: [9]bool = undefined;
        for (0..9) |i| {
            gives[i] = view.isGiven(row, @intCast(i));
            conflicts[i] = view.isConflictingRowCol(row, @intCast(i));
        }

        var s0: [20]u8 = undefined;
        var s1: [20]u8 = undefined;
        var s2: [20]u8 = undefined;
        var s3: [20]u8 = undefined;
        var s4: [20]u8 = undefined;
        var s5: [20]u8 = undefined;
        var s6: [20]u8 = undefined;
        var s7: [20]u8 = undefined;
        var s8: [20]u8 = undefined;

        return std.fmt.bufPrint(buf, "{d}│ {s} {s} {s} │ {s} {s} {s} │ {s} {s} {s} │\n", .{
            row_idx + 1,
            s0[0..style_cell(vals[0], gives[0], conflicts[0], inPeerRegion(selection, row, 0), selection != null and selection.?.row == row and selection.?.col == 0, &s0)],
            s1[0..style_cell(vals[1], gives[1], conflicts[1], inPeerRegion(selection, row, 1), selection != null and selection.?.row == row and selection.?.col == 1, &s1)],
            s2[0..style_cell(vals[2], gives[2], conflicts[2], inPeerRegion(selection, row, 2), selection != null and selection.?.row == row and selection.?.col == 2, &s2)],
            s3[0..style_cell(vals[3], gives[3], conflicts[3], inPeerRegion(selection, row, 3), selection != null and selection.?.row == row and selection.?.col == 3, &s3)],
            s4[0..style_cell(vals[4], gives[4], conflicts[4], inPeerRegion(selection, row, 4), selection != null and selection.?.row == row and selection.?.col == 4, &s4)],
            s5[0..style_cell(vals[5], gives[5], conflicts[5], inPeerRegion(selection, row, 5), selection != null and selection.?.row == row and selection.?.col == 5, &s5)],
            s6[0..style_cell(vals[6], gives[6], conflicts[6], inPeerRegion(selection, row, 6), selection != null and selection.?.row == row and selection.?.col == 6, &s6)],
            s7[0..style_cell(vals[7], gives[7], conflicts[7], inPeerRegion(selection, row, 7), selection != null and selection.?.row == row and selection.?.col == 7, &s7)],
            s8[0..style_cell(vals[8], gives[8], conflicts[8], inPeerRegion(selection, row, 8), selection != null and selection.?.row == row and selection.?.col == 8, &s8)],
        });
    }

    /// One text line of board row `row_idx` in the large board, styled like formatRow's cells.
    pub fn formatLargeLine(self: *AnsiStyler, row_idx: usize, line: usize, view: board.Board.BoardView, selection: ?CellSelection, buf: []u8) ![]u8 {
        _ = self;
        return largeLine(row_idx, line, view, selection, true, buf);
    }
};

// ============================================================================
// Tests — AnsiStyler wraps given digits in dim CSI codes
// ---------------------------------------------------------------------------

test "AnsiStyler wraps given digits in dim CSI codes" {
    var givens_row = [_]u8{
        5, 3, 0, 0, 7, 0, 0, 0, 0,
    };
    var rest: [72]u8 = undefined;
    @memset(&rest, 0);

    var flat: [81]u8 = undefined;
    @memcpy(flat[0..9], &givens_row);
    @memcpy(flat[9..], &rest);

    var b = try board.fromFlat(flat, .{});
    const view = b.asView();

    var buf: [256]u8 = undefined;
    var styler = AnsiStyler{};
    const line = try styler.formatRow(0, view, null, &buf);

    const dim_count = std.mem.count(u8, line, DIM_ON);
    const reset_count = std.mem.count(u8, line, RESET);
    try std.testing.expectEqual(@as(usize, 3), dim_count);
    try std.testing.expectEqual(@as(usize, 3), reset_count);
}

// Conflicts live in board.conflict_bits which is accessible via Board.isConflicting(idx).
// BoardView will need isConflictingRowCol(row, col) to expose that through the read-only seam.

test "AnsiStyler: conflicting non-given cell gets distinct ANSI wrapping" {
    var b = board.Board.init();
    // Put same digit in two non-given cells on row 0 -> conflict
    try b.setCell(0, 1, .five); // index 1
    try b.setCell(0, 5, .five); // index 5 — duplicates with index 1
    b.validate();
    const view = b.asView();

    var buf: [256]u8 = undefined;
    var styler = AnsiStyler{};
    const line = try styler.formatRow(0, view, null, &buf);

    // Row 0 should contain reverse-video (CONFLICT_ON) markers for the conflicting cells.
    const conflict_count = std.mem.count(u8, line, CONFLICT_ON);
    try std.testing.expectEqual(@as(usize, 2), conflict_count);
}

test "AnsiStyler: peer region cells get region background when selection set" {
    var b = board.Board.init();
    const view = b.asView();
    const selection = CellSelection{ .row = 4, .col = 4 };

    var buf: [512]u8 = undefined;
    var ansi = AnsiStyler{};
    const line = try ansi.formatRow(4, view, selection, &buf);

    const region_count = std.mem.count(u8, line, REGION_ON);
    try std.testing.expect(region_count >= 5);
    const select_count = std.mem.count(u8, line, SELECT_ON);
    try std.testing.expectEqual(@as(usize, 1), select_count);
}

test "inPeerRegion: row, column, and box membership" {
    const sel = CellSelection{ .row = 4, .col = 4 };
    try std.testing.expect(inPeerRegion(sel, 4, 0));
    try std.testing.expect(inPeerRegion(sel, 0, 4));
    try std.testing.expect(inPeerRegion(sel, 3, 3));
    try std.testing.expect(!inPeerRegion(sel, 0, 0));
}

test "AnsiStyler: given cell takes precedence over conflict styling" {
    var flat: [81]u8 = undefined;
    @memset(&flat, 0);
    // Row 0: givens at col 0 and col 5 both with value 5 — they conflict but are givens.
    flat[0] = 5; // row 0, col 0 — given
    flat[5] = 5; // row 0, col 5 — given (conflicts with col 0)

    var b = try board.fromFlat(flat, .{});
    b.validate();

    // Both should be flagged as conflicting by Board.
    try std.testing.expect(b.isConflicting(0));
    try std.testing.expect(b.isConflicting(5));

    const view = b.asView();
    var buf: [256]u8 = undefined;
    var styler = AnsiStyler{};
    const line = try styler.formatRow(0, view, null, &buf);

    // Since both cells are givens, they should be styled with DIM_ON (not CONFLICT_ON).
    const dim_count = std.mem.count(u8, line, DIM_ON);
    try std.testing.expectEqual(@as(usize, 2), dim_count);

    // No conflict markers — given-cell styling takes precedence.
    const conflict_count = std.mem.count(u8, line, CONFLICT_ON);
    try std.testing.expectEqual(@as(usize, 0), conflict_count);
}
