// Reference: conflict detection API for sudoku (copy/adapt into ~/Dev/src/sudoku).
// Validator never imports Board. Board imports Validator.
//
// Two checks only:
//   1. Whole board  — Validator.detectConflicts, Board.flagConflicts
//   2. One cell     — Validator.detectConflictsForCell, Board.refreshConflictsForCell

const std = @import("std");

pub const CELL_COUNT: usize = 81;
pub const GRID_SIZE: u8 = 9;
pub const BOX_COUNT: u8 = 9;

pub const Cell = struct {
    value: u4, // 0 = empty, 1..9 = digit
    given: bool,
};

// =============================================================================
// validator.zig — no Board import
// =============================================================================

pub const Validator = struct {
    /// Whole-board conflict bitmask. Bit i set iff cell i is in a duplicate row/col/box.
    pub fn detectConflicts(cells: []const Cell) u128 {
        std.debug.assert(cells.len == CELL_COUNT);
        var bits: u128 = 0;
        var row: u8 = 0;
        while (row < GRID_SIZE) : (row += 1) {
            bits |= detectRowConflicts(cells, row);
        }
        var col: u8 = 0;
        while (col < GRID_SIZE) : (col += 1) {
            bits |= detectColConflicts(cells, col);
        }
        var box: u8 = 0;
        while (box < BOX_COUNT) : (box += 1) {
            bits |= detectBoxConflicts(cells, box);
        }
        return bits;
    }

    /// Conflict bitmask for the row, column, and box containing (row, col) only.
    /// Other cells in the returned mask are always 0. Use with Board.refreshConflictsForCell.
    pub fn detectConflictsForCell(cells: []const Cell, row: u8, col: u8) u128 {
        std.debug.assert(cells.len == CELL_COUNT);
        std.debug.assert(row < GRID_SIZE and col < GRID_SIZE);
        const box = boxIndex(row, col);
        return detectRowConflicts(cells, row)
            | detectColConflicts(cells, col)
            | detectBoxConflicts(cells, box);
    }

    fn detectRowConflicts(cells: []const Cell, row: u8) u128 {
        var counts: [10]u8 = .{0} ** 10;
        const base = @as(usize, row) * GRID_SIZE;

        var col: u8 = 0;
        while (col < GRID_SIZE) : (col += 1) {
            const v = cells[base + col].value;
            if (v != 0) counts[v] += 1;
        }

        var bits: u128 = 0;
        col = 0;
        while (col < GRID_SIZE) : (col += 1) {
            const idx = base + col;
            const v = cells[idx].value;
            if (v != 0 and counts[v] > 1) {
                bits |= bitMask(@intCast(idx));
            }
        }
        return bits;
    }

    fn detectColConflicts(cells: []const Cell, col: u8) u128 {
        var counts: [10]u8 = .{0} ** 10;

        var row: u8 = 0;
        while (row < GRID_SIZE) : (row += 1) {
            const v = cells[index(row, col)].value;
            if (v != 0) counts[v] += 1;
        }

        var bits: u128 = 0;
        row = 0;
        while (row < GRID_SIZE) : (row += 1) {
            const idx = index(row, col);
            const v = cells[idx].value;
            if (v != 0 and counts[v] > 1) {
                bits |= bitMask(@intCast(idx));
            }
        }
        return bits;
    }

    fn detectBoxConflicts(cells: []const Cell, box: u8) u128 {
        std.debug.assert(box < BOX_COUNT);
        var counts: [10]u8 = .{0} ** 10;

        var lr: u8 = 0;
        while (lr < 3) : (lr += 1) {
            var lc: u8 = 0;
            while (lc < 3) : (lc += 1) {
                const row = boxOriginRow(box) + lr;
                const col = boxOriginCol(box) + lc;
                const v = cells[index(row, col)].value;
                if (v != 0) counts[v] += 1;
            }
        }

        var bits: u128 = 0;
        lr = 0;
        while (lr < 3) : (lr += 1) {
            var lc: u8 = 0;
            while (lc < 3) : (lc += 1) {
                const row = boxOriginRow(box) + lr;
                const col = boxOriginCol(box) + lc;
                const idx = index(row, col);
                const v = cells[idx].value;
                if (v != 0 and counts[v] > 1) {
                    bits |= bitMask(@intCast(idx));
                }
            }
        }
        return bits;
    }

    fn boxIndex(row: u8, col: u8) u8 {
        return (row / 3) * 3 + (col / 3);
    }

    fn boxOriginRow(box: u8) u8 {
        return (box / 3) * 3;
    }

    fn boxOriginCol(box: u8) u8 {
        return (box % 3) * 3;
    }

    fn index(row: u8, col: u8) usize {
        return @as(usize, row) * GRID_SIZE + col;
    }

    fn bitMask(idx: u8) u128 {
        std.debug.assert(idx < CELL_COUNT);
        return @as(u128, 1) << idx;
    }
};

