//! Test root — imports all sub-modules so `addTest` discovers every co-located test block.
const box = @import("box.zig");
const cell = @import("cell.zig");
const grid = @import("grid.zig");
const board = @import("board.zig");
const renderer = @import("renderer.zig");
const game_engine = @import("game_engine.zig");
const mock_renderer = @import("mock_renderer.zig");
const std_renderer = @import("std_renderer.zig");
const io_sink = @import("io_sink.zig");

test {
    _ = .{ box, cell, grid, board, renderer, game_engine, std_renderer, io_sink };
}
