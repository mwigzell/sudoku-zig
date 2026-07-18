const std = @import("std");
const CellValue = @import("cell.zig").CellValue;
const Cell = @import("cell.zig").Cell;
const rawToCellValue = @import("cell.zig").rawToCellValue;
const renderer = @import("renderer.zig");
const puzzle_gen = @import("puzzle_gen.zig");

pub const DIMENSION_SIZE: u8 = 9;
pub const CELL_COUNT = DIMENSION_SIZE * DIMENSION_SIZE;
// Box dimension: a standard Sudoku box is 3x3.
pub const BOX_DIMENSION: u4 = 3;
// Cells per box = 9.
pub const BoxCellCount = BOX_DIMENSION * BOX_DIMENSION;

/// The canonical 9×9 Sudoku board state, backed by flat storage + a given-bitmask.
pub const Board = struct {
    cells: [CELL_COUNT]Cell,
    given_bits: u128, // bit-per-cell mask of immutable puzzle clues
    digit_bits: [BoxCellCount]u32, // bitmask per box; bit k=0..8 -> digit D(k)=1..9

    /// Read-only borrowed lens over Board flat storage.
    pub const BoardView = struct {
        board: *const Board,

        /// Return the value at (row, col).
        pub fn get(self: BoardView, row: u4, col: u4) CellValue {
            return self.board.getCellValue(row, col);
        }

        /// Is this cell a puzzle clue (immutable)?
        pub fn isGiven(self: BoardView, row: u4, col: u4) bool {
            return self.board.isGiven(row, col);
        }

        /// Bulk resolve against flat storage by index list.
        pub fn resolve(self: BoardView, indices: []const usize) [9]CellValue {
            var vals: [9]CellValue = undefined;
            for (indices, 0..) |idx, i| {
                vals[i] = self.board.cells[idx].value;
            }
            return vals;
        }
    };

    /// Horizontal row lens — carries contiguous flat-storage indices for one row.
    pub const RowView = struct {
        rowNum: u4,
        indices: [9]usize,

        fn getValues(self: RowView, bv: BoardView) [9]CellValue {
            return bv.resolve(&self.indices);
        }
    };

    /// Create an empty Board (all zeros, no givens).
    pub fn init() Board {
        var b: Board = undefined;
        for (0..CELL_COUNT) |i| {
            b.cells[i] = Cell.init(.zero);
        }
        b.given_bits = 0;
        @memset(&b.digit_bits, 0);
        return b;
    }

    /// Read-only accessor for the raw digit-bitmask of a box at (box_row, box_col).
    pub fn getBoxDigitBits(self: Board, box_row: u2, box_col: u2) u32 {
        const box_idx: usize = @as(usize, @intCast(box_row)) * BOX_DIMENSION + @as(usize, @intCast(box_col));
        return self.digit_bits[box_idx];
    }

    /// Returns bit mask (1 << (digit - 1)) for a CellValue (skip .zero).
    fn digitToBit(val: CellValue) u32 {
        return if (val == .zero) 0 else @as(u32, 1) << @intCast(@intFromEnum(val) - 1);
    }

    /// Return the box index (0..8) for a cell at (row, col).
    fn cellToBoxIndex(row: u4, col: u4) u4 {
        return @as(u4, @intCast(@divTrunc(@as(usize, @intCast(row)), BOX_DIMENSION))) * BOX_DIMENSION +
            @as(u4, @intCast(@divTrunc(@as(usize, @intCast(col)), BOX_DIMENSION)));
    }

    /// Update the digit-bitmask for the box containing cell at (row, col).
    /// Remove bit for `old_val`, add bit for `new_val`. Idempotent when old==new.
    fn updateDigitBits(self: *Board, row: u4, col: u4, old_val: CellValue, new_val: CellValue) void {
        const box_idx: usize = @intCast(Board.cellToBoxIndex(row, col));
        const old_bit = Board.digitToBit(old_val);
        const new_bit = Board.digitToBit(new_val);
        if (old_bit != 0) self.digit_bits[box_idx] &= ~old_bit;
        if (new_bit != 0) self.digit_bits[box_idx] |= new_bit;
    }

    /// Return the value at (row, col).
    pub fn getCellValue(self: Board, row: u4, col: u4) CellValue {
        const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
        return self.cells[idx].value;
    }

    /// Is this cell a puzzle clue (immutable)?
    pub fn isGiven(self: Board, row: u4, col: u4) bool {
        const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
        return ((self.given_bits >> @intCast(idx)) & 1) == 1;
    }

    /// Return a RowView for row n (0..8).

    /// Create a borrowed read-only view of this board's cells.
    pub fn asRow(n: u4) RowView {
        var rv = RowView{
            .rowNum = n,
            .indices = undefined,
        };
        const base: usize = @as(usize, @intCast(n)) * DIMENSION_SIZE;
        for (0..9) |i| {
            rv.indices[i] = base + i;
        }
        return rv;
    }

    /// Return a borrowed read-only view of this board's cells.
    pub fn asView(self: *Board) BoardView {
        return BoardView{ .board = self };
    }

    /// Set the value at (row, col). Returns error.NotGiven if the cell is a puzzle clue.
    pub fn setCell(self: *Board, row: u4, col: u4, val: CellValue) !void {
        if (self.isGiven(row, col)) return error.NotGiven;
        const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
        const old_val = self.cells[idx].value;
        self.cells[idx].value = val;
        self.updateDigitBits(row, col, old_val, val);
    }
    /// Reset a cell at (row, col) to empty and clear its given-bit.
    pub fn clearCell(self: *Board, row: u4, col: u4) void {
        const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
        const old_val = self.cells[idx].value;
        self.cells[idx].value = .zero;
        self.given_bits &= ~(@as(u128, 1) << @intCast(idx));
        self.updateDigitBits(row, col, old_val, .zero);
    }

    /// Walk the flat cells and produce a render-ready snapshot.
    pub fn assembleRenderSnapshot(self: Board) renderer.RenderSnapshot {
        var snap: renderer.RenderSnapshot = undefined;
        for (0..DIMENSION_SIZE) |row| {
            for (0..DIMENSION_SIZE) |col| {
                const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
                snap.cells[row][col] = renderer.RenderCell{
                    .value = self.cells[idx].value,
                    .locked = self.isGiven(@intCast(row), @intCast(col)),
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
/// Values 0 mean empty; values 1–9 are given digits and set their bit in given_bits.
pub fn fromFlat(flat: [81]u8) BoardError!Board {
    for (flat) |v| {
        if (v > 9) return BoardError.BadCellValue;
    }

    var b = Board.init();
    var mask: u128 = 0;
    for (flat, 0..) |v, i| {
        b.cells[i] = Cell.init(rawToCellValue(v));
        if (v != 0) {
            mask |= @as(u128, 1) << @intCast(i);
            const row: u4 = @intCast(@divTrunc(i, DIMENSION_SIZE));
            const col: u4 = @intCast(@mod(i, DIMENSION_SIZE));
            b.updateDigitBits(row, col, .zero, rawToCellValue(v));
        }
    }
    b.given_bits = mask;
    return b;
}

/// Construct a Board from a one-line Sudoku string like "53..7........6.....98..".
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

test "Board: init produces 81 empty cells and no givens" {
    const b = Board.init();

    for (0..CELL_COUNT) |i| {
        try std.testing.expectEqual(CellValue.zero, b.cells[i].value);
    }
}

test "Board: assembleRenderSnapshot on an empty board yields all-zeroes snapshot" {
    var b = Board.init();

    const snap = b.assembleRenderSnapshot();

    for (0..9) |row| {
        for (0..9) |col| {
            try std.testing.expectEqual(CellValue.zero, snap.cells[row][col].value);
            try std.testing.expect(!snap.cells[row][col].locked);
            try std.testing.expect(!snap.cells[row][col].conflicting);
        }
    }
}

test "Board: assembleRenderSnapshot reflects givens populated by fromFlat" {
    var flat: [81]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 6; // A1
    flat[1] = 7; // B1
    flat[4] = 5; // E1

    var b = try fromFlat(flat);
    const snap = b.assembleRenderSnapshot();

    // Given cells present in snapshot
    try std.testing.expectEqual(CellValue.six, snap.cells[0][0].value);
    try std.testing.expect(snap.cells[0][0].locked);
    try std.testing.expectEqual(CellValue.seven, snap.cells[0][1].value);
    try std.testing.expect(snap.cells[0][1].locked);
    try std.testing.expectEqual(CellValue.five, snap.cells[0][4].value);
    try std.testing.expect(snap.cells[0][4].locked);

    // All other cells empty and unlocked
    try std.testing.expectEqual(CellValue.zero, snap.cells[0][2].value);
    try std.testing.expect(!snap.cells[0][2].locked);
    try std.testing.expectEqual(CellValue.zero, snap.cells[8][8].value);
    try std.testing.expect(!snap.cells[8][8].locked);

    // Snap is a copy — mutating Board after capture doesn't affect it
    try b.setCell(0, 2, .one);
    try std.testing.expectEqual(CellValue.zero, snap.cells[0][2].value);
    try std.testing.expectEqual(CellValue.five, snap.cells[0][4].value);
}

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

    const b = try fromFlat(easy);

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
        const c = b.getCellValue(row, col);
        if (raw_val != 0) {
            try std.testing.expect((b.given_bits >> @intCast(i)) & 1 == 1);
            try std.testing.expect(c == rawToCellValue(raw_val));
        } else {
            try std.testing.expect((b.given_bits >> @intCast(i)) & 1 != 1);
            try std.testing.expect(c == .zero);
        }
    }
}

test "Board: fromOneLineString parses digits and dots correctly" {
    const fixture = puzzle_gen.PuzzleGen.default();
    const b = try fromOneLineString(fixture);

    // Sample given positions (taken from fixture)
    const given_specs: []const struct { row: u4, col: u4, expected: CellValue } = &.{
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

    try std.testing.expectError(BoardError.BadCellValue, fromFlat(bad));
}

test "Board: fromOneLineString rejects wrong length" {
    const tooShort: []const u8 = "67..4";
    try std.testing.expectError(BoardError.WrongLength, fromOneLineString(tooShort));

    var tooLong: [82]u8 = undefined;
    @memset(&tooLong, '.');
    try std.testing.expectError(BoardError.WrongLength, fromOneLineString(tooLong[0..]));
}

test "Board: fromOneLineString rejects invalid characters" {
    var bad: [81]u8 = undefined;
    @memset(&bad, '.');
    bad[10] = 'X'; // letter in puzzle string

    try std.testing.expectError(BoardError.InvalidCharacter, fromOneLineString(bad[0..]));
}

test "Board: setCell places a digit on an empty cell" {
    var b = Board.init();

    // Set a cell to value 3 at row 0, col 2
    try b.setCell(0, 2, .three);

    try std.testing.expectEqual(.three, b.getCellValue(0, 2));
}

test "Board: clearCell resets value and clears given bit" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[10] = 7; // row 1, col 1 — index 10

    var b = try fromFlat(flat);

    try std.testing.expectEqual(.seven, b.getCellValue(1, 1));
    try std.testing.expect(b.isGiven(1, 1));

    // Clear it — both value AND given bit must be reset
    b.clearCell(1, 1);

    try std.testing.expectEqual(.zero, b.getCellValue(1, 1));
    try std.testing.expect(!b.isGiven(1, 1));
}

test "Board: fromFlat derives given bits dynamically per cell" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[5] = 6; // row 0, col 5
    flat[67] = 3; // row 7, col 4

    const b = try fromFlat(flat);

    // Every cell's given flag must match its data: non-zero → bit set, zero → clear
    for (flat, 0..) |v, i| {
        const expected_bit_set = v != 0;
        const bit_set = ((b.given_bits >> @intCast(i)) & 1) == 1;
        try std.testing.expectEqual(expected_bit_set, bit_set);
    }

    // Values also correct at known positions via seam
    try std.testing.expectEqual(CellValue.six, b.getCellValue(0, 5));
    try std.testing.expectEqual(CellValue.three, b.getCellValue(7, 4));
}

test "Board: setCell errors when modifying a given cell" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[5] = 6; // row 0, col 5 is a given

    var b = try fromFlat(flat);

    try std.testing.expect(b.isGiven(0, 5));

    // Attempting to overwrite a given must fail
    try std.testing.expectError(error.NotGiven, b.setCell(0, 5, .nine));

    // The given cell's value is unchanged, read via seam
    try std.testing.expectEqual(CellValue.six, b.getCellValue(0, 5));
}

test "Board: init sets all box digit bitmasks to zero" {
    const b = Board.init();
    for (0..BoxCellCount) |box_idx| {
        try std.testing.expectEqual(@as(u32, 0), b.digit_bits[box_idx]);
    }
}

test "Board: fromFlat initializes digit_bits for given cells" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    // All in box 0 (rows 0..2, cols 0..2)
    flat[1] = 3; // row 0, col 1 -> digit bit 2 set
    flat[11] = 7; // row 1, col 2 -> digit bit 6 set

    const b = try fromFlat(flat);

    // Box 0 should have bits for digits 3 and 7 set
    const box0_bits = b.getBoxDigitBits(0, 0);
    try std.testing.expect((box0_bits & (@as(u32, 1) << (@intFromEnum(CellValue.three) - 1))) != 0);
    try std.testing.expect((box0_bits & (@as(u32, 1) << (@intFromEnum(CellValue.seven) - 1))) != 0);
    // No other bits set in box 0
    try std.testing.expectEqual(@as(u32, (1 << (@intFromEnum(CellValue.three) - 1)) |
        (1 << (@intFromEnum(CellValue.seven) - 1))), box0_bits);

    // All other boxes should be zero
    for (0..BoxCellCount) |box_idx| {
        const br: u2 = @intCast(box_idx / BOX_DIMENSION);
        const bc: u2 = @intCast(box_idx % BOX_DIMENSION);
        if (br != 0 or bc != 0) {
            try std.testing.expectEqual(@as(u32, 0), b.getBoxDigitBits(br, bc));
        }
    }
}

