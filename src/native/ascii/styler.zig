const cell = @import("../../board/cell.zig");
const board = @import("../../board/board.zig");
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
