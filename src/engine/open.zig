/// Open command handler — deserializes game state from file via exec() dispatch.
const std = @import("std");
const game_engine = @import("game_engine.zig");
const mypath = @import("path.zig");

pub fn execute(engine: *game_engine.GameEngine, path: ?[]const u8) game_engine.Event {
    if (path) |file_path| {
        return doOpen(engine, file_path);
    } else {
        return .{
            .ok = .{
                .board_view = engine.board.asView(),
                .msg = "open: no file specified",
                .is_quit = false,
            },
        };
    }
}

fn doOpen(engine: *game_engine.GameEngine, file_path: []const u8) game_engine.Event {
    const gpa = std.heap.page_allocator;

    // Resolve the path through the data dir
    if (engine.data_dir == null) {
        engine.data_dir = mypath.getDataDir(gpa, engine.io) catch |err| {
            var buf: [80]u8 = undefined;
            return game_engine.Event{ .error_msg = std.fmt.bufPrint(&buf, "getDataDir: {s}", .{@errorName(err)}) catch "system error" };
        };
    }

    const resolved = mypath.resolveSavePath(
        gpa,
        engine.data_dir.?,
        file_path,
    ) catch |err| {
        var buf: [80]u8 = undefined;
        return game_engine.Event{ .error_msg = std.fmt.bufPrint(&buf, "resolveSavePath: {s}", .{@errorName(err)}) catch "system error" };
    };
    defer gpa.free(resolved);

    // Read file bytes
    var file = std.Io.Dir.openFileAbsolute(engine.io, resolved, .{}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };
    defer file.close(engine.io);

    const stat = std.Io.Dir.cwd().statFile(engine.io, resolved, .{}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };
    const buf = gpa.alloc(u8, stat.size) catch |err| {
        var errbuf: [80]u8 = undefined;
        return game_engine.Event{ .error_msg = std.fmt.bufPrint(&errbuf, "alloc: {s}", .{@errorName(err)}) catch "system error" };
    };
    defer gpa.free(buf);

    _ = std.Io.File.readPositionalAll(file, engine.io, buf, 0) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    // Deserialize into a new engine
    const loaded = game_engine.GameEngine.fromSaveFormat(gpa, engine.io, buf) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    // Replace self's state with loaded state
    engine.history.deinit();
    const old_board = engine.board;

    // Free old optional fields before overwriting self
    if (engine.data_dir) |old_dir| gpa.free(old_dir);
    if (engine.last_save_msg) |old_msg| gpa.free(old_msg);

    engine.* = loaded;
    _ = old_board;

    const msg = std.fmt.allocPrint(gpa, "opened: {s}", .{resolved}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    return .{
        .ok = .{
            .board_view = engine.board.asView(),
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
        std.testing.io,
    );
    defer engine.deinit();

    const tmp_path = "/tmp/sudoku_open_command_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    engine.data_dir = try mypath.getDataDir(std.heap.page_allocator, std.testing.io);
    errdefer std.heap.page_allocator.free(engine.data_dir.?);

    const resolved = try mypath.resolveSavePath(
        std.heap.page_allocator,
        engine.data_dir.?,
        tmp_path,
    );
    defer std.heap.page_allocator.free(resolved);

    _ = engine.saveGame(engine.io, resolved) catch return error.SkipZigTest;

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
        std.testing.io,
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
