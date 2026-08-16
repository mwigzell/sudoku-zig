const std = @import("std");
const facade = @import("renderer/facade.zig");
const sudoku = @import("sudoku.zig");
const config_module = @import("config.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");
const logger = @import("logger.zig");
const styler = @import("renderer/ascii/styler.zig");
const cli = @import("cli.zig");
const input_source = @import("input_source.zig");
const io_session = @import("io_session.zig");

pub fn main(init: std.process.Init) sudoku.Error!void {
    const log = logger.Logger(.sudoku);
    log.debug("Starting sudoku game.", .{});

    var arg_it = std.process.Args.iterate(init.minimal.args);
    const cfg = cli.parseCLI(&arg_it) catch unreachable;

    const stdout_writer = std.Io.File.stdout().writer(init.io, &.{});
    var session = io_session.IoSession{
        .reader = .{ .stdin = input_source.StdinSource.initStdin(std.heap.page_allocator, init.io) },
        .writer = .{ .stdout = stdout_writer },
        .alloc = std.heap.page_allocator,
    };
    var game = sudoku.Sudoku.init(cfg, &session, init.io) catch |err| {
        if (err == error.UnsupportedRenderer) {
            std.debug.print(
                "Error: renderer '{s}' is not available in this build.\nAvailable renderers: ansi, ascii.\n",
                .{@tagName(cfg.preferred_renderer)},
            );
            std.process.exit(1);
        }
        return err;
    };
    try game.run();
    session.deinit();

    log.debug("Ending sudoku game.", .{});
}

test {
    _ = .{ sudoku, io_session };
}
