/// Desktop `-r web`: loopback host + browser open (entry-layer wiring, not `web_host` internals).
const std = @import("std");
const config = @import("../core/config.zig");
const logger = @import("../core/logger.zig");
const web_host = @import("../web_host/mod.zig");
const open_browser = @import("open_browser.zig");
const shell_path = @import("shell/path.zig");

const log = logger.Logger(.sudoku);

fn whenHostReady(io: std.Io, url: []const u8) void {
    open_browser.openBrowser(io, url) catch |err| switch (err) {
        open_browser.OpenError.Unavailable => log.info("no browser available — open {s} yourself", .{url}),
    };
}

/// Blocks until the loopback host stops. `data_dir` is caller-owned for settings POST persistence.
pub fn run(io: std.Io, cfg: config.Config, data_dir: []const u8) void {
    const gpa = std.heap.page_allocator;
    const visible_save_dir: ?[]u8 = shell_path.computeVisibleSaveDir(gpa) catch |err| blk: {
        log.warn("visible save folder unavailable, saving in the data dir: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (visible_save_dir) |dir| gpa.free(dir);
    web_host.runWithHostConfig(io, web_host.bindLoopback, cfg, data_dir, visible_save_dir orelse data_dir, whenHostReady) catch |err| {
        if (err == web_host.ServeError.AddressInUse) {
            log.fatal("web server failed to start — port {d} is already in use.", .{web_host.Port});
        } else {
            log.fatal("web server failed to start: {s}.", .{@errorName(err)});
        }
    };
}
