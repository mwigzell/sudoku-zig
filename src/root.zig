//! Test root — imports all sub-modules so `addTest` discovers every co-located test block.
const cell = @import("cell.zig");
const board = @import("board.zig");
const render = @import("render.zig");

// Reference each module so Zig does not dead-code-eliminate them during test
// discovery. Without this, addTest sees no test blocks to run.
test "root: reference all sub-modules for test discovery" {
    _ = cell.Cell.init(.one);
    _ = board.Board.init;
    _ = render.cellChar(cell.Cell.init(.one));
}
