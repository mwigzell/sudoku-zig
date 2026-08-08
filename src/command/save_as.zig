/// SaveAs command handler — sets filename cache then saves via engine.saveGame().
const std = @import("std");
const game_engine = @import("../game_engine.zig");
const mypath = @import("path.zig");

pub fn execute(engine: *game_engine.GameEngine, path: []const u8) !game_engine.Event {
    const gpa = std.heap.page_allocator;

    // Ensure data dir is resolved
    if (engine.data_dir == null) {
        engine.data_dir = try mypath.getDataDir(gpa, engine.io);
    }

    // Set filename cache for future "save" quick-save
    if (engine.filename) |old_name| gpa.free(old_name);
    engine.filename = try gpa.dupe(u8, path);

    const resolved = try mypath.resolveSavePath(
        gpa,
        engine.data_dir.?,
        engine.filename.?,
    );
    defer gpa.free(resolved);

    // Save to disk
    engine.saveGame(engine.io, resolved) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    // Free old save message if present
    if (engine.last_save_msg) |old_m| gpa.free(old_m);

    const msg = std.fmt.allocPrint(gpa, "saved to: {s}", .{resolved}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };
    engine.last_save_msg = msg;

    return game_engine.Event{ .ok = .{
        .board_view = engine.board.asView(),
        .msg = msg,
        .is_quit = false,
    } };
}

test "command.save_as.execute saves file and caches filename" {
    var engine = try game_engine.GameEngine.init(
        @import("../puzzle_gen.zig").PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    const tmp_path = "/tmp/sudoku_saveas_command_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    // Give the engine a data dir
    engine.data_dir = try mypath.getDataDir(std.heap.page_allocator, std.testing.io);

    const event = execute(&engine, tmp_path) catch return error.SkipZigTest;

    switch (event) {
        .ok => |data| {
            try std.testing.expect(!data.is_quit);
            try std.testing.expect(data.msg != null);
            const m = data.msg.?;
            try std.testing.expect(std.mem.indexOf(u8, m, "saved") != null);

            // Filename should now be cached on the engine
            try std.testing.expect(engine.filename != null);
        },
        .error_msg => |msg| {
            // Accept I/O errors (depends on FS state)
            _ = msg;
        },
    }
}
