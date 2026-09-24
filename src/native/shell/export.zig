// Export command handler — the write inverse of import.
// Serializes the current board's cell values to one 81-char line and writes
// it through the transport seam; a failed write leaves the running game intact.
const std = @import("std");
const cell = @import("../../board/cell.zig");
const board = @import("../../board/board.zig");
const config = @import("../../config.zig");
const game_engine = @import("../../engine/game_engine.zig");
const file_transport = @import("file_transport.zig");
const PuzzleGen = @import("../../puzzle_gen.zig").PuzzleGen;

pub fn execute(engine: *game_engine.GameEngine, transport: file_transport.FileTransport, path: ?[]const u8) game_engine.Event {
    if (path) |p| {
        const gpa = std.heap.page_allocator;
        const resolved = transport.resolve(transport.context, p) catch |err| {
            var buf: [80]u8 = undefined;
            return game_engine.Event{ .error_msg = std.fmt.bufPrint(&buf, "resolve: {s}", .{@errorName(err)}) catch "system error" };
        };
        defer transport.free(transport.context, resolved);

        const line = board.toOneLineString(engine.state.board);
        transport.write(transport.context, resolved, &line) catch |err| {
            return game_engine.Event{ .error_msg = @errorName(err) };
        };

        const msg = std.fmt.allocPrint(gpa, "exported to: {s}", .{resolved}) catch |err| {
            return game_engine.Event{ .error_msg = @errorName(err) };
        };

        return game_engine.Event{ .ok = .{
            .board_view = engine.state.board.asView(),
            .msg = msg,
            .is_quit = false,
        } };
    }
    return game_engine.Event{ .error_msg = "export: no file specified" };
}

// ---------------------------------------------------------------------------

test "export.execute writes a one-line file matching toOneLineString(current board)" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const transport = file_transport.NativeTransport.make(std.testing.io);
    defer file_transport.NativeTransport.deinitSession();

    const tmp_path = "/tmp/sudoku_export_command_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    const before = board.toOneLineString(engine.state.board);
    const event = execute(&engine, transport, tmp_path);
    switch (event) {
        .ok => |ok| {
            _ = ok.board_view;
            if (ok.msg == null) return error.TestFailed;
        },
        else => return error.TestFailed,
    }

    const bytes = transport.readAll(transport.context, tmp_path) catch |err| return err;
    defer transport.free(transport.context, bytes);
    try std.testing.expectEqual(@as(usize, 81), bytes.len);
    try std.testing.expectEqualSlices(u8, &before, bytes[0..81]);
}

test "export.execute on an unwritable path returns error_msg and leaves board intact" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const transport = file_transport.NativeTransport.make(std.testing.io);
    defer file_transport.NativeTransport.deinitSession();

    const missing_parent = "/tmp/sudoku_export_missing_parent_test";
    std.Io.Dir.deleteDirAbsolute(std.testing.io, missing_parent) catch {};
    const ro_path = missing_parent ++ "/export_out.txt";

    const before = board.toOneLineString(engine.state.board);
    const event = execute(&engine, transport, ro_path);
    switch (event) {
        .error_msg => {},
        else => return error.TestFailed,
    }
    const after = board.toOneLineString(engine.state.board);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "export.execute with null path returns error_msg" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const transport = file_transport.NativeTransport.make(std.testing.io);
    defer file_transport.NativeTransport.deinitSession();

    const event = execute(&engine, transport, null);
    switch (event) {
        .error_msg => {},
        else => return error.TestFailed,
    }
}

test "export does not disturb cell history" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const transport = file_transport.NativeTransport.make(std.testing.io);
    defer file_transport.NativeTransport.deinitSession();

    _ = engine.exec(.{ .fill = .{ .row = 2, .col = 0, .digit = cell.CellValue.seven } });
    const history_len = engine.state.history.entries.items.len;
    const before = board.toOneLineString(engine.state.board);

    const tmp_path = "/tmp/sudoku_export_hist_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};
    const event = execute(&engine, transport, tmp_path);
    _ = switch (event) {
        .ok, .error_msg => true,
    };

    try std.testing.expectEqual(history_len, engine.state.history.entries.items.len);
    const after = board.toOneLineString(engine.state.board);
    try std.testing.expectEqualSlices(u8, &before, &after);
}
