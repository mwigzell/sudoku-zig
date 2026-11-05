// Process entry: resolve startup config, dispatch to the desktop web or terminal entry arm.
const std = @import("std");
const config = @import("core/config.zig");
const shell = @import("native/shell/shell.zig");
const logger = @import("core/logger.zig");
const desktop_web = @import("native/desktop_web.zig");
const desktop_terminal = @import("native/desktop_terminal.zig");
const startup_config = @import("core/startup/config.zig");
const shell_path = @import("native/shell/path.zig");
// Wasm JSON contract tests — not reachable from the native play path (see entry_wasm.zig).
const wasm_wire = @import("wasm/wire.zig");
const wasm_boundary = @import("wasm/boundary.zig");
const settings_store = @import("core/settings_store.zig");
const web_host = @import("web_host/mod.zig");
const open_browser = @import("native/open_browser.zig");
const android_jni_host = @import("android/jni_host.zig");
const about = @import("core/about.zig");
const build_info = @import("build_info.zig");
const EntryArm = enum { web, terminal };

fn armLabel(arm: EntryArm) []const u8 {
    return switch (arm) {
        .web => "desktop web",
        .terminal => "desktop terminal",
    };
}

fn selectEntryArm(cfg: config.Config) EntryArm {
    if (cfg.preferred_renderer == .web) return .web;
    return .terminal;
}

test {
    _ = .{ shell, desktop_web, desktop_terminal, web_host, open_browser, android_jni_host, wasm_wire, wasm_boundary, startup_config, settings_store };
}

/// Resolve startup config and dispatch to web or terminal desktop entry.
pub fn main(init: std.process.Init) shell.Error!void {
    const log = logger.Logger(.sudoku);
    log.start("starting desktop: {s}", .{about.summaryLine(build_info.debug_build)});
    var arg_it = std.process.Args.iterate(init.minimal.args);
    const gpa = std.heap.page_allocator;
    const cfg = startup_config.resolveStartupConfig(gpa, init.io, &arg_it) catch unreachable;
    startup_config.applyLoggerFromStartup(cfg);

    const arm = selectEntryArm(cfg);
    log.info("entry arm: {s}", .{armLabel(arm)});

    const data_dir = shell_path.computeDataDir(gpa) catch |err| blk: {
        log.warn("data dir unavailable, using the working directory: {s}", .{@errorName(err)});
        break :blk ".";
    };
    defer if (!std.mem.eql(u8, data_dir, ".")) gpa.free(data_dir);

    if (arm == .web) {
        desktop_web.run(init.io, cfg, data_dir);
        return;
    }

    try desktop_terminal.run(init.io, gpa, cfg, data_dir);
}

test "selectEntryArm routes web renderer to desktop web entry" {
    var cfg = config.Config.default();
    cfg.preferred_renderer = .web;
    try std.testing.expectEqual(EntryArm.web, selectEntryArm(cfg));
}

test "selectEntryArm routes non-web renderers to terminal entry" {
    var cfg = config.Config.default();
    cfg.preferred_renderer = .ansi;
    try std.testing.expectEqual(EntryArm.terminal, selectEntryArm(cfg));
}
