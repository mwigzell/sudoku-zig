/// Desktop terminal play: Host substrate, renderer facade, native `Sudoku` command loop.
const std = @import("std");
const config = @import("../config.zig");
const logger = @import("../logger.zig");
const settings_store = @import("../settings_store.zig");
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

    var startup_msg: ?[]const u8 = null;
    var owned_startup_msg: ?[]u8 = null;
    defer if (owned_startup_msg) |m| gpa.free(m);
    if (settings_persist) |sp| {
        const previous = settings_store.loadSessionMetaOrNull(gpa, io, sp.data_dir) catch null;
        defer if (previous) |value| settings_store.freeSessionMeta(gpa, value);
        if (previous != null and previous.?.current_file != null) {
            const path_value = previous.?.current_file.?;
            const restored = game.restoreFromPath(path_value);
            switch (restored) {
                .ok => |ev| startup_msg = ev.msg,
                .error_msg => |msg| {
                    const owned = std.fmt.allocPrint(gpa, "startup restore skipped: {s}", .{msg}) catch null;
                    if (owned) |value| {
                        owned_startup_msg = value;
                        startup_msg = value;
                    } else {
                        startup_msg = "startup restore skipped";
                    }
                },
            }
        }
    }

    try game.renderer.render(game.engine.eventBoard(), startup_msg, null);
    try game.renderer.showLegend(game.engine.getLegend());
    while (true) if (try game.turn()) break;

    log.debug("Ending sudoku game.", .{});
}
