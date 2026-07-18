const std = @import("std");
const game_engine = @import("game_engine.zig");
const ascii_renderer = @import("ascii_renderer.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const logger = @import("logger.zig");

pub fn main(init: std.process.Init) anyerror!void {
    logger.Logger(.sudoku).debug("Starting sudoku game.", .{});
    var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});

    var r = ascii_renderer.AsciiRenderer.init(&stdout_writer.interface);
    var engine = try game_engine.GameEngine(ascii_renderer.AsciiRenderer).init(puzzle_gen.PuzzleGen.easy(), &r);

    try engine.render();
}
