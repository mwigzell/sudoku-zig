const std = @import("std");
const CellValue = @import("cell.zig").CellValue;
const Cell = @import("cell.zig").Cell;
const rawToCellValue = @import("cell.zig").rawToCellValue;
const puzzle_gen = @import("puzzle_gen.zig");
const validator = @import("validator.zig");

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


    // ---------------------------------------------------------------------------
    // conflict detection helpers (moved from validator module)
    // ---------------------------------------------------------------------------

    /// Translate scope-relative conflict bits (0..8) to full board flat-storage positions
    /// using the View's index array.
    fn scopeToBoardMask(indices: *align(1) const [9]usize, scope_bits: u128) u128 {
        var result: u128 = 0;
        for (indices, 0..) |board_idx, i| {
            if ((scope_bits & (@as(u128, 1) << @intCast(i))) != 0) {
                result |= @as(u128, 1) << @intCast(board_idx);
            }
        }
        return result;
    }

    /// Build a bitmask of every flat-storage index in the row, column,
    /// and box containing cell at (row, col).
    fn unitsMask(row: u4, col: u4) u128 {
        var mask: u128 = 0;

        // Row cells
        for (0..DIMENSION_SIZE) |c| {
            const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(c));
            mask |= @as(u128, 1) << @intCast(idx);
        }

        // Column cells
        for (0..DIMENSION_SIZE) |r| {
            const idx: usize = @as(usize, @intCast(r)) * DIMENSION_SIZE + @as(usize, @intCast(col));
            mask |= @as(u128, 1) << @intCast(idx);
        }

        // Box cells
        const box_row: usize = @divTrunc(@as(usize, @intCast(row)), BOX_DIMENSION);
        const box_col: usize = @divTrunc(@as(usize, @intCast(col)), BOX_DIMENSION);
        for (0..BOX_DIMENSION) |r| {
            for (0..BOX_DIMENSION) |c| {
                const idx: usize = (box_row * BOX_DIMENSION + r) * DIMENSION_SIZE +
                    box_col * BOX_DIMENSION + c;
                mask |= @as(u128, 1) << @intCast(idx);
            }
        }

        return mask;
    }

    /// Walk every row, column, and box scope and update conflict_bits on the Board.
    pub fn validate(self: *Board) void {
        self.clearConflicts();
        var mask: u128 = 0;

        for (0..DIMENSION_SIZE) |r| {
            const rv = Board.asRow(@intCast(r));
            const scope_bits = validator.Validator.flagScopeConflicts(&self.cells, &rv.indices);
            mask |= Board.scopeToBoardMask(&rv.indices, scope_bits);
        }

        for (0..DIMENSION_SIZE) |c| {
            const cv = Board.asCol(@intCast(c));
            const scope_bits = validator.Validator.flagScopeConflicts(&self.cells, &cv.indices);
            mask |= Board.scopeToBoardMask(&cv.indices, scope_bits);
        }

        for (0..3) |br| {
            for (0..3) |bc| {
                const xv = Board.asBox(@intCast(br), @intCast(bc));
                const scope_bits = validator.Validator.flagScopeConflicts(&self.cells, &xv.indices);
                mask |= Board.scopeToBoardMask(&xv.indices, scope_bits);
            }
        }

        self.conflict_bits = mask;
    }

    /// Incremental conflict refresh after mutating cell at (row, col).
    /// Clears only the affected row+col+box bits and re-detects those 3 scopes.
    pub fn refreshConflictsForCell(self: *Board, row: u4, col: u4) void {
        const umask = Board.unitsMask(row, col);
        self.conflict_bits &= ~umask;

        var new_mask: u128 = 0;

        // Row
        const rv = Board.asRow(row);
        new_mask |= Board.scopeToBoardMask(&rv.indices, validator.Validator.flagScopeConflicts(&self.cells, &rv.indices));

        // Column
        const cv = Board.asCol(col);
        new_mask |= Board.scopeToBoardMask(&cv.indices, validator.Validator.flagScopeConflicts(&self.cells, &cv.indices));

        // Box
        const box_row: u2 = @intCast(@divTrunc(@as(usize, @intCast(row)), BOX_DIMENSION));
        const box_col: u2 = @intCast(@divTrunc(@as(usize, @intCast(col)), BOX_DIMENSION));
        const xv = Board.asBox(box_row, box_col);
        new_mask |= Board.scopeToBoardMask(&xv.indices, validator.Validator.flagScopeConflicts(&self.cells, &xv.indices));

        self.conflict_bits |= new_mask;
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

test "Board: asCol produces strided indices for column n" {
    var flat: [CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0 * 9 + 4] = 7; // row 0, col 4 = seven
    flat[2 * 9 + 4] = 3; // row 2, col 4 = three
    flat[5 * 9 + 4] = 1; // row 5, col 4 = one

    var b = try fromFlat(flat);
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

    var b = try fromFlat(flat);
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
    try std.testing.expectEqual(CellValue.zero, vals[0]);   // (0,3)
    try std.testing.expectEqual(CellValue.six, vals[1]);     // (0,4)
    try std.testing.expectEqual(CellValue.zero, vals[2]);   // (0,5)
    try std.testing.expectEqual(CellValue.two, vals[3]);     // (1,3)
    try std.testing.expectEqual(CellValue.zero, vals[4]);   // (1,4)
    try std.testing.expectEqual(CellValue.eight, vals[5]);  // (1,5)
    try std.testing.expectEqual(CellValue.four, vals[6]);   // (2,3)
    try std.testing.expectEqual(CellValue.zero, vals[7]);   // (2,4)
    try std.testing.expectEqual(CellValue.zero, vals[8]);   // (2,5)
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

test "Board: conflict bits start clear and can be set/cleared individually" {
    var b = Board.init();

    // All cells clear to begin with
    for (0..CELL_COUNT) |i| {
        try std.testing.expect(!b.isConflicting(i));
    }

    // Mark two arbitrary cells as conflicting
    b.setConflictBit(10);  // row 1, col 1
    b.setConflictBit(50);  // row 5, col 5

    try std.testing.expect(b.isConflicting(10));
    try std.testing.expect(b.isConflicting(50));
    try std.testing.expect(!b.isConflicting(0));   // untouched

    // Clear all conflicts
    b.clearConflicts();

    try std.testing.expect(!b.isConflicting(10));
    try std.testing.expect(!b.isConflicting(50));
}

// ---------------------------------------------------------------------------
// Integration tests — validate() and refreshConflictsForCell()
// ---------------------------------------------------------------------------

test "Board: validate flags row duplicates" {
    var b = Board.init();
    try b.setCell(0, 0, .five); // index 0 in row 0
    try b.setCell(0, 5, .five); // index 5 in row 0 — duplicate

    b.validate();

    try std.testing.expect(b.isConflicting(0));
    try std.testing.expect(b.isConflicting(5));
    try std.testing.expect(!b.isConflicting(1)); // not conflicting
}

test "Board: validate flags column duplicates" {
    var b = Board.init();
    try b.setCell(2, 3, .five); // index 21 — row 2 col 3
    try b.setCell(7, 3, .five); // index 66 — row 7 col 3 — duplicate

    b.validate();

    try std.testing.expect(b.isConflicting(21));
    try std.testing.expect(b.isConflicting(66));
}

test "Board: validate flags box-only conflicts" {
    var b = Board.init();
    try b.setCell(0, 1, .three); // index 1 — box (0,0)
    try b.setCell(2, 0, .three); // index 18 — same box (0,0), different row & col

    b.validate();

    try std.testing.expect(b.isConflicting(1));
    try std.testing.expect(b.isConflicting(18));
}

test "Board: validate does not flag cells with no conflicts" {
    var b = Board.init();
    try b.setCell(0, 0, .one);
    try b.setCell(0, 1, .two);
    try b.setCell(1, 0, .three); // different row from index 0, so no row conflict; diff col, so no col conflict

    b.validate();

    for (0..81) |i| {
        try std.testing.expect(!b.isConflicting(@intCast(i)));
    }
}

test "Board: validate flags cell when conflicting in multiple scopes" {
    var b = Board.init();
    try b.setCell(0, 0, .five); // index 0 — row 0, col 0, box (0,0)
    try b.setCell(0, 5, .five); // index 5 — same row 0 → row conflict
    try b.setCell(3, 0, .five); // index 27 → same col 0 → col conflict

    b.validate();

    // Cell 0 is in conflict via BOTH row and column
    try std.testing.expect(b.isConflicting(0));
    try std.testing.expect(b.isConflicting(5));
    try std.testing.expect(b.isConflicting(27));
}

test "Board: refreshConflictsForCell updates only affected scopes" {
    var b = Board.init();
    // Set up conflicts in row 0: five at (0,0) and (0,5)
    try b.setCell(0, 0, .five);
    try b.setCell(0, 5, .five);
    // And a separate conflict in row 4: three at (4,1) and (4,7)
    try b.setCell(4, 1, .three);
    try b.setCell(4, 7, .three);

    b.validate();

    // Both conflict pairs flagged
    try std.testing.expect(b.isConflicting(0));   // (0,0)
    try std.testing.expect(b.isConflicting(5));   // (0,5)
    try std.testing.expect(b.isConflicting(37));  // (4,1)
    try std.testing.expect(b.isConflicting(43));  // (4,7)

    // Now change cell (0,0) from five to one — removes its row conflict with (0,5)
    b.cells[0].value = .one;
    b.refreshConflictsForCell(0, 0);

    // Row-0 conflicts resolved: cells 0 and 5 should no longer be conflicting
    try std.testing.expect(!b.isConflicting(0));
    try std.testing.expect(!b.isConflicting(5));

    // Unrelated row-4 conflict untouched
    try std.testing.expect(b.isConflicting(37));
    try std.testing.expect(b.isConflicting(43));
}

test "Board: refreshConflictsForCell creates new conflict" {
    var b = Board.init();
    // Set up: row 0 has five at (0,3); row 4 has three at (4,1) and (4,7)
    try b.setCell(0, 3, .five);
    try b.setCell(4, 1, .three);
    try b.setCell(4, 7, .three);

    b.validate();

    // Only the row-4 pair is conflicting
    try std.testing.expect(!b.isConflicting(3));  // (0,3) — five, unique in row 0
    try std.testing.expect(b.isConflicting(37));  // (4,1)
    try std.testing.expect(b.isConflicting(43));  // (4,7)

    // Now make (0,5) also five → creates row-0 conflict for both (0,3) and (0,5)
    b.cells[5].value = .five;
    b.refreshConflictsForCell(0, 5);

    // New conflict pair flagged in row 0
    try std.testing.expect(b.isConflicting(3));   // (0,3) now conflicts with (0,5)
    try std.testing.expect(b.isConflicting(5));   // (0,5) conflicts with (0,3)

    // Unrelated row-4 conflict still intact
    try std.testing.expect(b.isConflicting(37));
    try std.testing.expect(b.isConflicting(43));
}

test "Board: refreshConflictsForCell does not touch unrelated cells" {
    var b = Board.init();
    // Conflicts in row 2: eight at (2,0) and (2,5)
    try b.setCell(2, 0, .eight);
    try b.setCell(2, 5, .eight);
    // And a unique cell in row 6 that should never be flagged:
    try b.setCell(6, 3, .one);

    b.validate();

    // Row-2 pair flagged; row-6 cell is clear
    try std.testing.expect(b.isConflicting(18));   // (2,0)
    try std.testing.expect(b.isConflicting(23));   // (2,5)
    try std.testing.expect(!b.isConflicting(59));  // (6,3) — unique

    // Change an unrelated cell in col 7: set (1,7) to nine
    b.cells[16].value = .nine;  // flat index 1*9+7 = 16
    b.refreshConflictsForCell(1, 7);

    // Row-2 conflicts untouched
    try std.testing.expect(b.isConflicting(18));
    try std.testing.expect(b.isConflicting(23));

    // (6,3) still not flagged — refresh on (1,7) doesn't reach row 6 / col 3 / box 5
    try std.testing.expect(!b.isConflicting(59));
}
