const std = @import("std");
const cell = @import("cell.zig");

/// Board dimension — a standard Sudoku grid is 9×9.
/// TODO: Revisit ownership. This constant currently lives in board but will be
/// needed by render, validation, and possibly GameEngine later. Consider a shared
/// `src/constants.zig` once two+ modules depend on it (abstraction earned by duplication).
pub const DIMENSION_SIZE: u8 = 9;

/// The canonical 9×9 Sudoku board state.
pub const Board = struct {
    cells: [DIMENSION_SIZE * DIMENSION_SIZE]cell.Cell,

    /// Create an empty Board (all zeros, nothing locked).
    pub fn init() Board {
        var b: Board = undefined;
        for (&b.cells) |*c| {
            c.* = cell.Cell.init(.zero);
        }
        return b;
    }
};

/// Construct a Board from a flat 81-element u8 array.
/// Values 0 mean empty/unlocked; values 1–9 are given digits and locked.
pub fn boardFromFlat(flat: [81]u8) Board {
    var b = Board.init();
    for (flat, 0..) |v, i| {
        if (v != 0) {
            b.cells[i].value = cell.rawToCellValue(v);
            b.cells[i].locked = true;
        }
    }
    return b;
}

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Board: constructs from flat puzzle array with correct givens and empties" {
    const easy: [81]u8 = blk: {
        // Classic easy Sudoku — pre-filled cells as digits, blanks as 0.
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

    const b = boardFromFlat(easy);

    // Total givens: count non-zero in the flat array (independent known-good literal)
    var expected_locked_count: usize = 0;
    for (&easy) |v| {
        if (v != 0) expected_locked_count += 1;
    }
    try std.testing.expectEqual(30, expected_locked_count);

    // All 81 cells populated
    var actual_locked_count: usize = 0;
    for (0..81) |i| {
        const raw_val = easy[i];
        const c = b.cells[i];
        if (raw_val != 0) {
            try std.testing.expect(c.locked);
            actual_locked_count += 1;
            try std.testing.expect(c.value == cell.rawToCellValue(raw_val));
        } else {
            try std.testing.expect(!c.locked);
            try std.testing.expect(c.value == .zero);
        }
    }
    try std.testing.expectEqual(expected_locked_count, actual_locked_count);
}
