/// Import command handler — loads a one-line puzzle text file through the
/// transport seam, swaps the board and clears mutation history.
///
/// Failures (missing file, wrong length, invalid characters) surface as an
/// error message and leave board and history untouched.
const std = @import("std");
const game_engine = @import("../../engine/game_engine.zig");
const board = @import("../../board/board.zig");
const file_transport = @import("file_transport.zig");

pub fn execute(engine: *game_engine.GameEngine, transport: file_transport.FileTransport, path: ?[]const u8) game_engine.Event {
    if (path == null) {
        return .{ .error_msg = "import: no file specified" };
    }
    return doImport(engine, transport, path.?);
}

fn doImport(engine: *game_engine.GameEngine, transport: file_transport.FileTransport, file_path: []const u8) game_engine.Event {
    const resolved = transport.resolve(transport.context, file_path) catch {
        return .{ .error_msg = "import: cannot read file" };
    };
    defer transport.free(transport.context, resolved);

    const buf = transport.readAll(transport.context, resolved) catch {
        return .{ .error_msg = "import: cannot read file" };
    };
    defer transport.free(transport.context, buf);

    return engine.importFromLine(buf);
}

// ---------------------------------------------------------------------------
// Tests — verify import handler seam: success swaps board and clears history,
// failures leave state untouched
// ---------------------------------------------------------------------------

test "import: valid puzzle file loads board and clears history" {
    file_transport.NativeTransport.resetSession();
    defer file_transport.NativeTransport.deinitSession();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    const tmp_path = "/tmp/sudoku_import_valid_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    const puzzle_line = PuzzleGen.default();
    try transport.write(transport.context, tmp_path, puzzle_line);

    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), @import("../../config.zig").Config.default());
    defer engine.deinit();
    _ = engine.exec(@import("../../command.zig").Command{
        .fill = @import("../../command.zig").FillData{ .row = 0, .col = 2, .digit = @import("../../board/cell.zig").CellValue.seven },
    });
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());

    const expected = board.fromOneLineString(puzzle_line) catch unreachable;

    const result = execute(&engine, transport, tmp_path);
    switch (result) {
        .ok => {},
        .error_msg => return error.TestFailed,
    }

    try std.testing.expectEqual(@as(usize, 0), engine.state.history.count());
    try std.testing.expect(board.equal(engine.state.board, expected));
}

test "import: 80 char file rejected, board and history unchanged" {
    file_transport.NativeTransport.resetSession();
    defer file_transport.NativeTransport.deinitSession();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    const tmp_path = "/tmp/sudoku_import_short_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    const puzzle_line = PuzzleGen.default();
    try transport.write(transport.context, tmp_path, puzzle_line[0..80]);

    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), @import("../../config.zig").Config.default());
    defer engine.deinit();
    _ = engine.exec(@import("../../command.zig").Command{
        .fill = @import("../../command.zig").FillData{ .row = 0, .col = 2, .digit = @import("../../board/cell.zig").CellValue.seven },
    });

    const pre = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(pre);

    const result = execute(&engine, transport, tmp_path);
    switch (result) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }

    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());
    const post = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(post);
    try std.testing.expect(std.mem.eql(u8, pre, post));
}

test "import: file with an invalid character rejected, state unchanged" {
    file_transport.NativeTransport.resetSession();
    defer file_transport.NativeTransport.deinitSession();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    const tmp_path = "/tmp/sudoku_import_badchar_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    const puzzle_line = PuzzleGen.default();
    var bad_line: [81]u8 = undefined;
    @memset(&bad_line, 'X');
    @memcpy(&bad_line, puzzle_line);
    bad_line[40] = 'X';
    try transport.write(transport.context, tmp_path, &bad_line);

    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), @import("../../config.zig").Config.default());
    defer engine.deinit();
    _ = engine.exec(@import("../../command.zig").Command{
        .fill = @import("../../command.zig").FillData{ .row = 0, .col = 2, .digit = @import("../../board/cell.zig").CellValue.seven },
    });

    const pre = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(pre);

    const result = execute(&engine, transport, tmp_path);
    switch (result) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }

    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());
    const post = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(post);
    try std.testing.expect(std.mem.eql(u8, pre, post));
}

test "import: missing file rejected, board and history unchanged" {
    file_transport.NativeTransport.resetSession();
    defer file_transport.NativeTransport.deinitSession();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, "/tmp/sudoku_import_missing_test.txt") catch {};

    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), @import("../../config.zig").Config.default());
    defer engine.deinit();
    _ = engine.exec(@import("../../command.zig").Command{
        .fill = @import("../../command.zig").FillData{ .row = 0, .col = 2, .digit = @import("../../board/cell.zig").CellValue.seven },
    });

    const pre = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(pre);

    const result = execute(&engine, transport, "/tmp/sudoku_import_missing_test.txt");
    switch (result) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }

    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());
    const post = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(post);
    try std.testing.expect(std.mem.eql(u8, pre, post));
}

const PuzzleGen = @import("../../puzzle_gen.zig").PuzzleGen;
