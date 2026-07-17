const std = @import("std");
const cell = @import("cell.zig");

/// A 3×3 block on the Sudoku grid. Box is the canonical owner of Cell storage;
/// rows and columns are computed lenses across owned Boxes.
pub const Box = struct {
    /// The 9 cells this Box owns, arranged as a 3-by-3 array.
    cells: [3][3]cell.Cell,

    /// Position in the meta-grid (0..2). Each Box has a stable (boxRow, boxCol)
    /// that never changes — it's part of the immutable topology.
    boxRow: u2,
    boxCol: u2,

    /// Create a fresh Box with all 9 cells empty and unlocked.
    pub fn init(r: u2, c: u2) Box {
        return .{
            .cells = blk: {
                var cells_arr: [3][3]cell.Cell = undefined;
                for (0..3) |row| {
                    for (0..3) |col| {
                        cells_arr[row][col] = cell.Cell.init(.zero, false);
                    }
                }
                break :blk cells_arr;
            },
            .boxRow = r,
            .boxCol = c,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Box: holds a 3x3 cell array and remembers its meta-grid position" {
    const b = Box.init(0, 2);

    try std.testing.expectEqual(@as(u2, 0), b.boxRow);
    try std.testing.expectEqual(@as(u2, 2), b.boxCol);

    // All cells start empty and unlocked (fresh board)
    for (0..3) |r| {
        for (0..3) |c| {
            const cell_entry = b.cells[r][c];
            try std.testing.expectEqual(cell.CellValue.zero, cell_entry.value);
            try std.testing.expect(!cell_entry.given);
        }
    }
}
