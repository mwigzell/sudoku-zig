const std = @import("std");
const game_engine = @import("game_engine.zig");
const std_renderer = @import("std_renderer.zig");
const default_puzzle = @import("default_puzzle.zig");

pub fn main(init: std.process.Init) anyerror!void {
    var r = std_renderer.StdoutRenderer.init(init.io);
    var engine = try game_engine.GameEngine(std_renderer.StdoutRenderer).init(default_puzzle.default_puzzle, &r);

    try engine.render(); } 
