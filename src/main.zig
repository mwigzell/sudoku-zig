const std = @import("std");
const game_engine = @import("game_engine.zig");
const std_renderer = @import("std_renderer.zig");

pub fn main(init: std.process.Init) anyerror!void {
    const puzzle = "67..4..524....1....53.87.91....12.85.2...46..7.5...21..47.3.52.5.62.8.499.....378";
    var buf: [8192]u8 = undefined;
    var r = std_renderer.StdoutRenderer.init(std.Io.Writer.fixed(&buf));
    var engine = try game_engine.GameEngine(std_renderer.StdoutRenderer).init(puzzle, &r);

    try engine.render();

    // print only the bytes that were actually written into buf
    const len: usize = r.w.end;
    var out_writer = std.Io.File.stdout().writer(init.io, &.{}) ;
    const stdout = &out_writer.interface;
    try stdout.writeAll(buf[0..len]);
}
