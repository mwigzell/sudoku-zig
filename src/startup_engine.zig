// Shared startup engine constructor: explicit empty-grid baseline + logger sync.
const config = @import("config.zig");
const logger = @import("logger.zig");
const game_engine = @import("engine/game_engine.zig");

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
