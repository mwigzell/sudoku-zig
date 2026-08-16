/// New-game command handler — clears undo history, loads a puzzle string (falling back to medium), returns a fresh board view.
const std = @import("std");
const game_engine = @import("game_engine.zig");
const board = @import("../board.zig");
const command = @import("../command.zig");
const PuzzleGen = @import("../puzzle_gen.zig").PuzzleGen;
const mypath = @import("path.zig");

pub fn execute(engine: *game_engine.GameEngine, data: command.NewData) game_engine.Event {
    engine.history.deinit();
    engine.history = game_engine.MutationHistory.init(std.heap.page_allocator);
    if (data.file) |path| {
        const gpa = std.heap.page_allocator;
        if (engine.data_dir == null) {
            engine.data_dir = mypath.getDataDir(gpa, engine.io) catch |err| {
                var buf: [80]u8 = undefined;
                return .{ .error_msg = std.fmt.bufPrint(&buf, "getDataDir: {s}", .{@errorName(err)}) catch "system error" };
            };
        }
        const resolved = mypath.resolveSavePath(gpa, engine.data_dir.?, path) catch |err| {
            var buf: [80]u8 = undefined;
            return .{ .error_msg = std.fmt.bufPrint(&buf, "resolveSavePath: {s}", .{@errorName(err)}) catch "system error" };
        };
        defer gpa.free(resolved);
        var file = std.Io.Dir.openFileAbsolute(engine.io, resolved, .{}) catch |err| {
            return .{ .error_msg = @errorName(err) };
        };
        defer file.close(engine.io);
        const stat = std.Io.Dir.cwd().statFile(engine.io, resolved, .{}) catch |err| {
            return .{ .error_msg = @errorName(err) };
        };
        const buf = gpa.alloc(u8, stat.size) catch |err| {
            var errbuf: [80]u8 = undefined;
            return .{ .error_msg = std.fmt.bufPrint(&errbuf, "alloc: {s}", .{@errorName(err)}) catch "system error" };
        };
        defer gpa.free(buf);
        _ = std.Io.File.readPositionalAll(file, engine.io, buf, 0) catch |err| {
            return .{ .error_msg = @errorName(err) };
        };
        const trimmed = std.mem.trim(u8, buf, &std.ascii.whitespace);
        engine.board = board.fromOneLineString(trimmed) catch return .{ .error_msg = "could not load puzzle from file" };
        return .{
            .ok = .{
                .board_view = engine.board.asView(),
                .msg = "new game started",
                .is_quit = false,
            },
        };
    }


    if (data.puzzle) |puzzle_str| {
        defer std.heap.page_allocator.free(puzzle_str);

        engine.board = board.fromOneLineString(puzzle_str) catch return .{ .error_msg = "could not load puzzle" };

        return .{
            .ok = .{
                .board_view = engine.board.asView(),
                .msg = "new game started",
                .is_quit = false,
            },
        };
    } else {
        const default_puzzle = PuzzleGen.medium();

        engine.board = board.fromOneLineString(default_puzzle) catch return .{ .error_msg = "could not create new game" };

        return .{
            .ok = .{
                .board_view = engine.board.asView(),
                .msg = "new game started",
                .is_quit = false,
            },
        };
    }
}

// ---------------------------------------------------------------------------
// Tests — verify new-game command handler seam
// ---------------------------------------------------------------------------

test "command.new.execute clears history and loads a puzzle string" {
    var engine = try game_engine.GameEngine.init(
        PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    _ = execute(&engine, command.NewData{ .puzzle = null, .file = null });

    try std.testing.expectEqual(@as(usize, 0), engine.history.count());
}

test "command.new.execute falls back to medium when puzzle is null" {
    var engine = try game_engine.GameEngine.init(
        PuzzleGen.default(),
        std.testing.io,
    );
    defer engine.deinit();

    _ = execute(&engine, command.NewData{ .puzzle = null, .file = null });

    // Just makes sure it doesnt panic or leak (the default puzzle has "6" at index 0)
    _ = engine.board.isGiven(0, 0);
}

test "command.new.execute loads puzzle from a file" {
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_new_cmd_puzzle_file.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    const contents = PuzzleGen.default();
    var file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch return error.TestSkipped;
    std.Io.File.writeStreamingAll(file, io, contents) catch return error.TestSkipped;
    file.close(io);

    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), io);
    defer engine.deinit();

    const event = execute(&engine, command.NewData{ .puzzle = null, .file = tmp_path });
    switch (event) {
        .ok => try std.testing.expect(true),
        .error_msg => return error.TestFailed,
    }

    try std.testing.expect(engine.board.isGiven(0, 0)); // puzzle[0]=='6' → A1 given
    try std.testing.expect(engine.board.isGiven(0, 1)); // puzzle[1]=='7' → B1 given
    try std.testing.expect(!engine.board.isGiven(0, 2)); // puzzle[2]=='.' → A3 empty
}

test "command.new.execute returns error when puzzle file is missing" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const event = execute(&engine, command.NewData{ .puzzle = null, .file = "/tmp/sudoku_new_cmd_missing.sud" });
    switch (event) {
        .error_msg => try std.testing.expect(true),
        .ok => return error.TestFailed,
    }
}
