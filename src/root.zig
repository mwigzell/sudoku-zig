//! Test root — imports all sub-modules so `addTest` discovers every co-located test block.
const box = @import("box.zig");
const cell = @import("cell.zig");
const grid = @import("grid.zig");
const board = @import("board.zig");
const render = @import("render.zig");

test {
    _ = .{ box, cell, grid, board, render };
}
