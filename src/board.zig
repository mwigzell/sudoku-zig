const std = @import("std");
const CellValue = @import("board/cell.zig").CellValue;
const Cell = @import("board/cell.zig").Cell;
const rawToCellValue = @import("board/cell.zig").rawToCellValue;
const puzzle_gen = @import("puzzle_gen.zig");
const validator = @import("board/validator.zig");

const conflict = @import("board/conflict.zig");

pub const Error = error{
    /// A cell value outside the 0–9 range.
    BadCellValue,
    /// The one-line string is not exactly 81 characters.
    WrongLength,
    /// An unrecognised character appeared in the one-line string.
    InvalidCharacter,
    /// Attempted to modify a puzzle clue cell.
    IsGiven,
    /// Upward coercion catch-all for any future fallible ops (I/O, alloc).
    System,
};
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
    conflict_bits: u128, // bit-per-cell mask of cells with duplicates
    digit_bits: [BoxCellCount]u32, // bitmask per box; bit k=0..8 -> digit D(k)=1..9

    /// Read-only borrowed lens over Board flat storage.
    pub const BoardView = struct {
        _board: *const Board,

        /// Return the value at (row, col).
        pub fn get(self: BoardView, row: u4, col: u4) CellValue {
            return self._board.getCellValue(row, col);
        }

        /// Is this cell a puzzle clue (immutable)?
        pub fn isGiven(self: BoardView, row: u4, col: u4) bool {
            return self._board.isGiven(row, col);
        }

        /// Is this cell flagged in conflict?
        pub fn isConflictingRowCol(self: BoardView, row: u4, col: u4) bool {
            const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
            return self._board.isConflicting(idx);
        }

        /// Bulk resolve against flat storage by index list.
        pub fn resolve(self: BoardView, indices: []const usize) [9]CellValue {
            var vals: [9]CellValue = undefined;
            for (indices, 0..) |idx, i| {
                vals[i] = self._board.cells[idx].value;
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

    /// Vertical column lens — carries strided flat-storage indices for one column.
    pub const ColView = struct {
        colNum: u4,
        indices: [9]usize,

        fn getValues(self: ColView, bv: BoardView) [9]CellValue {
            return bv.resolve(&self.indices);
        }
    };

    /// 3x3 box lens — carries scattered flat-storage indices for one box.
    pub const BoxView = struct {
        boxRow: u2,
        boxCol: u2,
        indices: [9]usize,

        fn getValues(self: BoxView, bv: BoardView) [9]CellValue {
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
        b.conflict_bits = 0;
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
    pub fn updateDigitBits(self: *Board, row: u4, col: u4, old_val: CellValue, new_val: CellValue) void {
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

    /// Is this cell flagged in conflict with another cell?
    pub fn isConflicting(self: Board, idx: usize) bool {
        return ((self.conflict_bits >> @intCast(idx)) & 1) == 1;
    }

    /// Mark cell at flat index `idx` as conflicting.
    pub fn setConflictBit(self: *Board, idx: usize) void {
        self.conflict_bits |= @as(u128, 1) << @intCast(idx);
    }

    /// Clear all conflict bits (called before re-validation).
    pub fn clearConflicts(self: *Board) void {
        self.conflict_bits = 0;
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

    /// Return a ColView for column n (0..8).
    pub fn asCol(n: u4) ColView {
        var cv = ColView{
            .colNum = n,
            .indices = undefined,
        };
        const offset: usize = @intCast(n);
        for (0..9) |i| {
            cv.indices[i] = offset + @as(usize, @intCast(i)) * DIMENSION_SIZE;
        }
        return cv;
    }

    /// Return a BoxView for the 3x3 box at (box_row, box_col).
    pub fn asBox(br: u2, bc: u2) BoxView {
        var xv = BoxView{
            .boxRow = br,
            .boxCol = bc,
            .indices = undefined,
        };
        var ci: usize = 0;
        for (0..BOX_DIMENSION) |r| {
            for (0..BOX_DIMENSION) |c| {
                const row: usize = @as(usize, br) * BOX_DIMENSION + r;
                const col: usize = @as(usize, bc) * BOX_DIMENSION + c;
                xv.indices[ci] = row * DIMENSION_SIZE + col;
                ci += 1;
            }
        }
        return xv;
    }

    /// Return a borrowed read-only view of this board's cells.
    pub fn asView(self: *const Board) BoardView {
        return BoardView{ ._board = self };
    }

    /// Serialize current cell values to a flat [81]u8 array for saving.
    /// Each element is the raw digit: 0 for empty, 1-9 for filled.
    pub fn toFlat(self: Board) [CELL_COUNT]u8 {
        var flat: [CELL_COUNT]u8 = undefined;
        for (self.cells, 0..) |cell, i| {
            flat[i] = @as(u8, @intFromEnum(cell.value));
        }
        return flat;
    }

    /// Compare two boards: same cell values and given_bits.
    pub fn equal(self: Board, other: Board) bool {
        if (self.given_bits != other.given_bits) return false;
        for (self.cells, other.cells, 0..) |c1, c2, i| {
            _ = i;
            if (c1.value != c2.value) return false;
        }
        return true;
    }

    /// Set the value at (row, col). Returns error.IsGiven if the cell is a puzzle clue.
    pub fn setCell(self: *Board, row: u4, col: u4, val: CellValue) Error!void {
        if (self.isGiven(row, col)) return error.IsGiven;
        const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
        const old_val = self.cells[idx].value;
        self.cells[idx].value = val;
        self.updateDigitBits(row, col, old_val, val);
    }
    /// Reset a cell at (row, col) to empty and clear its given-bit.
    fn clearCell(self: *Board, row: u4, col: u4) void {
        const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
        const old_val = self.cells[idx].value;
        self.cells[idx].value = .zero;
        self.given_bits &= ~(@as(u128, 1) << @intCast(idx));
        self.updateDigitBits(row, col, old_val, .zero);
    }

    pub fn validate(self: *Board) void {
        conflict.validate(self);
    }

    /// Incremental conflict refresh after mutating cell at (row, col).
    pub fn refreshConflictsForCell(self: *Board, row: u4, col: u4) void {
        conflict.refreshConflictsForCell(self, row, col);
    }
};

const serial = @import("board/serial.zig");

// Backward-compat re-exports (moved to board/serial.zig)
pub const FlatOpts = serial.FlatOpts;
pub const fromFlat = serial.fromFlat;
pub const fromOneLineString = serial.fromOneLineString;

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Board: init produces 81 empty cells and no givens" {
    const b = Board.init();

    for (0..CELL_COUNT) |i| {
        try std.testing.expectEqual(CellValue.zero, b.cells[i].value);
    }
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

    var b = try fromFlat(flat, .{});

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

    const b = try fromFlat(flat, .{});

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

    var b = try fromFlat(flat, .{});

    try std.testing.expect(b.isGiven(0, 5));

    // Attempting to overwrite a given must fail
    try std.testing.expectError(error.IsGiven, b.setCell(0, 5, .nine));

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

    const b = try fromFlat(flat, .{});

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

    var b = try fromFlat(flat, .{});
    try std.testing.expect((b.getBoxDigitBits(0, 1) & (@as(u32, 1) << (@intFromEnum(CellValue.five) - 1))) != 0);

    // Clear it — clearCell resets value AND clears the given bit; must also strip digit bit
    b.clearCell(0, 3);
    try std.testing.expectEqual(@as(u32, 0), b.getBoxDigitBits(0, 1));
}

test "Board.BoardView.resolve() resolves same values as getCellValue" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 5; // A1 (row 0, col 0) = 5
    flat[1] = 6; // A2 (row 0, col 1) = 6
    flat[9 + 4] = 3; // J5 (row 1, col 4) = 3

    var b = try fromFlat(flat, .{});
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
    try std.testing.expectEqual(CellValue.five, vals[0]); // flat[0] has value 5
    try std.testing.expectEqual(CellValue.six, vals[1]); // flat[1] has value 6
    try std.testing.expectEqual(CellValue.zero, vals[2]); // empty cell in row 0

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

    var b = try fromFlat(flat, .{});
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

test "Board: asCol produces strided indices for column n" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0 * 9 + 4] = 7; // row 0, col 4 = seven
    flat[2 * 9 + 4] = 3; // row 2, col 4 = three
    flat[5 * 9 + 4] = 1; // row 5, col 4 = one

    var b = try fromFlat(flat, .{});
    const view = b.asView();
    const col = Board.asCol(4);

    // Identity field
    try std.testing.expectEqual(@as(u4, 4), col.colNum);

    // Strided indices: offset = col index, stride = CELL_COUNT -> {4, 13, 22, 31, 40, 49, 58, 67, 76}
    const expected_indices: [9]usize = .{ 4, 13, 22, 31, 40, 49, 58, 67, 76 };
    for (col.indices, expected_indices, 0..) |got, expected, i| {
        _ = i;
        try std.testing.expectEqual(expected, got);
    }

    // Resolution through BoardView: column 4 values [7, 0, 3, 0, 0, 1, 0, 0, 0]
    const vals = col.getValues(view);
    try std.testing.expectEqual(CellValue.seven, vals[0]);
    try std.testing.expectEqual(CellValue.zero, vals[1]);
    try std.testing.expectEqual(CellValue.three, vals[2]);
    for (3..5) |i| {
        try std.testing.expectEqual(CellValue.zero, vals[i]);
    }
    try std.testing.expectEqual(CellValue.one, vals[5]);
    for (6..9) |i| {
        try std.testing.expectEqual(CellValue.zero, vals[i]);
    }
}

test "Board: asBox(0, 1) produces correct scattered indices for top-middle box" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    // Top-middle box covers rows 0..2 × cols 3..5 (indices 3,4,5 / 12,13,14 / 21,22,23)
    flat[0 * 9 + 4] = 6; // row 0, col 4 = six
    flat[1 * 9 + 3] = 2; // row 1, col 3 = two
    flat[1 * 9 + 5] = 8; // row 1, col 5 = eight
    flat[2 * 9 + 3] = 4; // row 2, col 3 = four

    var b = try fromFlat(flat, .{});
    const view = b.asView();
    const box = Board.asBox(0, 1);

    // Identity fields
    try std.testing.expectEqual(@as(u2, 0), box.boxRow);
    try std.testing.expectEqual(@as(u2, 1), box.boxCol);

    // Scattered indices: rows 0..2 × cols 3..5 -> {3,4,5,12,13,14,21,22,23}
    const expected_indices: [9]usize = .{ 3, 4, 5, 12, 13, 14, 21, 22, 23 };
    for (box.indices, expected_indices, 0..) |got, expected, i| {
        _ = i;
        try std.testing.expectEqual(expected, got);
    }

    // Resolution through BoardView: [0,6,0, 2,0,8, 4,0,0]
    const vals = box.getValues(view);
    try std.testing.expectEqual(CellValue.zero, vals[0]); // (0,3)
    try std.testing.expectEqual(CellValue.six, vals[1]); // (0,4)
    try std.testing.expectEqual(CellValue.zero, vals[2]); // (0,5)
    try std.testing.expectEqual(CellValue.two, vals[3]); // (1,3)
    try std.testing.expectEqual(CellValue.zero, vals[4]); // (1,4)
    try std.testing.expectEqual(CellValue.eight, vals[5]); // (1,5)
    try std.testing.expectEqual(CellValue.four, vals[6]); // (2,3)
    try std.testing.expectEqual(CellValue.zero, vals[7]); // (2,4)
    try std.testing.expectEqual(CellValue.zero, vals[8]); // (2,5)
}

test "Board: BoardView reflects mutation on reborrow" {
    var b = Board.init();

    // Place a value — setCell (non-given cell)
    try b.setCell(3, 4, .five);

    // Capture view before mutation
    const v1 = b.asView();
    try std.testing.expectEqual(CellValue.five, v1.get(3, 4));
    try std.testing.expect(!v1.isGiven(3, 4));

    // Mutate: overwrite the cell with a different value
    try b.setCell(3, 4, .nine);
    // Clear another cell first to have something non-zero then zeroed
    try b.setCell(7, 0, .three);
    b.clearCell(7, 0);

    // Fresh view after mutation sees updated state
    const v2 = b.asView();
    try std.testing.expectEqual(CellValue.nine, v2.get(3, 4));
    try std.testing.expect(!v2.isGiven(3, 4));

    // Cleared cell is zero on fresh view
    try std.testing.expectEqual(CellValue.zero, v2.get(7, 0));
    try std.testing.expect(!v2.isGiven(7, 0));
}
