const std = @import("std");
const Cell = @import("cell.zig").Cell;

/// Scan a scope (row/column/box) of 9 cells and return a bitmask where bit `i`
/// is set when cell at position `i` has a duplicate digit in that scope.
pub fn flagScopeConflicts(cells: []const Cell, indices: []const usize) u128 {
    var counts: [10]u8 = undefined;
    @memset(&counts, 0);
    for (indices) |idx| {
        const digit = cells[idx].value;
        if (digit != .zero) counts[@intFromEnum(digit)] += 1;
    }
    var result: u128 = 0;
    for (indices, 0..) |idx, i| {
        const digit = cells[idx].value;
        if (digit != .zero and counts[@intFromEnum(digit)] > 1) {
            result |= @as(u128, 1) << @intCast(i);
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests (co-located)
// ---------------------------------------------------------------------------

test "flagScopeConflicts empty scope → all clear" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    const indices: [9]usize = .{0, 1, 2, 3, 4, 5, 6, 7, 8};
    try std.testing.expectEqual(@as(u128, 0), flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts row duplicate at positions 0 and 3" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    cells[0].value = .five;
    cells[3].value = .five;
    const indices: [9]usize = .{0, 1, 2, 3, 4, 5, 6, 7, 8};
    try std.testing.expectEqual(@as(u128, (1 << 0) | (1 << 3)), flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts column duplicate at positions 2 and 7" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    cells[2].value = .three;
    cells[7].value = .three;
    const indices: [9]usize = .{0, 1, 2, 3, 4, 5, 6, 7, 8};
    try std.testing.expectEqual(@as(u128, (1 << 2) | (1 << 7)), flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts box duplicate at positions 1 and 6" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    cells[1].value = .seven;
    cells[6].value = .seven;
    const indices: [9]usize = .{0, 1, 2, 3, 4, 5, 6, 7, 8};
    try std.testing.expectEqual(@as(u128, (1 << 1) | (1 << 6)), flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts unique digits → no false positives" {
    const cells: [9]Cell = .{
        Cell.init(.two),     // position 0
        Cell.init(.five),   // position 1
        Cell.init(.zero),  // position 2 — empty
        Cell.init(.one),     // position 3
        Cell.init(.nine),  // position 4
        Cell.init(.three), // position 5
        Cell.init(.zero),  // position 6 — empty
        Cell.init(.seven), // position 7
        Cell.init(.four), // position 8
    };
    const indices: [9]usize = .{0, 1, 2, 3, 4, 5, 6, 7, 8};
    try std.testing.expectEqual(@as(u128, 0), flagScopeConflicts(&cells, &indices));
}

test "flagScopeConflicts three-of-a-kind → all three flagged" {
    var cells: [9]Cell = undefined;
    for (0..9) |i| {
        cells[i] = Cell.init(.zero);
    }
    cells[1].value = .four;
    cells[4].value = .four;
    cells[7].value = .four;
    const indices: [9]usize = .{0, 1, 2, 3, 4, 5, 6, 7, 8};
    try std.testing.expectEqual(@as(u128, (1 << 1) | (1 << 4) | (1 << 7)), flagScopeConflicts(&cells, &indices));
}


const board = @import("board.zig");

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

/// Walk every row, column, and box scope and update conflict_bits on the Board.
pub fn validateBoard(b: *board.Board) void {
    b.clearConflicts();
    var mask: u128 = 0;

    for (0..board.DIMENSION_SIZE) |r| {
        const rv = board.Board.asRow(@intCast(r));
        const scope_bits = flagScopeConflicts(&b.cells, &rv.indices);
        mask |= scopeToBoardMask(&rv.indices, scope_bits);
    }

    for (0..board.DIMENSION_SIZE) |c| {
        const cv = board.Board.asCol(@intCast(c));
        const scope_bits = flagScopeConflicts(&b.cells, &cv.indices);
        mask |= scopeToBoardMask(&cv.indices, scope_bits);
    }

    for (0..3) |br| {
        for (0..3) |bc| {
            const xv = board.Board.asBox(@intCast(br), @intCast(bc));
            const scope_bits = flagScopeConflicts(&b.cells, &xv.indices);
            mask |= scopeToBoardMask(&xv.indices, scope_bits);
        }
    }

    b.conflict_bits = mask;
}

/// Build a bitmask of every flat-storage index in the row, column,
/// and box containing cell at (row, col).
fn unitsMask(row: u4, col: u4) u128 {
    var mask: u128 = 0;

    // Row cells
    for (0..board.DIMENSION_SIZE) |c| {
        const idx: usize = @as(usize, @intCast(row)) * board.DIMENSION_SIZE + @as(usize, @intCast(c));
        mask |= @as(u128, 1) << @intCast(idx);
    }

    // Column cells
    for (0..board.DIMENSION_SIZE) |r| {
        const idx: usize = @as(usize, @intCast(r)) * board.DIMENSION_SIZE + @as(usize, @intCast(col));
        mask |= @as(u128, 1) << @intCast(idx);
    }

    // Box cells
    const box_row: usize = @divTrunc(@as(usize, @intCast(row)), board.BOX_DIMENSION);
    const box_col: usize = @divTrunc(@as(usize, @intCast(col)), board.BOX_DIMENSION);
    for (0..board.BOX_DIMENSION) |r| {
        for (0..board.BOX_DIMENSION) |c| {
            const idx: usize = (box_row * board.BOX_DIMENSION + r) * board.DIMENSION_SIZE +
                box_col * board.BOX_DIMENSION + c;
            mask |= @as(u128, 1) << @intCast(idx);
        }
    }

    return mask;
}

/// Incremental conflict refresh after mutating cell at (row, col).
/// Clears only the affected row+col+box bits and re-detects those 3 scopes.
pub fn refreshConflictsForCell(b: *board.Board, row: u4, col: u4) void {
    const umask = unitsMask(row, col);
    b.conflict_bits &= ~umask;

    var new_mask: u128 = 0;

    // Row
    const rv = board.Board.asRow(row);
    new_mask |= scopeToBoardMask(&rv.indices, flagScopeConflicts(&b.cells, &rv.indices));

    // Column
    const cv = board.Board.asCol(col);
    new_mask |= scopeToBoardMask(&cv.indices, flagScopeConflicts(&b.cells, &cv.indices));

    // Box
    const box_row: u2 = @intCast(@divTrunc(@as(usize, @intCast(row)), board.BOX_DIMENSION));
    const box_col: u2 = @intCast(@divTrunc(@as(usize, @intCast(col)), board.BOX_DIMENSION));
    const xv = board.Board.asBox(box_row, box_col);
    new_mask |= scopeToBoardMask(&xv.indices, flagScopeConflicts(&b.cells, &xv.indices));

    b.conflict_bits |= new_mask;
}




// ---------------------------------------------------------------------------
// Integration tests — validateBoard against real Board views
// ---------------------------------------------------------------------------

test "validateBoard flags row duplicates" {
    var b = board.Board.init();
    try b.setCell(0, 0, .five); // index 0 in row 0
    try b.setCell(0, 5, .five); // index 5 in row 0 — duplicate

    validateBoard(&b);

    try std.testing.expect(b.isConflicting(0));
    try std.testing.expect(b.isConflicting(5));
    try std.testing.expect(!b.isConflicting(1)); // not conflicting
}

test "validateBoard flags column duplicates" {
    var b = board.Board.init();
    try b.setCell(2, 3, .five); // index 21 — row 2 col 3
    try b.setCell(7, 3, .five); // index 66 — row 7 col 3 — duplicate

    validateBoard(&b);

    try std.testing.expect(b.isConflicting(21));
    try std.testing.expect(b.isConflicting(66));
}

test "validateBoard flags box-only conflicts" {
    var b = board.Board.init();
    try b.setCell(0, 1, .three); // index 1 — box (0,0)
    try b.setCell(2, 0, .three); // index 18 — same box (0,0), different row & col

    validateBoard(&b);

    try std.testing.expect(b.isConflicting(1));
    try std.testing.expect(b.isConflicting(18));
}

test "validateBoard does not flag cells with no conflicts" {
    var b = board.Board.init();
    try b.setCell(0, 0, .one);
    try b.setCell(0, 1, .two);
    try b.setCell(1, 0, .three); // different row from index 0, so no row conflict; diff col, so no col conflict

    validateBoard(&b);

    for (0..81) |i| {
        try std.testing.expect(!b.isConflicting(@intCast(i)));
    }
}

test "validateBoard flags cell when conflicting in multiple scopes" {
    var b = board.Board.init();
    try b.setCell(0, 0, .five); // index 0 — row 0, col 0, box (0,0)
    try b.setCell(0, 5, .five); // index 5 — same row 0 → row conflict
    try b.setCell(3, 0, .five); // index 27 → same col 0 → col conflict

    validateBoard(&b);

    // Cell 0 is in conflict via BOTH row and column
    try std.testing.expect(b.isConflicting(0));
    try std.testing.expect(b.isConflicting(5));
    try std.testing.expect(b.isConflicting(27));
}

test "refreshConflictsForCell updates only affected scopes" {
    var b = board.Board.init();
    // Set up conflicts in row 0: five at (0,0) and (0,5)
    try b.setCell(0, 0, .five);
    try b.setCell(0, 5, .five);
    // And a separate conflict in row 4: three at (4,1) and (4,7)
    try b.setCell(4, 1, .three);
    try b.setCell(4, 7, .three);

    validateBoard(&b);

    // Both conflict pairs flagged
    try std.testing.expect(b.isConflicting(0));   // (0,0)
    try std.testing.expect(b.isConflicting(5));   // (0,5)
    try std.testing.expect(b.isConflicting(37));  // (4,1)
    try std.testing.expect(b.isConflicting(43));  // (4,7)

    // Now change cell (0,0) from five to one — removes its row conflict with (0,5)
    b.cells[0].value = .one;
    refreshConflictsForCell(&b, 0, 0);

    // Row-0 conflicts resolved: cells 0 and 5 should no longer be conflicting
    try std.testing.expect(!b.isConflicting(0));
    try std.testing.expect(!b.isConflicting(5));

    // Unrelated row-4 conflict untouched
    try std.testing.expect(b.isConflicting(37));
    try std.testing.expect(b.isConflicting(43));
}