test "Board: setCell updates box digit bitmask when changing a value" {
    var b = Board.init();

    // Place digit 3 in a cell inside box 0
    try b.setCell(0, 1, .three);
    try std.testing.expect((b.getBoxDigitBits(0, 0) & (@as(u32, 1) << (@intFromEnum(CellValue.three) - 1))) != 0);

    // Change the same cell to digit 7 — bit 3 should disappear, bit 7 appear
    try b.setCell(0, 1, .seven);
    const box0_bits = b.getBoxDigitBits(0, 0);
    try std.testing.expect((box0_bits & (@as(u32, 1) << (@intFromEnum(CellValue.three) - 1))) == 0); // three gone
    try std.testing.expect((box0_bits & (@as(u32, 1) << (@intFromEnum(CellValue.seven) - 1))) != 0); // seven present
}

test "Board: clearCell clears the digit bit from the owning box" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[3] = 5; // row 0, col 3 -> inside box 1

    var b = try fromFlat(flat);
    try std.testing.expect((b.getBoxDigitBits(0, 1) & (@as(u32, 1) << (@intFromEnum(CellValue.five) - 1))) != 0);

    // Clear it — clearCell resets value AND clears the given bit; must also strip digit bit
    b.clearCell(0, 3);
    try std.testing.expectEqual(@as(u32, 0), b.getBoxDigitBits(0, 1));
}

