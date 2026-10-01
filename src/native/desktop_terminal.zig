/// Desktop terminal play: Host substrate, renderer facade, native `Sudoku` command loop.
const std = @import("std");
const config = @import("../config.zig");
const logger = @import("../logger.zig");
const host_mod = @import("host.zig");
const sudoku = @import("shell/sudoku.zig");
const file_transport = @import("shell/file_transport.zig");

const log = logger.Logger(.sudoku);

pub fn run(io: std.Io, gpa: std.mem.Allocator, cfg: config.Config, data_dir: []const u8) sudoku.Error!void {
    var host = host_mod.Host.create(cfg, io, gpa);
    defer host.deinit();
    var facade_f = host.facade() catch |err| {
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

    const settings_persist: ?sudoku.SettingsPersist = if (std.mem.eql(u8, data_dir, "."))
        null
    else
        .{ .io = io, .data_dir = data_dir };

    var game = try sudoku.Sudoku.init(cfg, facade_f, file_transport.NativeTransport.make(host.io), host.writer(), settings_persist);
    defer game.deinit();

    try game.showGame();
    while (true) if (try game.turn()) break;

    log.debug("Ending sudoku game.", .{});
}
