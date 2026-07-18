//! Test root — imports all sub-modules so `addTest` discovers every co-located test block.
const cell = @import("cell.zig");
const board = @import("board.zig");
const game_engine = @import("game_engine.zig");
const mock_renderer = @import("mock_renderer.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const logger = @import("logger.zig");
const ascii_renderer = @import("ascii_renderer.zig");

test {
    _ = .{ cell, board, game_engine, mock_renderer, puzzle_gen, logger, ascii_renderer };
}