// =============================================================================
// board.zig — imports validator.zig; Validator never imports this
// =============================================================================

pub const Board = struct {
    cells: [CELL_COUNT]Cell,
    given_bits: u128,
    conflict_bits: u128,
    digit_bits: [BOX_COUNT]u32,

    /// Whole-board conflict refresh. Use after bulk load or when generation finishes.
    pub fn flagConflicts(self: *Board) void {
        self.conflict_bits = Validator.detectConflicts(self.cells[0..]);
    }

    /// Incremental conflict refresh after mutating the cell at (row, col).
    pub fn refreshConflictsForCell(self: *Board, row: u8, col: u8) void {
        std.debug.assert(row < GRID_SIZE and col < GRID_SIZE);
        const cells = self.cells[0..];
        self.conflict_bits &= ~unitsMask(row, col);
        self.conflict_bits |= Validator.detectConflictsForCell(cells, row, col);
    }

    fn unitsMask(row: u8, col: u8) u128 {
        return rowMask(row) | colMask(col) | boxMask(boxIndex(row, col));
    }

    fn rowMask(row: u8) u128 {
        var mask: u128 = 0;
        var col: u8 = 0;
        while (col < GRID_SIZE) : (col += 1) {
            mask |= bitMask(@intCast(index(row, col)));
        }
        return mask;
    }

    fn colMask(col: u8) u128 {
        var mask: u128 = 0;
        var row: u8 = 0;
        while (row < GRID_SIZE) : (row += 1) {
            mask |= bitMask(@intCast(index(row, col)));
        }
        return mask;
    }

    fn boxMask(box: u8) u128 {
        var mask: u128 = 0;
        const origin_row = boxOriginRow(box);
        const origin_col = boxOriginCol(box);
        var lr: u8 = 0;
        while (lr < 3) : (lr += 1) {
            var lc: u8 = 0;
            while (lc < 3) : (lc += 1) {
                const row = origin_row + lr;
                const col = origin_col + lc;
                mask |= bitMask(@intCast(index(row, col)));
            }
        }
        return mask;
    }

    fn boxIndex(row: u8, col: u8) u8 {
        return (row / 3) * 3 + (col / 3);
    }

    fn boxOriginRow(box: u8) u8 {
        return (box / 3) * 3;
    }

    fn boxOriginCol(box: u8) u8 {
        return (box % 3) * 3;
    }

    fn index(row: u8, col: u8) u8 {
        return row * GRID_SIZE + col;
    }

    fn bitMask(idx: u8) u128 {
        return @as(u128, 1) << idx;
    }
};

// =============================================================================
// Usage (board.zig)
// =============================================================================
//
// pub fn setCell(self: *Board, row: u8, col: u8, value: u4) !void {
//     // ... mutate self.cells, self.digit_bits ...
//     self.refreshConflictsForCell(row, col);
// }
//
// pub fn loadFromPuzzle(self: *Board, clues: []const u8) !void {
//     // ... fill all self.cells ...
//     self.flagConflicts();
// }
