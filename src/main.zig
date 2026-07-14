const std = @import("std");
const game_engine = @import("game_engine.zig");
const std_renderer = @import("std_renderer.zig");
const io_sink = @import("io_sink.zig");
const default_puzzle = @import("default_puzzle.zig");

pub fn main(init: std.process.Init) anyerror!void {
    var real_sink = io_sink.IoSink.initStdout(init.io);
    defer real_sink.deinit(std.heap.page_allocator);

    var r = std_renderer.StdoutRenderer.init(.{ .file = &real_sink });
    var engine = try game_engine.GameEngine(std_renderer.StdoutRenderer).init(default_puzzle.default_puzzle, &r);

    try engine.render();
}
