const std = @import("std");
const testing = std.testing;
const cell = @import("cell.zig");
const board = @import("board.zig");

pub fn cellChar(c: cell.Cell) u8 {
    return switch (c.value) {
        .one => '1',
        .two => '2',
        .three => '3',
        .four => '4',
        .five => '5',
        .six => '6',
        .seven => '7',
        .eight => '8',
        .nine => '9',
        .zero => '.',
    };
}

/// Render the full 9×9 board as an ASCII grid to `wr`.
/// Draws top/bottom borders, left/right vertical edges,
/// and internal dividers between every 3-row/3-col box.
pub fn printGrid(wr: anytype, b: board.Board) !void {
    const n = board.DIMENSION_SIZE;
    const hline = "+-----+-----+-----+\n";

    var row: u8 = 0;
    while (row < n) : (row += 1) {
        // Horizontal border before every box row (and top)
        if (row % 3 == 0) _ = try wr.writeAll(hline);

        // Build one board row: "| c c c | c c c | c c c |
        var rowData: [24]u8 = undefined;
        var pos: usize = 0;
        rowData[pos] = '|';
        pos += 1;

        var col: u8 = 0;
        while (col < n) : (col += 1) {
            const ch = cellChar(b.cells[@as(usize, @intCast(row * n + col))]);
            rowData[pos] = ' ';
            pos += 1;
            rowData[pos] = ch;
            pos += 1;

            // Vertical divider after every 3rd cell (cols 3, 6)
            if ((col > 0) and (col % 3 == 0)) {
                rowData[pos] = '|';
                pos += 1;
            }
        }
        rowData[pos] = '|';
        _ = try wr.writeAll(rowData[0 .. pos + 1]);
        _ = try wr.write("\n");
    }

    // Bottom border
    _ = try wr.writeAll(hline);
}

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "render: cellChar maps filled cells to their digit character" {
    const c = cell.Cell.init(.five);
    try testing.expectEqual('5', cellChar(c));
}

test "render: cellChar maps empty (zero) cells to dot placeholder" {
    const c = cell.Cell.init(.zero);
    try testing.expectEqual('.', cellChar(c));
}

// NOTE: printGrid render test lives in tests.zig (root module) because std.io
// fails to resolve under the current transitive-import arrangement.
// TODO: Fix and move back when Zig 0.17 import resolution stabilises.
