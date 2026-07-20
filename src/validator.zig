const std  = @import("std");
const board = @import("board.zig");

pub fn flagConflicts(b: *board.Board) void {
    b.clearConflicts();

    const row0 = board.Board.asRow(0);
    for (row0.indices) |idx1| {
        const val1 = b.getCellValue(0, @intCast(idx1));
        if (val1 == .zero) continue;
        for (row0.indices) |idx2| {
            if (idx1 != idx2 and b.getCellValue(0, @intCast(idx2)) == val1) {
                b.setConflictBit(idx1);
                break;
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
