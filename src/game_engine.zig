const std = @import("std");
const board = @import("board.zig");
const cell = @import("cell.zig");

/// GameEngine is generic over the Renderer type it receives at init.
/// Holds Board state and delegates snapshot emission to the renderer.
pub fn GameEngine(comptime R: type) type {
    const Engine = struct {
        board: board.Board,

        /// Render delegate — must satisfy `render(RenderSnapshot) anyerror!void` contract.
        renderer: *R,

        /// Construct from a one-line puzzle string.
        pub fn init(puzzle_str: []const u8, r: *R) board.BoardError!@This() {
            return @This(){
                .board = try board.fromOneLineString(puzzle_str),
                .renderer = r,
            };
        }

        /// Set a single cell on the Board to the given raw digit (1–9).
        /// Silently skips given cells.
        pub fn fill(self: *@This(), row_idx: usize, col_idx: usize, value: u8) void {
            if (!self.board.isGiven(@intCast(row_idx), @intCast(col_idx))) {
                self.board.setCell(@intCast(row_idx), @intCast(col_idx), cell.rawToCellValue(value)) catch {};
            }
        }

        /// Delegate view construction to Board and emit through renderer.
        pub fn render(self: *@This()) anyerror!void {
            const view = self.board.asView();
            try self.renderer.render(view);
        }

        /// Set a cell and immediately re-render. Convenience wrapper over `fill` + `render`.
        pub fn fillAndRender(self: *@This(), row_idx: usize, col_idx: usize, value: u8) anyerror!void {
            self.fill(row_idx, col_idx, value);
            try self.render();
        }
    };
    return Engine;
}

const puzzle_gen = @import("puzzle_gen.zig");
const mock_renderer = @import("mock_renderer.zig");

test "GameEngine fill updates cell in snapshot" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(puzzle_gen.PuzzleGen.default(), &mock);

    engine.fill(0, 3, 7);
    try engine.render();

    const cells = mock.last_rendered_cells orelse unreachable;
    try std.testing.expectEqual(cell.CellValue.seven, cells[0][3]);
}



test "GameEngine init builds board, explicit render emits snapshot" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(puzzle_gen.PuzzleGen.default(), &mock);

    // init does not auto-render — call_count is zero post-init
    try std.testing.expectEqual(0, mock.call_count);

    try engine.render();
    try std.testing.expectEqual(1, mock.call_count);

    const cells = mock.last_rendered_cells orelse unreachable;
    // puzzle[0..2] is '6' → A1 should be a given (six)
    try std.testing.expect(engine.board.isGiven(0, 0));
    try std.testing.expectEqual(cell.CellValue.six, cells[0][0]);

    // puzzle[2] is '.' → A3 should be non-given and empty
    try std.testing.expect(!engine.board.isGiven(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, cells[0][2]);
}
