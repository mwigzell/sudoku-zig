const std = @import("std");
const board = @import("../../board.zig");
const cell = @import("../../cell.zig");

/// Test helper: accepts BoardView and copies the 9×9 grid of CellValue for inspection.
pub const MockRenderer = struct {
    call_count: usize,
    last_rendered_cells: ?[9][9]cell.CellValue,

    pub fn init() MockRenderer {
        return .{
            .call_count = 0,
            .last_rendered_cells = null,
        };
    }

    /// Accepts a BoardView, copies its flat cells into [9][9]CellValue.
    pub fn render(self: *MockRenderer, view: board.Board.BoardView, status_msg: ?[]const u8) anyerror!void {
        _ = status_msg;
        var cells: [9][9]cell.CellValue = undefined;
        for (0..board.DIMENSION_SIZE) |row| {
            for (0..board.DIMENSION_SIZE) |col| {
                cells[row][col] = view.get(@intCast(row), @intCast(col));

            }
        }
        self.last_rendered_cells = cells;
        self.call_count += 1;
    }
};

// ---------------------------------------------------------------------------
// Change-1 test — MockRenderer captures [9][9]CellValue from BoardView
test "MockRenderer: copies BoardView flat cells into [9][9]CellValue" {
    var flat: [board.CELL_COUNT]u8 = undefined;
    @memset(&flat, 0);
    flat[0] = 5;   // row 0 col 0 = five (given)
    flat[12] = 3;  // row 1 col 3 = three (given)
    flat[80] = 9;  // row 8 col 8 = nine (given)

    var b = try board.fromFlat(flat, .{});
    const view = b.asView();

    var mock = MockRenderer.init();
    try mock.render(view, null);

    // call_count incremented
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);

    // last_rendered_cells captures all values
    const cells = mock.last_rendered_cells orelse unreachable;

    // Given cell values present
    try std.testing.expectEqual(cell.CellValue.five, cells[0][0]);
    try std.testing.expectEqual(cell.CellValue.three, cells[1][3]);
    try std.testing.expectEqual(cell.CellValue.nine, cells[8][8]);

    // Mutate a non-given cell and re-render — mock should reflect update
    try b.setCell(2, 4, .seven);
    try mock.render(view, null);

    try std.testing.expectEqual(@as(usize, 2), mock.call_count);

    // Re-extract to get the second render's copy
    const cells2 = mock.last_rendered_cells orelse unreachable;
    try std.testing.expectEqual(cell.CellValue.seven, cells2[2][4]);
}
