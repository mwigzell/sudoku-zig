// Edit → Copy (native): emit the current grid as one 81-char line on stdout.
const std = @import("std");
const cell = @import("../../board/cell.zig");
const board = @import("../../board/board.zig");
const config = @import("../../config.zig");
const game_engine = @import("../../engine/game_engine.zig");
const export_command = @import("export.zig");
const PuzzleGen = @import("../../puzzle_gen.zig").PuzzleGen;

pub fn execute(engine: *game_engine.GameEngine, out: *std.Io.Writer) game_engine.Event {
    const line = export_command.currentPuzzleLine(engine);
    std.Io.Writer.writeAll(out, &line) catch return game_engine.Event{ .error_msg = "copy: write failed" };
    std.Io.Writer.writeAll(out, "\n") catch return game_engine.Event{ .error_msg = "copy: write failed" };

    const msg = std.fmt.allocPrint(std.heap.page_allocator, "copy: puzzle line printed", .{}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    return game_engine.Event{ .ok = .{
        .board_view = engine.state.board.asView(),
        .msg = msg,
        .is_quit = false,
    } };
}

test "copy.execute prints exact one-line puzzle via writer; board and history unchanged" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = engine.exec(.{ .fill = .{ .row = 2, .col = 0, .digit = cell.CellValue.seven } });
    const history_len = engine.state.history.entries.items.len;
    const expected = export_command.currentPuzzleLine(&engine);

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const before = board.toOneLineString(engine.state.board);
    const event = execute(&engine, &aw.writer);
    switch (event) {
        .ok => |ok| {
            try std.testing.expect(ok.msg != null);
            std.heap.page_allocator.free(ok.msg.?);
        },
        else => return error.TestFailed,
    }

    const written = std.Io.Writer.buffered(&aw.writer);
    try std.testing.expectEqual(@as(usize, 82), written.len);
    try std.testing.expectEqualSlices(u8, &expected, written[0..81]);
    try std.testing.expectEqual('\n', written[81]);
    try std.testing.expectEqual(history_len, engine.state.history.entries.items.len);
    const after = board.toOneLineString(engine.state.board);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "copy.execute matches export file bytes for the same board" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const line = export_command.currentPuzzleLine(&engine);
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const event = execute(&engine, &aw.writer);
    switch (event) {
        .ok => |ok| std.heap.page_allocator.free(ok.msg.?),
        else => return error.TestFailed,
    }
    const written = std.Io.Writer.buffered(&aw.writer);
    try std.testing.expectEqualSlices(u8, &line, written[0..81]);
}
