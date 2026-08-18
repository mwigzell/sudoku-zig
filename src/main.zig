// Entry point — parses CLI args, builds the Host (renderer substrate), starts the game loop.
const std = @import("std");
const facade = @import("renderer/facade.zig");
const sudoku = @import("sudoku.zig");
const config_module = @import("config.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");
const logger = @import("logger.zig");
const styler = @import("renderer/ascii/styler.zig");
const cli = @import("cli.zig");
// main constructs the Host at startup — the import is load-bearing: without it host.zig would not enter this file's test closure.
const host_mod = @import("host/host.zig");
// Load-bearing: wasm_bytes.zig must stay reachable from this closure for its tests.
const wasm_bytes = @import("renderer/wasm/wasm_bytes.zig");

test {
    // Reachability pin: keeps sudoku.zig (and its sub-modules) inside the test closure of this root file.
    _ = .{sudoku};
    _ = wasm_bytes;
}

pub fn main(init: std.process.Init) sudoku.Error!void {
    // Parse CLI flags (renderer, difficulty, log level) and apply the log severity before any further output.
    var arg_it = std.process.Args.iterate(init.minimal.args);
    const cfg = cli.parseCLI(&arg_it) catch unreachable;
    logger.min_level = cfg.log_level;

    const log = logger.Logger(.sudoku);
    log.debug("Starting sudoku game.", .{});

    // Host owns the renderer substrate and I/O session for this process (see host/host.zig).
    var host = host_mod.Host.create(cfg, init.io, std.heap.page_allocator);
    defer host.deinit();
    var game = sudoku.Sudoku.init(&host) catch |err| {
        // Renderer requested but not available in this build — tell the player which one, separately for "unimplemented" and "no fallback".
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

    // Command loop: menu → play → save/open, until the player quits or the game exits.
    try game.run();

    log.debug("Ending sudoku game.", .{});
}
