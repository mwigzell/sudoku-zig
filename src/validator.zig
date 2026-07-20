const std  = @import("std");
const board = @import("board.zig");

pub fn flagConflicts(b: *board.Board) void {
    b.clearConflicts();

    // Check every row
    for (0..board.DIMENSION_SIZE) |r| {
        const rowNum: u4 = @intCast(r);
        const rv = board.Board.asRow(rowNum);
        for (rv.indices, 0..) |idx1, p1| {
            const val1 = b.getCellValue(rowNum, @as(u4, @intCast(p1)));
            if (val1 == .zero) continue;
            for (rv.indices) |idx2| {
                if (idx1 != idx2 and b.getCellValue(rowNum, @as(u4, @intCast(idx2 - rv.indices[0]))) == val1) {
                    b.setConflictBit(idx1);
                    break;
                }
            }
        }
    }

    // Check every column
    for (0..board.DIMENSION_SIZE) |c| {
        const colNum: u4 = @intCast(c);
        const cv = board.Board.asCol(colNum);
        for (cv.indices, 0..) |idx1, p1| {
            const val1 = b.getCellValue(@as(u4, @intCast(p1)), colNum);
            if (val1 == .zero) continue;
            for (cv.indices, 0..) |_, p2| {
                if (p1 != p2 and b.getCellValue(@as(u4, @intCast(p2)), colNum) == val1) {
                    b.setConflictBit(idx1);
                    break;
                }
            }
        }
    }

    // Check every box
    for (0..3) |br| {
        for (0..3) |bc| {
            const xv = board.Board.asBox(@intCast(br), @intCast(bc));
            for (xv.indices) |idx1| {
                const val1 = b.getCellValue(
                    @as(u4, @intCast(idx1 / board.DIMENSION_SIZE)),
                    @as(u4, @intCast(idx1 % board.DIMENSION_SIZE)),
                );
                if (val1 == .zero) continue;
                for (xv.indices) |idx2| {
                    if (idx1 != idx2 and b.getCellValue(
                        @as(u4, @intCast(idx2 / board.DIMENSION_SIZE)),
                        @as(u4, @intCast(idx2 % board.DIMENSION_SIZE)),
                    ) == val1) {
                        b.setConflictBit(idx1);
                        break;
                    }
                }
            }
        }
    }
}

test "validate empty board → all clear" {
    var b = board.Board.init();
    flagConflicts(&b);

    for (0..board.CELL_COUNT) |i| {
        try std.testing.expect(!b.isConflicting(i));
    }
}

test "validate row conflict → both duplicate cells flagged" {
    var b = board.Board.init();
    try b.setCell(0, 2, .five); // index 2
    try b.setCell(0, 6, .five); // index 6 — duplicate in row 0
    flagConflicts(&b);

    var bit_2_set = false;
    var bit_6_set = false;
    for (0..board.CELL_COUNT) |i| {
        if (b.isConflicting(i)) {
            switch (i) {
                2 => { bit_2_set = true; },
                6 => { bit_6_set = true; },
                else => try std.testing.expect(false), // no stray bits
            }
        }
    }
    try std.testing.expect(bit_2_set);
    try std.testing.expect(bit_6_set);
}
test "validate column conflict → duplicates flagged" {
    var b = board.Board.init();
    try b.setCell(2, 3, .five); // index 21 — row 2, col 3
    try b.setCell(7, 3, .five); // index 66 — row 7, col 3 — duplicate in column 3
    flagConflicts(&b);

    var bit_21_set = false;
    var bit_66_set = false;
    for (0..board.CELL_COUNT) |i| {
        if (b.isConflicting(i)) {
            switch (i) {
                21 => { bit_21_set = true; },
                66 => { bit_66_set = true; },
                else => try std.testing.expect(false), // no stray bits
            }
        }
    }
    try std.testing.expect(bit_21_set);
    try std.testing.expect(bit_66_set);
}
test "validate box conflict → duplicates within 3x3 flagged" {
    var b = board.Board.init();
    try b.setCell(0, 1, .five); // index 1 — in box (0,0)
    try b.setCell(2, 0, .five); // index 18 — also in box (0,0), different row+col
    flagConflicts(&b);

    var bit_1_set = false;
    var bit_18_set = false;
    for (0..board.CELL_COUNT) |i| {
        if (b.isConflicting(i)) {
            switch (i) {
                1 => { bit_1_set = true; },
                18 => { bit_18_set = true; },
                else => try std.testing.expect(false), // no stray bits
            }
        }
    }
    try std.testing.expect(bit_1_set);
    try std.testing.expect(bit_18_set);
}
test "validate no false positives — unique digits across all scopes" {
    // Use the default puzzle fixture — guaranteed valid (no duplicates in any scope)
    const fixture = @import("puzzle_gen.zig").PuzzleGen.default();
    var b = board.fromOneLineString(fixture) catch unreachable;
    flagConflicts(&b);

    for (0..board.CELL_COUNT) |i| {
        try std.testing.expect(!b.isConflicting(i));
    }
}
