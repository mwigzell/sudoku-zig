const std = @import("std");
const cell = @import("cell.zig");
const renderer = @import("renderer.zig");
const puzzle_gen = @import("puzzle_gen.zig");

/// Board dimension — a standard Sudoku grid is 9×9.
pub const DIMENSION_SIZE: u8 = 9;
pub const CELL_COUNT = DIMENSION_SIZE * DIMENSION_SIZE;

/// The canonical 9×9 Sudoku board state, backed by flat [81]Cell storage.
pub const Board = struct {
    cells: [CELL_COUNT]cell.Cell,

    /// Create an empty Board (all zeros, nothing given).
    pub fn init() Board {
        var b: Board = undefined;
        for (0..CELL_COUNT) |i| {
            b.cells[i] = cell.Cell.init(.zero, false);
        }
        return b;
    }

    /// Return a mutable pointer to the Cell at (row, col).
    pub fn cellAt(self: *Board, row: u4, col: u4) *cell.Cell {
        const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
        return &self.cells[idx];
    }

        /// Set the value at (row, col). Does NOT mark the cell as given.
        pub fn setCell(self: *Board, row: u4, col: u4, val: cell.CellValue) void {
            self.cellAt(row, col).value = val;
        }

        /// Reset a cell at (row, col) to empty and strip the given flag.
        pub fn clearCell(self: *Board, row: u4, col: u4) void {
            const c = self.cellAt(row, col);
            c.value = .zero;
            c.given = false;
        }

    /// Walk the flat cells and produce a render-ready snapshot.
    pub fn assembleRenderSnapshot(self: *Board) renderer.RenderSnapshot {
        var snap: renderer.RenderSnapshot = undefined;
        for (0..DIMENSION_SIZE) |row| {
            for (0..DIMENSION_SIZE) |col| {
                const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
                snap.cells[row][col] = renderer.RenderCell{
                    .value = self.cells[idx].value,
                    .locked = self.cells[idx].given,
                    .conflicting = false,
                };
            }
        }
        return snap;
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
/// Values 0 mean empty; values 1–9 are given digits and marked as given.
/// Returns an error if any cell value is outside 0–9.
pub fn fromFlat(flat: [81]u8) BoardError!Board {
    for (flat) |v| {
        if (v > 9) return BoardError.BadCellValue;
    }

    var b = Board.init();
    for (flat, 0..) |v, i| {
        const globalRow: u4 = @intCast(@divTrunc(i, 9));
        const globalCol: u4 = @intCast(@mod(i, 9));
        const c = b.cellAt(globalRow, globalCol);
        c.value = cell.rawToCellValue(v);
        c.given = v != 0;
    }
    return b;
}

/// Construct a Board from a one-line Sudoku string like "53..7........6.....98..".
/// Digits '1'–'9' are given; '.' or '0' are empty.
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

test "Board: init produces 81 empty, non-given cells" {
    const b = Board.init();

    for (0..CELL_COUNT) |i| {
        try std.testing.expectEqual(cell.CellValue.zero, b.cells[i].value);
        try std.testing.expect(!b.cells[i].given);
    }
}

test "Board: assembleRenderSnapshot on an empty board yields all-zeroes snapshot" {
    var b = Board.init();

    const snap = b.assembleRenderSnapshot();

    for (0..9) |row| {
        for (0..9) |col| {
            try std.testing.expectEqual(cell.CellValue.zero, snap.cells[row][col].value);
            try std.testing.expect(!snap.cells[row][col].locked);
            try std.testing.expect(!snap.cells[row][col].conflicting);
        }
    }
}

test "Board: assembleRenderSnapshot reflects given givens populated by fromFlat" {
    var flat: [81]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 6; // A1
    flat[1] = 7; // B1
    flat[4] = 5; // E1 (index 4 = row 0, col 4)

    var b = try fromFlat(flat);
    const snap = b.assembleRenderSnapshot();

    // Given cells present in snapshot
    try std.testing.expectEqual(cell.CellValue.six, snap.cells[0][0].value);
    try std.testing.expect(snap.cells[0][0].locked);
    try std.testing.expectEqual(cell.CellValue.seven, snap.cells[0][1].value);
    try std.testing.expect(snap.cells[0][1].locked);
    try std.testing.expectEqual(cell.CellValue.five, snap.cells[0][4].value);
    try std.testing.expect(snap.cells[0][4].locked);

    // All other cells empty and unlocked
    try std.testing.expectEqual(cell.CellValue.zero, snap.cells[0][2].value);
    try std.testing.expect(!snap.cells[0][2].locked);
    try std.testing.expectEqual(cell.CellValue.zero, snap.cells[8][8].value);
    try std.testing.expect(!snap.cells[8][8].locked);

    // Snap is a copy - mutating Board after capture doesn't affect it
    b.cellAt(0, 4).value = .one;
    try std.testing.expectEqual(cell.CellValue.five, snap.cells[0][4].value);
}

test "Board: constructs from flat puzzle array with correct givens and empties" {
    const easy: [81]u8 = blk: {
        // Classic easy Sudoku - pre-filled cells as digits, blanks as 0.
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

    const b = try fromFlat(easy);

    // Total givens: count non-zero in the flat array (independent known-good literal)
    var expected_given_count: usize = 0;
    for (&easy) |v| {
        if (v != 0) expected_given_count += 1;
    }
    try std.testing.expectEqual(30, expected_given_count);

    // All 81 cells populated - accessed through flat array to verify row-major indexing.
    var actual_given_count: usize = 0;
    for (0..81) |i| {
        const raw_val = easy[i];
        const c = b.cells[i];
        if (raw_val != 0) {
            try std.testing.expect(c.given);
            actual_given_count += 1;
            try std.testing.expect(c.value == cell.rawToCellValue(raw_val));
        } else {
            try std.testing.expect(!c.given);
            try std.testing.expect(c.value == .zero);
        }
    }
    try std.testing.expectEqual(expected_given_count, actual_given_count);
}

test "Board: fromOneLineString parses digits and dots into given/non-given cells" {
    const fixture = puzzle_gen.PuzzleGen.default();
    var b = try fromOneLineString(fixture);

    // Sample given cells at known positions (taken from fixture above)
    const given_specs: []const struct { row: u4, col: u4, expected: cell.CellValue } = &.{
        .{ .row = 0, .col = 0, .expected = .six },
        .{ .row = 0, .col = 1, .expected = .seven },
        .{ .row = 2, .col = 4, .expected = .eight },
        .{ .row = 3, .col = 5, .expected = .two },
        .{ .row = 7, .col = 0, .expected = .five },
        .{ .row = 8, .col = 6, .expected = .three },
    };
    for (given_specs) |spec| {
        const c = b.cellAt(spec.row, spec.col).*;
        try std.testing.expect(c.given);
        try std.testing.expectEqual(spec.expected, c.value);
    }

    // Total givens: fixture has exactly 39 non-dot characters
    var given_count: usize = 0;
    for (fixture) |ch| {
        if (ch != '.' and ch != '0') given_count += 1;
    }
    try std.testing.expectEqual(39, given_count);

    // Check a few dot positions are non-given and zero
    const c13 = b.cellAt(1, 3).*;
    try std.testing.expect(!c13.given);
    try std.testing.expectEqual(.zero, c13.value);

    const c40 = b.cellAt(4, 0).*;
    try std.testing.expect(!c40.given);
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
test "Board: setCell places a digit without marking it given" {
    var b = Board.init();

    // Set a cell to value 3 at row 0, col 2
    b.setCell(0, 2, .three);

    // Value should be set
    try std.testing.expectEqual(.three, b.cells[2].value);

    // But the cell must NOT be marked as given (user entry, not puzzle clue)
    try std.testing.expect(!b.cells[2].given);
}

test "Board: clearCell resets both value and given flag" {
    var b = Board.init();

    // Prime a cell as a given (simulating a puzzle clue)
    const c1 = b.cellAt(1, 1);
    c1.value = .seven;
    c1.given = true;

    try std.testing.expectEqual(.seven, b.cells[10].value);
    try std.testing.expect(b.cells[10].given);

    // Clear it — both value AND given must be reset
    b.clearCell(1, 1);

    try std.testing.expectEqual(.zero, b.cells[10].value);
    try std.testing.expect(!b.cells[10].given);
}


test "Board: fromFlat computes given flag from data for every cell" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[5] = 6;   // row 0, col 5
    flat[67] = 3;  // row 7, col 4

    const b = try fromFlat(flat);

    // Every cell must derive given from its value: non-zero → given, zero → not given
    for (flat, 0..) |v, i| {
        const expected_given = v != 0;
        const c = b.cells[i];
        try std.testing.expectEqual(expected_given, c.given);
    }

    // Values also correct at known positions
    try std.testing.expectEqual(cell.CellValue.six, b.cells[5].value);
    try std.testing.expectEqual(cell.CellValue.three, b.cells[67].value);
}
