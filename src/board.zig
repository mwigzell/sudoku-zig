const std = @import("std");
const cell = @import("cell.zig");
const grid = @import("grid.zig");
const default_puzzle = @import("default_puzzle.zig");

/// Board dimension — a standard Sudoku grid is 9×9.
pub const DIMENSION_SIZE: u8 = 9;

/// The canonical 9×9 Sudoku board state, backed by a Grid whose Boxes own Cell data.
pub const Board = struct {
    grid: grid.Grid,

    /// Create an empty Board (all zeros, nothing locked).
    pub fn init() Board {
        return .{ .grid = grid.Grid.init() };
    }
};

/// Errors returned when parsing puzzle data into a Board.
pub const BoardError = error{
    /// A cell value outside the 0–9 range was found.
    BadCellValue,
    /// The one-line string is not exactly 81 characters.
    WrongLength,
    /// An unrecognised character appeared in the one-line string.
    InvalidCharacter,
};

/// Construct a Board from a flat 81-element u8 array.
/// Values 0 mean empty/unlocked; values 1–9 are given digits and locked.
/// Returns an error if any cell value is outside 0–9.
pub fn fromFlat(flat: [81]u8) BoardError!Board {
    for (flat) |v| {
        if (v > 9) return BoardError.BadCellValue;
    }

    var b = Board.init();
    for (flat, 0..) |v, i| {
        const globalRow: u4 = @intCast(@divTrunc(i, 9));
        const globalCol: u4 = @intCast(@mod(i, 9));
        if (v != 0) {
            const ptr = b.grid.cellAt(globalRow, globalCol);
            ptr.value = cell.rawToCellValue(v);
            ptr.locked = true;
        }
    }
    return b;
}

/// Construct a Board from a one-line Sudoku string like "53..7........6.....98..".
/// Digits '1'–'9' are locked givens; '.' or '0' are empty/unlocked.
/// Returns an error if the string is not exactly 81 characters
/// or contains any character outside those ranges.
pub fn fromOneLineString(oneLine: []const u8) BoardError!Board {
    if (oneLine.len != 81) return BoardError.WrongLength;

    var flat: [81]u8 = undefined;
    for (oneLine, 0..) |ch, i| {
        flat[i] = switch (ch) {
            '.' => 0,
            '0' => 0,
            '1'...'9' => ch - '0',
            else => return BoardError.InvalidCharacter,
        };
    }
    return fromFlat(flat);
}

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Board: constructs from flat puzzle array with correct givens and empties" {
    const easy: [81]u8 = blk: {
        // Classic easy Sudoku — pre-filled cells as digits, blanks as 0.
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

    var b = try fromFlat(easy);

    // Total givens: count non-zero in the flat array (independent known-good literal)
    var expected_locked_count: usize = 0;
    for (&easy) |v| {
        if (v != 0) expected_locked_count += 1;
    }
    try std.testing.expectEqual(30, expected_locked_count);

    // All 81 cells populated — accessed through Grid.cellAt() to verify Box ownership path.
    var actual_locked_count: usize = 0;
    for (0..81) |i| {
        const raw_val = easy[i];
        const globalRow: u4 = @intCast(@divTrunc(i, 9));
        const globalCol: u4 = @intCast(@mod(i, 9));
        const c = b.grid.cellAt(globalRow, globalCol).*; // copy of Cell via pointer
        if (raw_val != 0) {
            try std.testing.expect(c.locked);
            actual_locked_count += 1;
            try std.testing.expect(c.value == cell.rawToCellValue(raw_val));
        } else {
            try std.testing.expect(!c.locked);
            try std.testing.expect(c.value == .zero);
        }
    }
    try std.testing.expectEqual(expected_locked_count, actual_locked_count);
}

test "Board: fromOneLineString parses digits and dots into locked/unlocked cells" {
    const fixture = default_puzzle.default_puzzle;
    var b = try fromOneLineString(fixture);

    // Sample locked cells at known positions (taken from fixture above)
    const locked_specs: []const struct { row: u4, col: u4, expected: cell.CellValue } = &.{
        .{ .row = 0,  .col = 0,  .expected = .six },
        .{ .row = 0,  .col = 1,  .expected = .seven },
        .{ .row = 2,  .col = 4,  .expected = .eight },
        .{ .row = 3,  .col = 5,  .expected = .two },
        .{ .row = 7,  .col = 0,  .expected = .five },
        .{ .row = 8,  .col = 6,  .expected = .three },
    };
    for (locked_specs) |spec| {
        const c = b.grid.cellAt(spec.row, spec.col).*;
        try std.testing.expect(c.locked);
        try std.testing.expectEqual(spec.expected, c.value);
    }

    // Total givens: fixture has exactly 39 non-dot characters
    var locked_count: usize = 0;
    for (fixture) |ch| {
        if (ch != '.' and ch != '0') locked_count += 1;
    }
    try std.testing.expectEqual(39, locked_count);

    // Check a few dot positions are unlocked and zero
    const c13 = b.grid.cellAt(1, 3).*;
    try std.testing.expect(!c13.locked);
    try std.testing.expectEqual(.zero, c13.value);

    const c40 = b.grid.cellAt(4, 0).*;
    try std.testing.expect(!c40.locked);
    try std.testing.expectEqual(.zero, c40.value);
}

test "Board: fromFlat rejects out-of-range cell values" {
    var bad: [81]u8 = undefined;
    @memset(&bad, 0);
    bad[5] = 42; // out of range

    try std.testing.expectError(BoardError.BadCellValue, fromFlat(bad));
}

test "Board: fromOneLineString rejects wrong length" {
    const tooShort: []const u8 = "67..4";
    try std.testing.expectError(BoardError.WrongLength, fromOneLineString(tooShort));

    var tooLong: [82]u8 = undefined; // any extra char past 81 -> wrong length
    @memset(&tooLong, '.');
    try std.testing.expectError(BoardError.WrongLength, fromOneLineString(tooLong[0..]));
}

test "Board: fromOneLineString rejects invalid characters" {
    var bad: [81]u8 = undefined;
    @memset(&bad, '.');
    bad[10] = 'X'; // letter in puzzle string

    try std.testing.expectError(BoardError.InvalidCharacter, fromOneLineString(bad[0..]));
}
