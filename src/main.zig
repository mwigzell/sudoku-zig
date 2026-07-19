const std = @import("std");
const game_engine = @import("game_engine.zig");
const ascii_renderer = @import("ascii_renderer.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const logger = @import("logger.zig");
const styler = @import("styler.zig");

pub fn main(init: std.process.Init) anyerror!void {
    logger.Logger(.sudoku).debug("Starting sudoku game.", .{});
    var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});

    var s = styler.AnsiStyler{};
    const R = ascii_renderer.AsciiRenderer(styler.AnsiStyler);
    var r = R.init(&stdout_writer.interface, &s);
    var engine = try game_engine.GameEngine(R).init(puzzle_gen.PuzzleGen.easy(), &r);
    try engine.render();
}
