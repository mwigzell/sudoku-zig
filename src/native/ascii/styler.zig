const cell = @import("../../core/board/cell.zig");
const board = @import("../../core/board/board.zig");
const frame_mod = @import("../../core/frame.zig");
const std = @import("std");

/// Core's frame: the board plus the selected cell and its region.
const Frame = frame_mod.Frame;

// ---------------------------------------------------------------------------
/// Plain styler — produces unadorned layout identical to original cellRow output.
pub const PlainStyler = struct {
    /// Fill the passed buffer with a formatted row string for `row_idx`.
    pub fn formatRow(self: *PlainStyler, row_idx: usize, frame: Frame, buf: []u8) ![]u8 {
        _ = self;
        const rv = board.Board.asRow(@intCast(row_idx));
        const vals = frame.board.resolve(&rv.indices);

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
    pub fn formatLargeLine(self: *PlainStyler, row_idx: usize, line: usize, frame: Frame, buf: []u8) ![]u8 {
        _ = self;
        return largeLine(row_idx, line, frame, false, buf);
    }
};

// Tests (co-located) — PlainStyler produces bit-for-bit identical output
// ---------------------------------------------------------------------------

test "PlainStyler formats empty board row 0 identically to cellRow" {
    var b = board.Board.init();
    const view = b.asView();

    var buf: [64]u8 = undefined;
    var styler = PlainStyler{};
    const line = try styler.formatRow(0, .{ .board = view }, &buf);

    try std.testing.expectEqualStrings("1│       │       │       │\n", line);
}

// ============================================================================
/// ANSI constants — Dim ON (givens) / Reset
const DIM_ON = "\x1b[2m";
const CONFLICT_ON = "\x1b[7m";
const RESET = "\x1b[0m";

// Background greys on the 256-colour ramp (232 darkest … 255 lightest).
/// The selected cell's row, column and box.
const GREY_REGION: u8 = 238;
/// The selected cell, lighter than its region.
const GREY_SELECTED: u8 = 242;

fn background(comptime grey: u8) []const u8 {
    return std.fmt.comptimePrint("\x1b[48;5;{d}m", .{grey});
}

/// Foreground of a pencil mark: a muted cyan, readable on every background and unlike a
/// player's digit (default) or a given (dim).
const MARK_ON = "\x1b[38;5;109m";
/// Back to the default foreground, keeping the cell's background.
const MARK_OFF = "\x1b[39m";

/// Background of the selected cell's region.
pub const REGION_ON = background(GREY_REGION);
/// Background of the selected cell.
pub const SELECT_ON = background(GREY_SELECTED);

/// Is (row, col) shaded as the selected cell? Only while its region is shown: the terminal
/// has no deselect, so a selection drawn with Show Region off could never be turned off.
fn shadesSelected(frame: Frame, row: u4, col: u4) bool {
    return frame.region != null and frame.isSelected(row, col);
}

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
/// An unset mark's slot on the plain board, where marks have no colour to tell them from digits.
const UNSET_MARK = "·";
/// An unset mark's slot on the styled board, where marks are coloured.
const UNSET_MARK_STYLED = " ";
/// Bytes of the longest slot: an unset `·`, or a coloured mark.
const LARGE_SLOT_MAX = @max(UNSET_MARK.len, MARK_ON.len + 1 + MARK_OFF.len);
/// Bytes of one line of a large cell's text.
const LARGE_CELL_TEXT_MAX = 2 + @as(usize, board.BOX_DIMENSION) * LARGE_SLOT_MAX;

/// Line `line` of the cell at (row, col): its marks for that line of the 3×3 grid; when `styled`
/// a mark is coloured and an unset one blank, when plain an unset one is `·`. A filled cell shows
/// only its digit, in the middle of the middle line.
fn largeCellText(view: board.Board.BoardView, row: u4, col: u4, line: usize, styled: bool, out: *[LARGE_CELL_TEXT_MAX]u8) []const u8 {
    const unset = if (styled) UNSET_MARK_STYLED else UNSET_MARK;
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
            const digit = '1' + @as(u8, @intCast(plane));
            const written = if (styled)
                std.fmt.bufPrint(out[len..], MARK_ON ++ "{c}" ++ MARK_OFF, .{digit}) catch unreachable
            else
                std.fmt.bufPrint(out[len..], "{c}", .{digit}) catch unreachable;
            len += written.len;
        } else {
            @memcpy(out[len..][0..unset.len], unset);
            len += unset.len;
        }
    }
    out[len] = ' ';
    return out[0 .. len + 1];
}

