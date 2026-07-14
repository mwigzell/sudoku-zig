const std = @import("std");
const game_engine = @import("game_engine.zig");
const std_renderer = @import("std_renderer.zig");
const io_sink = @import("io_sink.zig");
const default_puzzle = @import("default_puzzle.zig");

pub fn main(init: std.process.Init) anyerror!void {
    var sink = io_sink.IoSink.init(init.io).toStdout();
    var r = std_renderer.StdoutRenderer.init(&sink);
    var engine = try game_engine.GameEngine(std_renderer.StdoutRenderer).init(default_puzzle.default_puzzle, &r);

    try engine.render();
}
