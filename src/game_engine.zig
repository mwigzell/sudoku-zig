const std = @import("std");
const board = @import("board.zig");
const cell = @import("cell.zig");

pub const CommandResult = union(enum) { ok, error_msg: []const u8 };

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
        /// Route a parsed command through Board mutation + render update.
        pub fn exec(self: *@This(), cmd: command.Command) anyerror!CommandResult {
            switch (cmd) {
                .fill => |f| {
                    return self.tryFill(f.row, f.col, f.digit);
                },
                .clear => |c| {
                    return self.tryClear(c.row, c.col);
                },
                .quit => {
                    return CommandResult.ok;
                },
            }
        }

        /// Attempt to fill a cell — surfaces given-cell rejections as error_msg.
        fn tryFill(self: *@This(), row: u4, col: u4, digit: cell.CellValue) CommandResult {
            self.board.setCell(row, col, digit) catch {
                return CommandResult{ .error_msg = "cannot overwrite a given cell" };
            };
            self.renderer.render(self.board.asView()) catch {};
            return CommandResult.ok;
        }
        /// Attempt to clear a cell — refuses if the cell is given.
        fn tryClear(self: *@This(), row: u4, col: u4) CommandResult {
            if (self.board.isGiven(row, col)) {
                return CommandResult{ .error_msg = "cannot clear a given cell" };
            }
            self.board.clearCell(row, col);
            self.renderer.render(self.board.asView()) catch {};
            return CommandResult.ok;
        }


    };
    return Engine;
}

const puzzle_gen = @import("puzzle_gen.zig");
const mock_renderer = @import("mock_renderer.zig");

const command = @import("command.zig");
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

// T2: exec(Command) returns structured results with given-cell feedback

test "exec fill non-given cell → .ok" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(), &mock,
    );

    const fill_cmd = command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    };
    _ = try engine.exec(fill_cmd);

    // Board should show the filled value at (0, 2)
    try std.testing.expectEqual(cell.CellValue.seven, engine.board.getCellValue(0, 2));
}

test "exec fill given cell → .error_msg" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(), &mock,
    );

    // A1 (0, 0) is a given ('6'.)
    try std.testing.expect(engine.board.isGiven(0, 0));

    const fill_cmd = command.Command{
        .fill = command.FillData{ .row = 0, .col = 0, .digit = cell.CellValue.nine },
    };
    const result: CommandResult = try engine.exec(fill_cmd);

    if (result != .error_msg) return error.TestFailed;

    // Message field exists since we tagged .error_msg above
    _ = result.error_msg;
}

test "exec clear given cell → .error_msg" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(), &mock,
    );

    const clear_cmd = command.Command{
        .clear = command.ClearData{ .row = 0, .col = 0 },
    };
    const result: CommandResult = try engine.exec(clear_cmd);

    if (result != .error_msg) return error.TestFailed;
}

test "exec quit → .ok" {
    var mock = mock_renderer.MockRenderer.init();
    _ = mock.call_count;  // silence unused warning on variable we check below

    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(), &mock,
    );

    const quit_cmd: command.Command = .{ .quit = {} };
    const result: CommandResult = try engine.exec(quit_cmd);

    if (result != .ok) return error.TestFailed;
}

