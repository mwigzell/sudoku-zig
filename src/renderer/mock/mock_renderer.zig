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
    command_queue: []const command.ParseCommandResult,
    queue_index: usize,

    pub fn init(commands: []const command.ParseCommandResult) MockRenderer {
        return .{
            .call_count = 0,
            .last_rendered_cells = null,
            .command_queue = commands,
            .queue_index = 0,
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
        _ = cmds;
        if (self.queue_index < self.command_queue.len) {
            const result = self.command_queue[self.queue_index];
            self.queue_index += 1;
            return result;
        }
        // Queue exhausted — return quit to break the run() loop
        return .{ .valid = command.Command.quit };
    }
};

fn dummyAvailableCommands() AvailableCommands {
    return .{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .save = true,
        .open = true,
        .new = true,
        .save_as = true,
    };
}
test "MockRenderer.getCommandInput returns queued commands in order" {
    const cmds = [_]command.ParseCommandResult{
        .{ .valid = .{ .quit = {} } },
        .{ .valid = .{ .undo = {} } },
    };
    var mock = MockRenderer.init(&cmds);

    const r1 = try mock.getCommandInput(dummyAvailableCommands());
    try std.testing.expect(r1 == .valid);
    try std.testing.expectEqualStrings(@tagName(r1.valid), "quit");
    try std.testing.expectEqual(@as(usize, 1), mock.queue_index);

    const r2 = try mock.getCommandInput(dummyAvailableCommands());
    try std.testing.expect(r2 == .valid);
    try std.testing.expectEqualStrings(@tagName(r2.valid), "undo");
    try std.testing.expectEqual(@as(usize, 2), mock.queue_index);
}

test "MockRenderer.getCommandInput returns quit on empty queue" {
    var mock = MockRenderer.init(&.{});

    const r = try mock.getCommandInput(dummyAvailableCommands());
    try std.testing.expect(r == .valid);
    try std.testing.expectEqualStrings(@tagName(r.valid), "quit");
}

test "MockRenderer.getCommandInput returns quit after exhausting queue" {
    const cmds = [_]command.ParseCommandResult{
        .{ .valid = .{ .quit = {} } },
    };
    var mock = MockRenderer.init(&cmds);

    _ = try mock.getCommandInput(dummyAvailableCommands());

    const after = try mock.getCommandInput(dummyAvailableCommands());
    try std.testing.expect(after == .valid);
    try std.testing.expectEqualStrings(@tagName(after.valid), "quit");
}

test "MockRenderer.getCommandInput can return error_msg entries" {
    const cmds = [_]command.ParseCommandResult{
        .{ .error_msg = "some error" },
    };
    var mock = MockRenderer.init(&cmds);

    const r = try mock.getCommandInput(dummyAvailableCommands());
    try std.testing.expect(r == .error_msg);
    try std.testing.expectEqualStrings(r.error_msg, "some error");
}
