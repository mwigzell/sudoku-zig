const std = @import("std");
const facade = @import("renderer/facade.zig");
const sudoku = @import("sudoku.zig");
const config_module = @import("config.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");
const logger = @import("logger.zig");
const styler = @import("renderer/ascii/styler.zig");
const input_source = @import("input_source.zig");

pub fn main(init: std.process.Init) anyerror!void {
    const log = logger.Logger(.sudoku);
    log.debug("Starting sudoku game.", .{});

    var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});
    try stdout_writer.interface.print("\x1b[2J\x1b[H", .{});
    const cfg = config_module.Config.default();

    var s = styler.AnsiStyler{};
    const R = ascii_renderer.AsciiRenderer(styler.AnsiStyler);

    var renderer = R.init(std.heap.page_allocator, init.io, &stdout_writer.interface, &s, .{ .stdin = input_source.StdinSource.initStdin(std.heap.page_allocator) });

    const f = facade.Make(R).make(&renderer);
    var game = try sudoku.Sudoku.init(cfg, &f, init.io);
    game.run() catch |err| {
        if (err == error.ReadEOF) {
            log.debug("bye!", .{});
            return; // EOF — user pressed Ctrl-D, normal exit.
        }

        log.err("run: {s}", .{@errorName(err)});
    };
    log.debug("Ending sudoku game.", .{});
}
