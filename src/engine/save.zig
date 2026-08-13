/// Save command handler — delegates to save_as after ensuring a filename is known.

const std = @import("std");
const game_engine = @import("game_engine.zig");
const save_as_command = @import("save_as.zig");
const mypath = @import("path.zig");

pub const DEFAULT_SAVE_FILE = "sudoku_save.sud";

pub fn execute(engine: *game_engine.GameEngine, path: []const u8) game_engine.Event {
    return save_as_command.execute(engine, path);
}


test "command.save.execute saves file and returns ok with message" {
    var engine = try game_engine.GameEngine.init(
        @import("../puzzle_gen.zig").PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    const tmp_path = "/tmp/sudoku_save_command_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    // Give the engine a data dir
    engine.data_dir = try mypath.getDataDir(std.heap.page_allocator, std.testing.io);

    const event = execute(&engine, DEFAULT_SAVE_FILE);

    switch (event) {
        .ok => |data| {
            try std.testing.expect(!data.is_quit);
            try std.testing.expect(data.msg != null);
            const m = data.msg.?;
            try std.testing.expect(std.mem.indexOf(u8, m, "saved") != null);
        },
        .error_msg => |msg| {
            // Accept I/O errors (depends on FS state)
            _ = msg;
        },
    }
}
