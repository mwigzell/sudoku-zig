const std = @import("std");
const board = @import("../board.zig");
const validator = @import("validator.zig");

/// Translate scope-relative conflict bits (0..8) to full board flat-storage positions
/// using the View's index array.
pub fn scopeToBoardMask(indices: *align(1) const [9]usize, scope_bits: u128) u128 {
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
pub fn unitsMask(row: u4, col: u4) u128 {
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

/// Walk every row, column, and box scope and update conflict_bits on the Board.
pub fn validate(b: *board.Board) void {
    b.clearConflicts();
    var mask: u128 = 0;

    for (0..board.DIMENSION_SIZE) |r| {
        const rv = board.Board.asRow(@intCast(r));
        const scope_bits = validator.Validator.flagScopeConflicts(&b.cells, &rv.indices);
        mask |= scopeToBoardMask(&rv.indices, scope_bits);
    }

    for (0..board.DIMENSION_SIZE) |c| {
        const cv = board.Board.asCol(@intCast(c));
        const scope_bits = validator.Validator.flagScopeConflicts(&b.cells, &cv.indices);
        mask |= scopeToBoardMask(&cv.indices, scope_bits);
    }

    for (0..3) |br| {
        for (0..3) |bc| {
            const xv = board.Board.asBox(@intCast(br), @intCast(bc));
            const scope_bits = validator.Validator.flagScopeConflicts(&b.cells, &xv.indices);
            mask |= scopeToBoardMask(&xv.indices, scope_bits);
        }
    }

    b.conflict_bits = mask;
}

/// Incremental conflict refresh after mutating cell at (row, col).
/// Clears only the affected row+col+box bits and re-detects those 3 scopes.
pub fn refreshConflictsForCell(b: *board.Board, row: u4, col: u4) void {
    const umask = unitsMask(row, col);
    b.conflict_bits &= ~umask;

    var new_mask: u128 = 0;

    // Row
    const rv = board.Board.asRow(row);
    new_mask |= scopeToBoardMask(&rv.indices, validator.Validator.flagScopeConflicts(&b.cells, &rv.indices));

    // Column
    const cv = board.Board.asCol(col);
    new_mask |= scopeToBoardMask(&cv.indices, validator.Validator.flagScopeConflicts(&b.cells, &cv.indices));

    // Box
    const box_row: u2 = @intCast(@divTrunc(@as(usize, @intCast(row)), board.BOX_DIMENSION));
    const box_col: u2 = @intCast(@divTrunc(@as(usize, @intCast(col)), board.BOX_DIMENSION));
    const xv = board.Board.asBox(box_row, box_col);
    new_mask |= scopeToBoardMask(&xv.indices, validator.Validator.flagScopeConflicts(&b.cells, &xv.indices));

    b.conflict_bits |= new_mask;
}

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Board: conflict bits start clear and can be set/cleared individually" {
    var b = board.Board.init();

    // All cells clear to begin with
    for (0..board.CELL_COUNT) |i| {
        try std.testing.expect(!b.isConflicting(@intCast(i)));
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
    var b = board.Board.init();
    try b.setCell(0, 0, .five); // index 0 in row 0
    try b.setCell(0, 5, .five); // index 5 in row 0 — duplicate

    validate(&b);

    try std.testing.expect(b.isConflicting(0));
    try std.testing.expect(b.isConflicting(5));
    try std.testing.expect(!b.isConflicting(1)); // not conflicting
}

test "Board: validate flags column duplicates" {
    var b = board.Board.init();
    try b.setCell(2, 3, .five); // index 21 — row 2 col 3
    try b.setCell(7, 3, .five); // index 66 — row 7 col 3 — duplicate

    validate(&b);

    try std.testing.expect(b.isConflicting(21));
    try std.testing.expect(b.isConflicting(66));
}

test "Board: validate flags box-only conflicts" {
    var b = board.Board.init();
    try b.setCell(0, 1, .three); // index 1 — box (0,0)
    try b.setCell(2, 0, .three); // index 18 — same box (0,0), different row & col

    validate(&b);

    try std.testing.expect(b.isConflicting(1));
    try std.testing.expect(b.isConflicting(18));
}

test "Board: validate does not flag cells with no conflicts" {
    var b = board.Board.init();
    try b.setCell(0, 0, .one);
    try b.setCell(0, 1, .two);
    try b.setCell(1, 0, .three); // different row from index 0, so no row conflict; diff col, so no col conflict

    validate(&b);

    for (0..81) |i| {
        try std.testing.expect(!b.isConflicting(@intCast(i)));
    }
}

test "Board: validate flags cell when conflicting in multiple scopes" {
    var b = board.Board.init();
    try b.setCell(0, 0, .five); // index 0 — row 0, col 0, box (0,0)
    try b.setCell(0, 5, .five); // index 5 — same row 0 → row conflict
    try b.setCell(3, 0, .five); // index 27 → same col 0 → col conflict

    validate(&b);

    // Cell 0 is in conflict via BOTH row and column
    try std.testing.expect(b.isConflicting(0));
    try std.testing.expect(b.isConflicting(5));
    try std.testing.expect(b.isConflicting(27));
}

test "Board: refreshConflictsForCell updates only affected scopes" {
    var b = board.Board.init();
    // Set up conflicts in row 0: five at (0,0) and (0,5)
    try b.setCell(0, 0, .five);
    try b.setCell(0, 5, .five);
    // And a separate conflict in row 4: three at (4,1) and (4,7)
    try b.setCell(4, 1, .three);
    try b.setCell(4, 7, .three);

    validate(&b);

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

test "Board: refreshConflictsForCell creates new conflict" {
    var b = board.Board.init();
    // Set up: row 0 has five at (0,3); row 4 has three at (4,1) and (4,7)
    try b.setCell(0, 3, .five);
    try b.setCell(4, 1, .three);
    try b.setCell(4, 7, .three);

    validate(&b);

    // Only the row-4 pair is conflicting
    try std.testing.expect(!b.isConflicting(3));  // (0,3) — five, unique in row 0
    try std.testing.expect(b.isConflicting(37));  // (4,1)
    try std.testing.expect(b.isConflicting(43));  // (4,7)

    // Now make (0,5) also five → creates row-0 conflict for both (0,3) and (0,5)
    b.cells[5].value = .five;
    refreshConflictsForCell(&b, 0, 5);

    // New conflict pair flagged in row 0
    try std.testing.expect(b.isConflicting(3));   // (0,3) now conflicts with (0,5)
    try std.testing.expect(b.isConflicting(5));   // (0,5) conflicts with (0,3)

    // Unrelated row-4 conflict still intact
    try std.testing.expect(b.isConflicting(37));
    try std.testing.expect(b.isConflicting(43));
}

test "Board: refreshConflictsForCell does not touch unrelated cells" {
    var b = board.Board.init();
    // Conflicts in row 2: eight at (2,0) and (2,5)
    try b.setCell(2, 0, .eight);
    try b.setCell(2, 5, .eight);
    // And a unique cell in row 6 that should never be flagged:
    try b.setCell(6, 3, .one);

    validate(&b);

    // Row-2 pair flagged; row-6 cell is clear
    try std.testing.expect(b.isConflicting(18));   // (2,0)
    try std.testing.expect(b.isConflicting(23));   // (2,5)
    try std.testing.expect(!b.isConflicting(59));  // (6,3) — unique

    // Change an unrelated cell in col 7: set (1,7) to nine
    b.cells[16].value = .nine;  // flat index 1*9+7 = 16
    refreshConflictsForCell(&b, 1, 7);

    // Row-2 conflicts untouched
    try std.testing.expect(b.isConflicting(18));
    try std.testing.expect(b.isConflicting(23));

    // (6,3) still not flagged — refresh on (1,7) doesn't reach row 6 / col 3 / box 5
    try std.testing.expect(!b.isConflicting(59));
}
