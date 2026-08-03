/// Open command handler — deserializes game state from file via exec() dispatch.
const std = @import("std");
const game_engine = @import("../game_engine.zig");
const mypath = @import("path.zig");

pub fn execute(engine: *game_engine.GameEngine, path: []const u8) !game_engine.Event {
    const gpa = std.heap.page_allocator;

    // Resolve the path through the data dir
    if (engine._data_dir == null) {
        engine._data_dir = try mypath.getDataDir(gpa, engine._io);
        errdefer gpa.free(engine._data_dir.?);
    }

    const resolved = try mypath.resolveSavePath(
        gpa,
        engine._data_dir.?,
        path,
    );
    defer gpa.free(resolved);

    // Read file bytes
    var file = std.Io.Dir.openFileAbsolute(engine._io, resolved, .{}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };
    defer file.close(engine._io);

    const stat = std.Io.Dir.cwd().statFile(engine._io, resolved, .{}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };
    const buf = try gpa.alloc(u8, stat.size);
    defer gpa.free(buf);

    _ = std.Io.File.readPositionalAll(file, engine._io, buf, 0) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    // Deserialize into a new engine
    const loaded = game_engine.GameEngine.fromSaveFormat(gpa, engine._io, buf) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    // Replace self's state with loaded state
    engine.history.deinit();
    const old_board = engine.board;

    // Free old optional fields before overwriting self
    if (engine._data_dir) |old_dir| gpa.free(old_dir);
    if (engine._filename) |old_name| gpa.free(old_name);
    if (engine._last_save_msg) |old_msg| gpa.free(old_msg);

    engine.* = loaded;
    _ = old_board;

    const msg = std.fmt.allocPrint(gpa, "opened: {s}", .{resolved}) catch |err| {
        return game_engine.Event{ .error_msg = @errorName(err) };
    };

    return game_engine.Event{ .ok = .{
        .board_view = engine.board.asView(),
        .msg = msg,
        .is_quit = false,
    } };
}
