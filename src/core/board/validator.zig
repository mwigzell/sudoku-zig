const std = @import("std");
const Cell = @import("cell.zig").Cell;
const board = @import("board.zig");

pub const Validator = struct {
    /// Scan a scope (row/column/box) of 9 cells, given by their board indices, and
    /// return the board cells whose digit repeats within that scope.
    pub fn flagScopeConflicts(cells: []const Cell, indices: []const usize) board.CellMask {
        var counts: [10]u8 = undefined;
        @memset(&counts, 0);
        for (indices) |idx| {
            const digit = cells[idx].value;
            if (digit != .zero) counts[@backingInt(digit)] += 1;
        }
        var result: board.CellMask = 0;
        for (indices) |idx| {
            const digit = cells[idx].value;
            if (digit != .zero and counts[@backingInt(digit)] > 1) {
                result |= board.indexBit(idx);
            }
        }
        return result;
    }
};

// ---------------------------------------------------------------------------
// Tests (co-located)
// ---------------------------------------------------------------------------

test "flagScopeConflicts empty scope all clear" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    const indices: [9]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqual(@as(board.CellMask, 0), Validator.flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts row duplicate at positions 0 and 3" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    cells[0].value = .five;
    cells[3].value = .five;
    const indices: [9]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqual(@as(board.CellMask, (1 << 0) | (1 << 3)), Validator.flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts column duplicate at positions 2 and 7" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    cells[2].value = .three;
    cells[7].value = .three;
    const indices: [9]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqual(@as(board.CellMask, (1 << 2) | (1 << 7)), Validator.flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts box duplicate at positions 1 and 6" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    cells[1].value = .seven;
    cells[6].value = .seven;
    const indices: [9]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqual(@as(board.CellMask, (1 << 1) | (1 << 6)), Validator.flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts unique digits no false positives" {
    const cells: [9]Cell = .{
        Cell.init(.two), // position 0
        Cell.init(.five), // position 1
        Cell.init(.zero), // position 2 — empty
        Cell.init(.one), // position 3
        Cell.init(.nine), // position 4
        Cell.init(.three), // position 5
        Cell.init(.zero), // position 6 — empty
        Cell.init(.seven), // position 7
        Cell.init(.four), // position 8
    };
    const indices: [9]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqual(@as(board.CellMask, 0), Validator.flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts three-of-a-kind all three flagged" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    cells[1].value = .four;
    cells[4].value = .four;
    cells[7].value = .four;
    const indices: [9]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectEqual(@as(board.CellMask, (1 << 1) | (1 << 4) | (1 << 7)), Validator.flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts marks the board cells of a column, not their positions in it" {
    var cells: [board.CELL_COUNT]Cell = undefined;
    for (&cells) |*c| c.* = Cell.init(.zero);
    const col = board.Board.asCol(2);
    cells[col.indices[1]].value = .six;
    cells[col.indices[8]].value = .six;
    try std.testing.expectEqual(board.cellBit(1, 2) | board.cellBit(8, 2), Validator.flagScopeConflicts(&cells, &col.indices));
}
