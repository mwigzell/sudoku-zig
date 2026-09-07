/// Open command handler — deserializes game state from file via exec() dispatch.
const std = @import("std");
const game_engine = @import("game_engine.zig");
const save_format = @import("save_format.zig");
const file_transport = @import("file_transport.zig");
const mypath = @import("path.zig");

pub fn execute(engine: *game_engine.GameEngine, path: ?[]const u8) game_engine.Event {
    if (path) |file_path| {
        return doOpen(engine, file_path);
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

fn doOpen(engine: *game_engine.GameEngine, file_path: []const u8) game_engine.Event {
    const gpa = std.heap.page_allocator;

    const resolved = engine.transport.resolve(engine.transport.context, file_path) catch |err| {
        var buf: [80]u8 = undefined;
        return game_engine.Event{ .error_msg = std.fmt.bufPrint(&buf, "resolve: {s}", .{@errorName(err)}) catch "system error" };
    };
    defer engine.transport.free(engine.transport.context, resolved);

    // Read file bytes
    const buf = engine.transport.readAll(engine.transport.context, resolved) catch |err| {
        var errbuf: [80]u8 = undefined;
        return game_engine.Event{ .error_msg = std.fmt.bufPrint(&errbuf, "readAll: {s}", .{@errorName(err)}) catch "system error" };
    };
    defer engine.transport.free(engine.transport.context, buf);

    // Deserialize into a loaded State (pure codec, no Io)
    const loaded = save_format.fromSaveFormat(gpa, buf) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    // Replace the engine's board/history with the loaded state
    engine.state.history.deinit();
    engine.state.board = loaded.board;
    engine.state.history = loaded.history;

    // Free old optional fields (the loaded State does not own them)
    if (engine.data_dir) |old_dir| gpa.free(old_dir);
    if (engine.last_save_msg) |old_msg| gpa.free(old_msg);
    engine.data_dir = null;
    engine.last_save_msg = null;

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
        @import("../puzzle_gen.zig").PuzzleGen.default(),
        file_transport.NativeTransport.make(std.testing.io),
    );
    defer engine.deinit();

    const tmp_path = "/tmp/sudoku_open_command_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    engine.data_dir = try mypath.computeDataDir(std.heap.page_allocator);
    errdefer std.heap.page_allocator.free(engine.data_dir.?);

    const resolved = try mypath.resolveSavePath(
        std.heap.page_allocator,
        engine.data_dir.?,
        tmp_path,
    );
    defer std.heap.page_allocator.free(resolved);

    _ = engine.saveGame(resolved) catch return error.SkipZigTest;

    const event = execute(&engine, tmp_path);

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
        @import("../puzzle_gen.zig").PuzzleGen.default(),
        file_transport.NativeTransport.make(std.testing.io),
    );
    defer engine.deinit();

    const event = execute(&engine, null);

    switch (event) {
        .ok => |data| {
            try std.testing.expect(data.msg != null);
            try std.testing.expect(std.mem.indexOf(u8, data.msg.?, "no file") != null);
        },
        .error_msg => return error.TestFailed,
    }
}
