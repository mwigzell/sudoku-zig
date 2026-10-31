/// Desktop terminal play: Host substrate, renderer facade, native `Sudoku` command loop.
const std = @import("std");
const config = @import("../core/config.zig");
const logger = @import("../core/logger.zig");
const host_mod = @import("host.zig");
const sudoku = @import("shell/shell.zig");
const file_transport = @import("shell/file_transport.zig");
const settings_store = @import("../core/settings_store.zig");
const shell_path = @import("shell/path.zig");

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

    const visible_save_dir: ?[]u8 = shell_path.computeVisibleSaveDir(gpa) catch null;
    defer if (visible_save_dir) |dir| gpa.free(dir);
    const settings_persist: ?sudoku.SettingsPersist = if (std.mem.eql(u8, data_dir, "."))
        null
    else
        .{ .io = io, .data_dir = data_dir, .visible_save_dir = visible_save_dir orelse data_dir };

    var game = try sudoku.Sudoku.init(cfg, facade_f, file_transport.NativeTransport.make(host.io), host.writer(), settings_persist);
    defer game.deinit();

    const current_file = if (settings_persist) |sp|
        settings_store.loadCurrentFile(gpa, sp.io, sp.data_dir) catch null
    else
        null;
    defer if (current_file) |path| gpa.free(path);

    try game.runStartupFlow(current_file);
    while (true) if (try game.turn()) break;

    log.debug("Ending sudoku game.", .{});
}
