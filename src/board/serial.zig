const std = @import("std");
const board = @import("../board.zig");
const cell = @import("cell.zig");

pub const Error = board.Error;

pub const FlatOpts = struct {
    // When provided, use explicit given_bits mask; otherwise derive from nonzero cells.
    given_bits: ?u128 = null,
};

/// Serialize current cell values to a flat [81]u8 array for saving.
/// Each element is the raw digit: 0 for empty, 1-9 for filled.
pub fn toFlat(b: board.Board) [board.CELL_COUNT]u8 {
    var flat: [board.CELL_COUNT]u8 = undefined;
    for (b.cells, 0..) |c, i| {
        flat[i] = @as(u8, @intFromEnum(c.value));
    }
    return flat;
}

/// Compare two boards: same cell values and given_bits.
pub fn equal(a: board.Board, b: board.Board) bool {
    if (a.given_bits != b.given_bits) return false;
    for (a.cells, b.cells) |c1, c2| {
        if (c1.value != c2.value) return false;
    }
    return true;
}

/// Construct a Board from a flat 81-element u8 array.
pub fn fromFlat(flat: [81]u8, opts: FlatOpts) Error!board.Board {
    for (flat) |v| {
        if (v > 9) return Error.BadCellValue;
    }

    var b = board.Board.init();
    var mask: u128 = 0;
    for (flat, 0..) |v, i| {
        b.cells[i] = cell.Cell.init(cell.rawToCellValue(v));
        if (v != 0) {
            mask |= @as(u128, 1) << @intCast(i);
            const row: u4 = @intCast(@divTrunc(i, board.DIMENSION_SIZE));
            const col: u4 = @intCast(@mod(i, board.DIMENSION_SIZE));
            b.updateDigitBits(row, col, .zero, cell.rawToCellValue(v));
        }
    }
    b.given_bits = if (opts.given_bits) |explicit| explicit else mask;
    return b;
}

/// Construct a Board from a one-line Sudoku string like "53..7........6.....98..".
pub fn fromOneLineString(oneLine: []const u8) Error!board.Board {
    if (oneLine.len != 81) return Error.WrongLength;

    var flat: [81]u8 = undefined;
    for (oneLine, 0..) |ch, i| {
        flat[i] = switch (ch) {
            '.' => 0,
            '0' => 0,
            '1'...'9' => ch - '0',
            else => return Error.InvalidCharacter,
        };
    }
    return fromFlat(flat, .{});
}

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Board: constructs from flat puzzle array with correct values" {
    const easy: [81]u8 = blk: {
        var data: [81]u8 = undefined;
        @memset(&data, 0);

        // Row 0: 5 3 . | . 7 . | . . .
        data[0 * 9 + 0] = 5;
        data[0 * 9 + 1] = 3;
        data[0 * 9 + 4] = 7;
        // Row 1: 6 . . | 1 9 5 | . . .
        data[1 * 9 + 0] = 6;
        data[1 * 9 + 3] = 1;
        data[1 * 9 + 4] = 9;
        data[1 * 9 + 5] = 5;
        // Row 2: . 9 8 | . . . | . 6 .
        data[2 * 9 + 1] = 9;
        data[2 * 9 + 2] = 8;
        data[2 * 9 + 7] = 6;
        // Row 3: 8 . . | . 6 . | . . 3
        data[3 * 9 + 0] = 8;
        data[3 * 9 + 4] = 6;
        data[3 * 9 + 8] = 3;
        // Row 4: 4 . . | 8 . 3 | . . 1
        data[4 * 9 + 0] = 4;
        data[4 * 9 + 3] = 8;
        data[4 * 9 + 4] = 3;
        data[4 * 9 + 8] = 1;
        // Row 5: 7 . . | . 2 . | . . 6
        data[5 * 9 + 0] = 7;
        data[5 * 9 + 4] = 2;
        data[5 * 9 + 8] = 6;
        // Row 6: . 6 . | . . . | 2 8 .
        data[6 * 9 + 1] = 6;
        data[6 * 9 + 6] = 2;
        data[6 * 9 + 7] = 8;
        // Row 7: . . . | 4 1 9 | . . 5
        data[7 * 9 + 3] = 4;
        data[7 * 9 + 4] = 1;
        data[7 * 9 + 5] = 9;
        data[7 * 9 + 8] = 5;
        // Row 8: . . . | . 8 . | . 7 9
        data[8 * 9 + 4] = 8;
        data[8 * 9 + 7] = 7;
        data[8 * 9 + 8] = 9;

        break :blk data;
    };

    const b = try fromFlat(easy, .{});

    // Count givens via bitmask
    var given_count: usize = 0;
    for (0..81) |i| {
        if ((b.given_bits >> @intCast(i)) & 1 == 1) given_count += 1;
    }
    try std.testing.expectEqual(30, given_count);

    // All 81 cells populated correctly (using seam: getCellValue)
    for (0..81) |i| {
        const raw_val = easy[i];
        const row: u4 = @intCast(@divTrunc(i, 9));
        const col: u4 = @intCast(@mod(i, 9));
        const cv = b.getCellValue(row, col);
        if (raw_val != 0) {
            try std.testing.expect((b.given_bits >> @intCast(i)) & 1 == 1);
            try std.testing.expect(cv == cell.rawToCellValue(raw_val));
        } else {
            try std.testing.expect((b.given_bits >> @intCast(i)) & 1 != 1);
            try std.testing.expect(cv == .zero);
        }
    }
}