/// ANSI codes for a whole large cell, in style_cell's order: a conflicting entry is reversed,
/// otherwise the selection or region shading, with givens dimmed.
fn largeCellStyle(frame: Frame, row: u4, col: u4) []const u8 {
    const view = frame.board;
    const value = view.get(row, col);
    const given = view.isGiven(row, col) and value != .zero;
    if (!given and value != .zero and view.isConflictingRowCol(row, col)) return CONFLICT_ON;
    if (shadesSelected(frame, row, col)) return if (given) SELECT_ON ++ DIM_ON else SELECT_ON;
    if (frame.inRegion(row, col)) return if (given) REGION_ON ++ DIM_ON else REGION_ON;
    return if (given) DIM_ON else "";
}

/// One text line of board row `row_idx` in the large board; the row number sits on the
/// middle line. `styled` adds the ANSI cell styling.
fn largeLine(row_idx: usize, line: usize, frame: Frame, styled: bool, buf: []u8) ![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    const row: u4 = @intCast(row_idx);
    if (line == LARGE_CELL_LINES / 2) try w.print("{d}│", .{row_idx + 1}) else try w.writeAll(" │");
    for (0..board.DIMENSION_SIZE) |c| {
        const col: u4 = @intCast(c);
        var text_buf: [LARGE_CELL_TEXT_MAX]u8 = undefined;
        const style = if (styled) largeCellStyle(frame, row, col) else "";
        try w.writeAll(style);
        try w.writeAll(largeCellText(frame.board, row, col, line, styled, &text_buf));
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
        try plain.formatLargeLine(0, 0, .{ .board = view }, &buf),
    );
    try std.testing.expectEqualStrings(
        "1│ ·5·   7   ··· │" ++ empty_box ++ empty_box ++ "\n",
        try plain.formatLargeLine(0, 1, .{ .board = view }, &buf),
    );
}

// ---------------------------------------------------------------------------
/// AnsiStyler — fills buffer with formatted row string for `row_idx`.
pub const AnsiStyler = struct {
    /// Fill the passed buffer with a formatted row string for `row_idx`.
    pub fn formatRow(self: *AnsiStyler, row_idx: usize, frame: Frame, buf: []u8) ![]u8 {
        _ = self;
        const view = frame.board;
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
            s0[0..style_cell(vals[0], gives[0], conflicts[0], frame.inRegion(row, 0), shadesSelected(frame, row, 0), &s0)],
            s1[0..style_cell(vals[1], gives[1], conflicts[1], frame.inRegion(row, 1), shadesSelected(frame, row, 1), &s1)],
            s2[0..style_cell(vals[2], gives[2], conflicts[2], frame.inRegion(row, 2), shadesSelected(frame, row, 2), &s2)],
            s3[0..style_cell(vals[3], gives[3], conflicts[3], frame.inRegion(row, 3), shadesSelected(frame, row, 3), &s3)],
            s4[0..style_cell(vals[4], gives[4], conflicts[4], frame.inRegion(row, 4), shadesSelected(frame, row, 4), &s4)],
            s5[0..style_cell(vals[5], gives[5], conflicts[5], frame.inRegion(row, 5), shadesSelected(frame, row, 5), &s5)],
            s6[0..style_cell(vals[6], gives[6], conflicts[6], frame.inRegion(row, 6), shadesSelected(frame, row, 6), &s6)],
            s7[0..style_cell(vals[7], gives[7], conflicts[7], frame.inRegion(row, 7), shadesSelected(frame, row, 7), &s7)],
            s8[0..style_cell(vals[8], gives[8], conflicts[8], frame.inRegion(row, 8), shadesSelected(frame, row, 8), &s8)],
        });
    }

    /// One text line of board row `row_idx` in the large board, styled like formatRow's cells.
    pub fn formatLargeLine(self: *AnsiStyler, row_idx: usize, line: usize, frame: Frame, buf: []u8) ![]u8 {
        _ = self;
        return largeLine(row_idx, line, frame, true, buf);
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
    const line = try styler.formatRow(0, .{ .board = view }, &buf);

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
    const line = try styler.formatRow(0, .{ .board = view }, &buf);

    // Row 0 should contain reverse-video (CONFLICT_ON) markers for the conflicting cells.
    const conflict_count = std.mem.count(u8, line, CONFLICT_ON);
    try std.testing.expectEqual(@as(usize, 2), conflict_count);
}

