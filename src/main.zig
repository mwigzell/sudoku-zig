// Entry point — parses CLI args, builds the Host (renderer substrate), starts the game loop.
const std = @import("std");
const facade = @import("renderer/facade.zig");
const sudoku = @import("sudoku.zig");
const config_module = @import("config.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");
const logger = @import("logger.zig");
const styler = @import("renderer/ascii/styler.zig");
const cli = @import("cli.zig");
// main constructs the Host at startup — host.zig stays in the suite closure.
const host_mod = @import("host/host.zig");

test "host module is part of the test closure" {
    _ = host_mod;
}

pub fn main(init: std.process.Init) sudoku.Error!void {
    var arg_it = std.process.Args.iterate(init.minimal.args);
    const cfg = cli.parseCLI(&arg_it) catch unreachable;

    // Apply the requested log severity once, before any further output.
    logger.min_level = cfg.log_level;

    const log = logger.Logger(.sudoku);
    log.debug("Starting sudoku game.", .{});

    var host = host_mod.Host.create(cfg, init.io, std.heap.page_allocator);
    defer host.deinit();
    var game = sudoku.Sudoku.init(&host) catch |err| {
        if (err == error.UnsupportedRenderer) {
            std.debug.print(
                "Error: renderer '{s}' is not available in this build.\nAvailable renderers: ansi, ascii.\n",
                .{@tagName(cfg.preferred_renderer)},
            );
            std.process.exit(1);
        }
        if (err == error.NoFallbackConfigured) {
            std.debug.print(
                "Error: renderer '{s}' is unavailable and no fallback renderer is configured.\n",
                .{@tagName(cfg.preferred_renderer)},
            );
            std.process.exit(1);
        }
        return err;
    };
    defer game.deinit();
    try game.run();

    log.debug("Ending sudoku game.", .{});
}

test {
    _ = .{sudoku};
}