test "Board.BoardView.resolve() resolves same values as getCellValue" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 5;  // A1 (row 0, col 0) = 5
    flat[1] = 6;  // A2 (row 0, col 1) = 6
    flat[9 + 4] = 3; // J5 (row 1, col 4) = 3

    var b = try fromFlat(flat);
    const view = b.asView();

    // Point resolution through Board.BoardView delegates to Board's own seam
    try std.testing.expectEqual(CellValue.five, view.get(0, 0));
    try std.testing.expectEqual(CellValue.three, view.get(1, 4));
    try std.testing.expectEqual(CellValue.zero, view.get(8, 8));

    // isGiven consistency: same as Board.isGiven(row, col)
    try std.testing.expect(view.isGiven(0, 0));
    try std.testing.expect(!view.isGiven(1, 5));

    // Bulk resolve row 0 indices against flat storage -> matches individual gets
    const row_0_indices: [9]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const vals = view.resolve(&row_0_indices);
    try std.testing.expectEqual(CellValue.five, vals[0]);   // flat[0] has value 5
    try std.testing.expectEqual(CellValue.six, vals[1]);    // flat[1] has value 6
    try std.testing.expectEqual(CellValue.zero, vals[2]);   // empty cell in row 0

    // Bulk resolve matches individual get() calls for every position in the range
    for (vals, 0..) |val, i| {
        const col: u4 = @intCast(i);
        try std.testing.expectEqual(val, view.get(0, col));
    }
}

test "Board: asRow produces contiguous indices for row n" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[2 * 9 + 1] = 9; // row 2, col 1 = nine
    flat[2 * 9 + 2] = 8; // row 2, col 2 = eight

    var b = try fromFlat(flat);
    const view = b.asView();
    const row = Board.asRow(2);

    // Identity field
    try std.testing.expectEqual(@as(u4, 2), row.rowNum);

    // Contiguous indices: base = n * CELL_COUNT -> {18, 19, ..., 26}
    const expected_indices: [9]usize = .{ 18, 19, 20, 21, 22, 23, 24, 25, 26 };
    for (row.indices, expected_indices, 0..) |got, expected, i| {
        _ = i;
        try std.testing.expectEqual(expected, got);
    }

    // Resolution through BoardView: row 2 values [0, 9, 8, 0, 0, 0, 0, 0, 0]
    const vals = row.getValues(view);
    try std.testing.expectEqual(CellValue.zero, vals[0]);
    try std.testing.expectEqual(CellValue.nine, vals[1]);
    try std.testing.expectEqual(CellValue.eight, vals[2]);
    for (3..9) |i| {
        try std.testing.expectEqual(CellValue.zero, vals[i]);
    }
}
