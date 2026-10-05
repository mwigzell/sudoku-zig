// Shared startup engine constructor: explicit empty-grid baseline + logger sync.
const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const game_engine = @import("engine/game_engine.zig");
const cell = @import("board/cell.zig");

fn emptyPuzzleLine() [81]u8 {
    var line: [81]u8 = undefined;
    @memset(&line, '0');
    return line;
}

/// Build a startup `GameEngine` from resolved startup config.
/// startup: full startup config after settings + CLI resolution.
/// Returns: empty-grid engine carrying the startup config and synced log level.
pub fn initEngineFromStartup(startup: config.Config) game_engine.Error!game_engine.GameEngine {
    logger.min_level = startup.log_level;
    return game_engine.GameEngine.init(emptyPuzzleLine()[0..], startup);
}

test "initEngineFromStartup seeds empty board and syncs startup config + logger" {
    var startup = config.Config.default();
    startup.difficulty = .hard;
    startup.log_level = .warn;
    startup.theme = .light;
    startup.show_region = true;
    startup.warn_solvability = true;
    startup.auto_restore = true;
    startup.auto_new = true;
    startup.auto_save = true;

    var engine = try initEngineFromStartup(startup);
    defer engine.deinit();

    try std.testing.expectEqual(startup.log_level, logger.min_level);

    const live = engine.getConfig();
    try std.testing.expectEqual(startup.difficulty, live.difficulty);
    try std.testing.expectEqual(startup.log_level, live.log_level);
    try std.testing.expectEqual(startup.theme, live.theme);
    try std.testing.expectEqual(startup.show_region, live.show_region);
    try std.testing.expectEqual(startup.warn_solvability, live.warn_solvability);
    try std.testing.expectEqual(startup.auto_restore, live.auto_restore);
    try std.testing.expectEqual(startup.auto_new, live.auto_new);
    try std.testing.expectEqual(startup.auto_save, live.auto_save);

    const board = engine.eventBoard();
    var row: u4 = 0;
    while (row < 9) : (row += 1) {
        var col: u4 = 0;
        while (col < 9) : (col += 1) {
            try std.testing.expectEqual(cell.CellValue.zero, board.get(row, col));
        }
    }
}
