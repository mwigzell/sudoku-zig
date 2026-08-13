const std = @import("std");
const facade = @import("renderer/facade.zig");
const sudoku = @import("sudoku.zig");
const config_module = @import("config.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");
const logger = @import("logger.zig");
const styler = @import("renderer/ascii/styler.zig");
const cli = @import("cli.zig");
const input_source = @import("input_source.zig");

pub fn main(init: std.process.Init) sudoku.Error!void {
    const log = logger.Logger(.sudoku);
    log.debug("Starting sudoku game.", .{});

    var arg_it = std.process.Args.iterate(init.minimal.args);
    const cfg = cli.parseCLI(&arg_it) catch unreachable;

    // var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});
    // stdout_writer.interface.print("\x1b[2J\x1b[H", .{}) catch return error.System;

    // var s = styler.AnsiStyler{};
    // const R = ascii_renderer.AsciiRenderer(styler.AnsiStyler);

    // var renderer = R.init(std.heap.page_allocator, init.io, &stdout_writer.interface, &s, .{ .stdin = input_source.StdinSource.initStdin(std.heap.page_allocator) });

    // const f = facade.Make(R).make(&renderer);
    const is: input_source.ReaderSource = .{ .stdin = input_source.StdinSource.initStdin(std.heap.page_allocator) };
    var game = try sudoku.Sudoku.init(cfg, is, init);
    try game.run();

    log.debug("Ending sudoku game.", .{});
}
