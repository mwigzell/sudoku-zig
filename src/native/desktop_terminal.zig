/// Desktop terminal play: Host substrate, renderer facade, native `Sudoku` command loop.
const std = @import("std");
const config = @import("../config.zig");
const logger = @import("../logger.zig");
const host_mod = @import("host.zig");
const sudoku = @import("shell/sudoku.zig");
const file_transport = @import("shell/file_transport.zig");
const settings_store = @import("../settings_store.zig");
const input_source = @import("input_source.zig");

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

    const current_file = if (settings_persist) |sp|
        settings_store.loadCurrentFile(gpa, sp.io, sp.data_dir) catch null
    else
        null;
    defer if (current_file) |path| gpa.free(path);

    const startup = try game.runStartupPolicy(current_file);
    if (startup.restore_failed) {
        // Restore errors are blocking for this run; after acknowledgement,
        // allow explicit cleanup and clear the pointer to avoid repeat failures.
        if (current_file) |failed_path| {
            maybeDeleteFailedRestoreFile(io, host.writer(), &game, failed_path);
        }
        if (settings_persist) |sp| {
            settings_store.setCurrentFile(gpa, sp.io, sp.data_dir, null) catch {};
        }
    }

    if (!startup.rendered) try game.showGameWithStatus(startup.startup_status);
    while (true) if (try game.turn()) break;

    log.debug("Ending sudoku game.", .{});
}

fn maybeDeleteFailedRestoreFile(io: std.Io, out: *std.Io.Writer, game: *sudoku.Sudoku, file_path: []const u8) void {
    out.print("restore failed for '{s}'. delete this file? [y/N]: ", .{file_path}) catch return;
    var prompt = input_source.StdinSource.initStdin(std.heap.page_allocator, io);
    const line = prompt.readLine() catch return;
    defer std.heap.page_allocator.free(line);

    if (line.len == 0) return;
    if (!(line[0] == 'y' or line[0] == 'Y')) return;

    const resolved = game.transport.resolve(game.transport.context, file_path) catch return;
    defer game.transport.free(game.transport.context, resolved);
    std.Io.Dir.deleteFileAbsolute(io, resolved) catch {};
}