test "Board: fromOneLineString parses digits and dots correctly" {
    const puzzle_gen = @import("../puzzle_gen.zig");
    const fixture = puzzle_gen.PuzzleGen.default();
    const b = try fromOneLineString(fixture);

    // Sample given positions (taken from fixture)
    const given_specs: []const struct { row: u4, col: u4, expected: cell.CellValue } = &.{
        .{ .row = 0, .col = 0, .expected = .six },
        .{ .row = 0, .col = 1, .expected = .seven },
        .{ .row = 2, .col = 4, .expected = .eight },
        .{ .row = 3, .col = 5, .expected = .two },
        .{ .row = 7, .col = 0, .expected = .five },
        .{ .row = 8, .col = 6, .expected = .three },
    };
    for (given_specs) |spec| {
        try std.testing.expect(b.isGiven(spec.row, spec.col));
        try std.testing.expectEqual(spec.expected, b.getCellValue(spec.row, spec.col));
    }

    // Total givens = 39 non-dot chars in fixture
    var given_count: usize = 0;
    for (fixture) |ch| {
        if (ch != '.' and ch != '0') given_count += 1;
    }
    try std.testing.expectEqual(39, given_count);

    // Dot positions are non-given and zero via seam
    try std.testing.expect(!b.isGiven(1, 3));
    try std.testing.expectEqual(.zero, b.getCellValue(1, 3));
    try std.testing.expect(!b.isGiven(4, 0));
    try std.testing.expectEqual(.zero, b.getCellValue(4, 0));
}

test "Board: fromFlat rejects out-of-range cell values" {
    var bad: [81]u8 = undefined;
    @memset(&bad, 0);
    bad[5] = 42; // out of range

    try std.testing.expectError(Error.BadCellValue, fromFlat(bad, .{}));
}

test "Board: fromOneLineString rejects wrong length" {
    const tooShort: []const u8 = "67..4";
    try std.testing.expectError(Error.WrongLength, fromOneLineString(tooShort));

    var tooLong: [82]u8 = undefined;
    @memset(&tooLong, '.');
    try std.testing.expectError(Error.WrongLength, fromOneLineString(tooLong[0..]));
}

test "Board: fromOneLineString rejects invalid characters" {
    var bad: [81]u8 = undefined;
    @memset(&bad, '.');
    bad[10] = 'X'; // letter in puzzle string

    try std.testing.expectError(Error.InvalidCharacter, fromOneLineString(bad[0..]));
}

test "Board: toFlat produces [81]u8 matching current cell values" {
    var flat: [board.CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 5;
    flat[12] = 3;
    flat[40] = 7;
    flat[80] = 9;

    var b = try fromFlat(flat, .{});
    const out = toFlat(b);

    for (out, 0..) |v, i| {
        const row: u4 = @intCast(@divTrunc(i, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(i, board.DIMENSION_SIZE));
        const cv = b.getCellValue(row, col);
        if (v == 0) {
            try std.testing.expectEqual(cell.CellValue.zero, cv);
        } else {
            try std.testing.expectEqual(cell.rawToCellValue(v), cv);
        }
    }
}

test "Board: toFlat -> fromFlat round-trip preserves cell values" {
    var flat: [board.CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[3] = 6;
    flat[30] = 2;

    var b = try fromFlat(flat, .{});
    try b.setCell(0, 0, .one);
    try b.setCell(1, 1, .four);
    try b.setCell(8, 8, .nine);

    const out = toFlat(b);
    const r = try fromFlat(out, .{});

    for (0..board.CELL_COUNT) |i| {
        const row: u4 = @intCast(@divTrunc(i, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(i, board.DIMENSION_SIZE));

        try std.testing.expectEqual(b.getCellValue(row, col), r.getCellValue(row, col));
    }
}

test "Board: equal returns true for identical boards" {
    var flat: [board.CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 5;
    flat[12] = 3;
    flat[40] = 7;

    const b1 = try fromFlat(flat, .{});
    const b2 = try fromFlat(flat, .{});

    try std.testing.expect(equal(b1, b2));
}

test "Board: equal returns false when cell values differ" {
    var flat: [board.CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 5;
    flat[12] = 3;

    const b1 = try fromFlat(flat, .{});
    var b2 = try fromFlat(flat, .{});

    // Mutate one cell of b2
    _ = b2.setCell(0, 1, .nine) catch {};

    try std.testing.expect(!equal(b1, b2));
}

test "Board: equal returns false when given_bits differ" {
    var flat: [board.CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 5;

    const b1 = try fromFlat(flat, .{});
    var b2 = try fromFlat(flat, .{});

    // b1 has cell 0 as given (non-zero in flat), b2 does not
    b2.given_bits &= ~@as(u128, 1);

    try std.testing.expect(!equal(b1, b2));
}
