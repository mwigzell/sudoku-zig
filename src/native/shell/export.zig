// Puzzle line encoder for File → Export and Edit → Copy; the flow decides where the line goes.
const board = @import("../../core/board/board.zig");
const game_engine = @import("../../core/engine/game_engine.zig");

/// The current grid as one 81-char line (wasm uses the same codec in-engine).
pub fn currentPuzzleLine(engine: *const game_engine.GameEngine) [81]u8 {
    return board.toOneLineString(engine.state.board);
}
