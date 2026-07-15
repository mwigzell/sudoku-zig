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
        /// Stores renderer reference but does not emit — caller controls first render via `render()`.
        pub fn init(puzzle_str: []const u8, r: *R) board.BoardError!@This() {
            return @This(){
                .board = try board.fromOneLineString(puzzle_str),
                .renderer = r,
            };
        }

        /// Set a single cell on the Board to the given raw digit (1–9).
        /// Silently skips locked/given cells.
        pub fn fill(self: *@This(), row_idx: usize, col_idx: usize, value: u8) void {
            const ptr = self.board.grid.cellAt(@intCast(row_idx), @intCast(col_idx));
            if (!ptr.locked) {
                ptr.value = cell.rawToCellValue(value);
            }
        }

        /// Delegate snapshot assembly to Board and emit through renderer.
        pub fn render(self: *@This()) anyerror!void {
            const snap = self.board.assembleRenderSnapshot();
            try self.renderer.render(snap);
        }

        /// Set a cell and immediately re-render. Convenience wrapper over `fill` + `render`.
        pub fn fillAndRender(self: *@This(), row_idx: usize, col_idx: usize, value: u8) anyerror!void {
            self.fill(row_idx, col_idx, value);
            try self.render();
        }
    };
    return Engine;
}

const default_puzzle = @import("default_puzzle.zig");
const mock_renderer = @import("mock_renderer.zig");

test "GameEngine fill updates cell in snapshot" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(default_puzzle.default_puzzle, &mock);

    engine.fill(0, 2, 7);
    try engine.render();

    const snap = mock.last_snapshot orelse unreachable;
    try std.testing.expectEqual(cell.CellValue.seven, snap.cells[0][2].value);
    try std.testing.expect(!snap.cells[0][2].locked);
}

test "GameEngine init builds board, explicit render emits snapshot" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(default_puzzle.default_puzzle, &mock);

    // init does not auto-render — call_count is zero post-init
    try std.testing.expectEqual(0, mock.call_count);

    try engine.render();
    try std.testing.expectEqual(1, mock.call_count);

    const snap = mock.last_snapshot orelse unreachable;
    // puzzle[0..3] is '6' → A1 should be locked six
    try std.testing.expect(snap.cells[0][0].locked);
    try std.testing.expectEqual(cell.CellValue.six, snap.cells[0][0].value);

    // puzzle[2] is '.' → A3 should be empty and unlocked
    try std.testing.expect(!snap.cells[0][2].locked);
    try std.testing.expectEqual(cell.CellValue.zero, snap.cells[0][2].value);
}
