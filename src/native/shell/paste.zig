// Edit → Paste (native): prompt-supplied one-line string → engine `importFromLine`.
const game_engine = @import("../../engine/game_engine.zig");
const board = @import("../../board/board.zig");
const config = @import("../../config.zig");
const cell = @import("../../board/cell.zig");
const std = @import("std");
const PuzzleGen = @import("../../puzzle_gen/mod.zig").PuzzleGen;

pub fn execute(engine: *game_engine.GameEngine, line: ?[]const u8) game_engine.Event {
    if (line == null) return .{ .error_msg = "paste: no puzzle line specified" };
    return engine.importFromLine(line.?);
}

test "paste: valid line loads board and clears history" {
    const puzzle_line = PuzzleGen.hard();
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 2, .digit = cell.CellValue.seven } });
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());

    const expected = board.fromOneLineString(puzzle_line) catch unreachable;
    const result = execute(&engine, puzzle_line);
    switch (result) {
        .ok => {},
        .error_msg => return error.TestFailed,
    }
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.count());
    try std.testing.expect(board.equal(engine.state.board, expected));
}

test "paste: short line rejected; board and history unchanged" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 2, .digit = cell.CellValue.seven } });
    const pre = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(pre);

    const result = execute(&engine, PuzzleGen.default()[0..80]);
    switch (result) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());
    const post = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(post);
    try std.testing.expect(std.mem.eql(u8, pre, post));
}

test "paste: invalid character rejected; state unchanged" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 2, .digit = cell.CellValue.seven } });
    const pre = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(pre);

    var bad: [81]u8 = undefined;
    @memset(&bad, '1');
    bad[40] = 'z';

    const result = execute(&engine, &bad);
    switch (result) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }
    const post = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(post);
    try std.testing.expect(std.mem.eql(u8, pre, post));
}

test "paste: null line returns error without touching engine" {
    var engine = try game_engine.GameEngine.init(PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 1, .col = 1, .digit = cell.CellValue.three } });
    const pre = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(pre);

    const result = execute(&engine, null);
    try std.testing.expect(result == .error_msg);
    const post = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(post);
    try std.testing.expect(std.mem.eql(u8, pre, post));
}