const conflict = @import("../../core/board/conflict.zig");

test "AnsiStyler: peer region cells get region background when selection set" {
    var b = board.Board.init();
    const view = b.asView();
    const frame = Frame{ .board = view, .selected = .{ .row = 4, .col = 4 }, .region = conflict.unitsMask(4, 4) };

    var buf: [512]u8 = undefined;
    var ansi = AnsiStyler{};
    const line = try ansi.formatRow(4, frame, &buf);

    const region_count = std.mem.count(u8, line, REGION_ON);
    try std.testing.expect(region_count >= 5);
    const select_count = std.mem.count(u8, line, SELECT_ON);
    try std.testing.expectEqual(@as(usize, 1), select_count);
}

test "AnsiStyler: with Show Region off nothing is shaded, not even the selected cell" {
    var b = board.Board.init();
    const frame = Frame{ .board = b.asView(), .selected = .{ .row = 4, .col = 4 } };
    var buf: [512]u8 = undefined;
    var ansi = AnsiStyler{};
    const line = try ansi.formatRow(4, frame, &buf);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, line, SELECT_ON));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, line, REGION_ON));
}

test "the region and selected-cell greys are clearly apart, the selected cell lighter" {
    // Ramp steps that keep two neighbouring greys clearly apart.
    const min_step = 3;
    try std.testing.expect(GREY_SELECTED - GREY_REGION >= min_step);
}

test "large board, styled, Show Region off: nothing is shaded, not even the selected cell" {
    var b = board.Board.init();
    const frame = Frame{ .board = b.asView(), .selected = .{ .row = 0, .col = 0 } };
    var buf: [1024]u8 = undefined;
    var ansi = AnsiStyler{};
    const top = try ansi.formatLargeLine(0, 0, frame, &buf);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, top, SELECT_ON));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, top, REGION_ON));
}

test "large board, styled: marks in their own colour, no dots, empty and filled cells unshaded outside the region" {
    var b = board.Board.init();
    b.toggleMark(0, 0, .one);
    try b.setCell(0, 1, .seven);
    const frame = Frame{ .board = b.asView(), .selected = .{ .row = 4, .col = 4 }, .region = conflict.unitsMask(4, 4) };
    var buf: [1024]u8 = undefined;
    var ansi = AnsiStyler{};

    const top = try ansi.formatLargeLine(0, 0, frame, &buf);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, top, UNSET_MARK));
    try std.testing.expect(std.mem.startsWith(u8, top, " │ " ++ MARK_ON ++ "1" ++ MARK_OFF ++ "   " ++ "     "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, top, REGION_ON));

    const middle = try ansi.formatLargeLine(0, 1, frame, &buf);
    try std.testing.expect(std.mem.indexOf(u8, middle, "  7  ") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, middle, MARK_ON));

    const selected_row = try ansi.formatLargeLine(4, 0, frame, &buf);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, selected_row, SELECT_ON));
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, selected_row, REGION_ON));
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
    const line = try styler.formatRow(0, .{ .board = view }, &buf);

    // Since both cells are givens, they should be styled with DIM_ON (not CONFLICT_ON).
    const dim_count = std.mem.count(u8, line, DIM_ON);
    try std.testing.expectEqual(@as(usize, 2), dim_count);

    // No conflict markers — given-cell styling takes precedence.
    const conflict_count = std.mem.count(u8, line, CONFLICT_ON);
    try std.testing.expectEqual(@as(usize, 0), conflict_count);
}
