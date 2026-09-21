// Entry point — parses CLI args, builds the Host (renderer substrate), starts the game loop.
const std = @import("std");
const sudoku = @import("native/shell/sudoku.zig");
const logger = @import("logger.zig");
const cli = @import("native/cli.zig");
const host_mod = @import("native/host.zig");
const file_transport = @import("native/shell/file_transport.zig");
const serve = @import("native/serve.zig");
// Wasm JSON contract tests — not reachable from the native play path (see wasm_entry.zig).
const wasm_wire = @import("wasm/wire.zig");
const wasm_boundary = @import("wasm/boundary.zig");

// Test builds omit main(), so imports only used there are tree-shaken away.
// Pin roots whose tests must still run under `zig build test`.
test {
    _ = .{ sudoku, serve, wasm_wire, wasm_boundary };
}

pub fn main(init: std.process.Init) sudoku.Error!void {
    // Parse CLI flags (renderer, difficulty, log level) and apply the log severity before any further output.
    var arg_it = std.process.Args.iterate(init.minimal.args);
    const cfg = cli.parseCLI(&arg_it) catch unreachable;
    logger.min_level = cfg.log_level;

    const log = logger.Logger(.sudoku);
    log.debug("Starting sudoku game.", .{});

    // web deployment: the binary serves the embedded page and exits when every
    // asset has been delivered — no game loop, no Host.
    if (cfg.preferred_renderer == .web) {
        serve.serve(init.io, serve.openBrowser) catch |err| {
            if (err == serve.ServeError.AddressInUse) {
                log.fatal("web server failed to start — port {d} is already in use.", .{serve.Port});
            } else {
                log.fatal("web server failed to start: {s}.", .{@errorName(err)});
            }
        };
        return;
    }

    // Host owns the renderer substrate and I/O session for this process (see native/host.zig).
    var host = host_mod.Host.create(cfg, init.io, std.heap.page_allocator);
    defer host.deinit();
    var facade_f = host.facade() catch |err| {
        // Renderer requested but not available in this build — tell the player which one, separately for "unimplemented" and "no fallback".
        if (err == error.UnsupportedRenderer) {
            log.fatal(
                "renderer '{s}' is not available in this build.\nAvailable renderers: ansi, ascii.",
                .{@tagName(cfg.preferred_renderer)},
            );
        }
        if (err == error.NoFallbackConfigured) {
            log.fatal(
                "renderer '{s}' is unavailable and no fallback renderer is configured.",
                .{@tagName(cfg.preferred_renderer)},
            );
        }
        return err;
    };
    defer facade_f.deinit();
    var game = try sudoku.Sudoku.init(cfg, facade_f, file_transport.NativeTransport.make(host.io));
    defer game.deinit();

    // Command loop: menu → play → save/open, until the player quits.
    try game.showGame();
    while (true) if (try game.turn()) break;

    log.debug("Ending sudoku game.", .{});
}
