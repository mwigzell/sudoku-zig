const std = @import("std");
const board = @import("../../board.zig");
const cell = @import("../../cell.zig");
const facade = @import("../facade.zig");
const command = @import("../../command/parse.zig");

const AvailableCommands = @import("../../game_engine.zig").AvailableCommands;

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
    pub fn render(self: *MockRenderer, view: board.Board.BoardView, status_msg: ?[]const u8) facade.Error!void {
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

    pub fn showLegend(self: *MockRenderer, commands: AvailableCommands) facade.Error!void {
        _ = self;
        _ = commands;
    }

    pub fn showError(self: *MockRenderer, msg: []const u8) facade.Error!void {
        _ = self;
        _ = msg;
    }


    pub fn openDialog(self: *MockRenderer) facade.Error!facade.OpenFileResult {
        _ = self;
        return .Cancelled;
    }

    pub fn newGameOptions(self: *MockRenderer) facade.Error!facade.PuzzleReturn {
        _ = self;
        return .Cancelled;
    }

    pub fn getCommandInput(self: *MockRenderer, cmds: AvailableCommands) facade.Error!command.ParseCommandResult {
        _ = self;
        _ = cmds;
        return .{ .error_msg = "MockRenderer getCommandInput not configured" };
    }
};
