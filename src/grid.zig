const std = @import("std");
const box = @import("box.zig");
const cell = @import("cell.zig");

/// Computed lens across three Boxes sharing a horizontal band, yielding 9 cell
/// references for global row index 0–8. Not an owned array — assembles refs
/// from the Box owners.
pub const RowView = struct {
    cells: [9]*cell.Cell,
    rowNum: u4,
};

/// Computed lens across three Boxes sharing a vertical band, yielding 9 cell
/// references for global column index 0–8. Like RowView, not an owned array.
pub const ColView = struct {
    cells: [9]*cell.Cell,
    colNum: u4,
};

/// Immutable topology engine holding the authoritative Box arrangement and
/// providing computed row/column views across that owned data.
pub const Grid = struct {
    boxes: [3][3]box.Box,

    /// Create a fresh Grid with 9 empty Boxes, each carrying correct (boxRow, boxCol).
    pub fn init() Grid {
        var g: Grid = undefined;
        for (0..3) |br| {
            for (0..3) |bc| {
                g.boxes[br][bc] = box.Box.init(@intCast(br), @intCast(bc));
            }
        }
        return g;
    }

    /// Return a RowView lens for the given global row index (0–8),
    /// assembling cell references across 3 Boxes in that horizontal band.
    pub fn row(self: *Grid, n: u8) RowView {
        const boxRow: usize = @divTrunc(n, 3);         // which band of boxes
        const withinBoxRow: usize = @mod(n, 3);         // row inside each box
        var rv: RowView = .{ .rowNum = @intCast(n), .cells = undefined };
        for (0..3) |bc| {
            inline for (0..3) |cc| {
                const globalColIndex: usize = bc * 3 + cc;
                rv.cells[globalColIndex] = &self.boxes[boxRow][bc].cells[withinBoxRow][cc];
            }
        }
        return rv;
    }

    /// Return a ColView lens for the given global column index (0–8),
    /// assembling cell references across 3 Boxes in that vertical band.
    pub fn col(self: *Grid, n: u8) ColView {
        const boxCol: usize = @divTrunc(n, 3);          // which vertical band of boxes
        const withinBoxCol: usize = @mod(n, 3);         // column inside each box
        var cv: ColView = .{ .colNum = @intCast(n), .cells = undefined };
        for (0..3) |br| {
            inline for (0..3) |r| {
                const globalRowIndex: usize = br * 3 + r;
                cv.cells[globalRowIndex] = &self.boxes[br][boxCol].cells[r][withinBoxCol];
            }
        }
        return cv;
    }

    /// Resolve a global (row, col) coordinate to the Cell pointer owned by the
    /// correct Box. Used by Board construction to write puzzle data through ownership.
    pub fn cellAt(self: *Grid, globalRow: u4, globalCol: u4) *cell.Cell {
        const boxRow: usize = @divTrunc(globalRow, 3);
        const withinBoxRow: usize = @mod(globalRow, 3);
        const boxCol: usize = @divTrunc(globalCol, 3);
        const withinBoxCol: usize = @mod(globalCol, 3);
        return &self.boxes[boxRow][boxCol].cells[withinBoxRow][withinBoxCol];
    }
};

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Grid: init produces 9 Boxes with correct meta-grid positions" {
    const g = Grid.init();

    for (0..3) |br| {
        for (0..3) |bc| {
            const b = g.boxes[br][bc];
            try std.testing.expectEqual(@as(u2, @intCast(br)), b.boxRow);
            try std.testing.expectEqual(@as(u2, @intCast(bc)), b.boxCol);
        }
    }
}

test "Grid: row(4) assembles cell references from the three middle-band Boxes" {
    var g = Grid.init();

    // Seed unique values in box-row 1 (middle band) so we can verify which cells the lens points to.
    for (0..3) |c| {
        g.boxes[1][0].cells[1][c].value = .one;
        g.boxes[1][1].cells[1][c].value = .two;
        g.boxes[1][2].cells[1][c].value = .three;
    }

    const rv = g.row(4);
    try std.testing.expectEqual(@as(u4, 4), rv.rowNum);

    // row(4) is middle band (box-row 1), within-box row index 1 (4 % 3)
    // Box [1][0] contributed rows 0-2 at global cols 0-2 → values .one
    // Box [1][1] contributed rows 0-2 at global cols 3-5 → values .two
    // Box [1][2] contributed rows 0-2 at global cols 6-8 → values .three
    for (0..3) |i| {
        try std.testing.expectEqual(.one, rv.cells[i].value);
        try std.testing.expectEqual(.two, rv.cells[i + 3].value);
        try std.testing.expectEqual(.three, rv.cells[i + 6].value);
    }
}

test "Grid: col(4) assembles cell references from the three center-band Boxes" {
    var g = Grid.init();

    // Seed unique values in box-col 1 (center vertical band), within-box column index 1.
    for (0..3) |br| {
        for (0..3) |r| {
            switch (br) {
                0 => g.boxes[br][1].cells[r][1].value = .one,
                1 => g.boxes[br][1].cells[r][1].value = .two,
                else => g.boxes[br][1].cells[r][1].value = .three,
            }
        }
    }

    const cv = g.col(4);
    try std.testing.expectEqual(@as(u4, 4), cv.colNum);

    // col(4) is center vertical band (box-col 1), within-box col index 1 (4 % 3)
    // Box [0][1] contributes global rows 0-2 → values .one
    // Box [1][1] contributes global rows 3-5 → values .two
    // Box [2][1] contributes global rows 6-8 → values .three
    for (0..3) |i| {
        try std.testing.expectEqual(.one, cv.cells[i].value);
        try std.testing.expectEqual(.two, cv.cells[i + 3].value);
        try std.testing.expectEqual(.three, cv.cells[i + 6].value);
    }
}

test "Grid: cellAt resolves global coordinates through Box ownership" {
    var g = Grid.init();

    // Seed a unique value at the center of box [1][1]: cells[1][2]
    g.boxes[1][1].cells[1][2].value = .seven;

    // Global row=4  → box-row 1, within-box row 1
    // Global col=5  → box-col 1, within-box col 2
    const ptr: *cell.Cell = g.cellAt(@as(u4, 4), @as(u4, 5));
    try std.testing.expectEqual(.seven, ptr.value);

    // Mutate through the returned pointer — Box must see the change (ownership proof).
    ptr.value = .nine;
    try std.testing.expectEqual(.nine, g.boxes[1][1].cells[1][2].value);
}
