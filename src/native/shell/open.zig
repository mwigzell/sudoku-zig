/// Open command handler — reads bytes via transport, loads state through engine codec.
const std = @import("std");
const game_engine = @import("../../engine/game_engine.zig");
const file_transport = @import("file_transport.zig");

pub fn execute(engine: *game_engine.GameEngine, transport: file_transport.FileTransport, path: ?[]const u8) game_engine.Event {
    if (path) |file_path| {
        return doOpen(engine, transport, file_path);
    } else {
        return .{
            .ok = .{
                .board_view = engine.state.board.asView(),
                .msg = "open: no file specified",
                .is_quit = false,
            },
        };
    }
}

fn doOpen(engine: *game_engine.GameEngine, transport: file_transport.FileTransport, file_path: []const u8) game_engine.Event {
    const gpa = std.heap.page_allocator;

    const resolved = transport.resolve(transport.context, file_path) catch |err| {
        var buf: [80]u8 = undefined;
        return game_engine.Event{ .error_msg = std.fmt.bufPrint(&buf, "resolve: {s}", .{@errorName(err)}) catch "system error" };
    };
    defer transport.free(transport.context, resolved);

    const buf = transport.readAll(transport.context, resolved) catch |err| {
        var errbuf: [80]u8 = undefined;
        return game_engine.Event{ .error_msg = std.fmt.bufPrint(&errbuf, "readAll: {s}", .{@errorName(err)}) catch "system error" };
    };
    defer transport.free(transport.context, buf);

    engine.loadSaveFormat(buf) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    const msg = std.fmt.allocPrint(gpa, "opened: {s}", .{resolved}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    return .{
        .ok = .{
            .board_view = engine.state.board.asView(),
            .msg = msg,
            .is_quit = false,
        },
    };
}

// ---------------------------------------------------------------------------
// Tests — verify open command handler seam
// ---------------------------------------------------------------------------

test "command.open.execute opens file and returns ok with message" {
    var engine = try game_engine.GameEngine.init(
        @import("../../puzzle_gen.zig").PuzzleGen.default(),
        @import("../../config.zig").Config.default(),
    );
    defer engine.deinit();

    const transport = file_transport.NativeTransport.make(std.testing.io);
    defer file_transport.NativeTransport.deinitSession();
    const tmp_path = "/tmp/sudoku_open_command_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    const resolved = try transport.resolve(transport.context, tmp_path);
    defer transport.free(transport.context, resolved);

    const save_buf = try engine.toSaveFormat(std.heap.page_allocator);
    defer std.heap.page_allocator.free(save_buf);
    try transport.write(transport.context, resolved, save_buf);

    const event = execute(&engine, transport, tmp_path);

    switch (event) {
        .ok => |data| {
            try std.testing.expect(!data.is_quit);
            try std.testing.expect(data.msg != null);
            const m = data.msg.?;
            try std.testing.expect(std.mem.indexOf(u8, m, "opened") != null);
        },
        .error_msg => return error.TestFailed,
    }
}

test "command.open.execute returns fallback message when path is null" {
    var engine = try game_engine.GameEngine.init(
        @import("../../puzzle_gen.zig").PuzzleGen.default(),
        @import("../../config.zig").Config.default(),
    );
    defer engine.deinit();

    const transport = file_transport.NativeTransport.make(std.testing.io);
    const event = execute(&engine, transport, null);

    switch (event) {
        .ok => |data| {
            try std.testing.expect(data.msg != null);
            try std.testing.expect(std.mem.indexOf(u8, data.msg.?, "no file") != null);
        },
        .error_msg => return error.TestFailed,
    }
}
