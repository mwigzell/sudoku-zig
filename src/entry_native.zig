// Process entry: resolve startup config, dispatch to the desktop web or terminal entry arm.
const std = @import("std");
const config = @import("core/config.zig");
const shell = @import("native/shell/shell.zig");
const logger = @import("core/logger.zig");
const desktop_web = @import("native/desktop_web.zig");
const desktop_terminal = @import("native/desktop_terminal.zig");
const startup_config = @import("core/startup/config.zig");
const shell_path = @import("native/shell/path.zig");
const cli = @import("native/cli.zig");
// Wasm JSON contract tests — not reachable from the native play path (see entry_wasm.zig).
const wasm_wire = @import("wasm/wire.zig");
const wasm_boundary = @import("wasm/boundary.zig");
const config_store = @import("core/config_store.zig");
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
    if (cfg.renderers.preferred == .web) return .web;
    return .terminal;
}

test {
    _ = .{ shell, desktop_web, desktop_terminal, web_host, open_browser, android_jni_host, wasm_wire, wasm_boundary, startup_config, config_store, cli };
    // Layering gate: no file-scope import under `src/core/` may reach the native adapters.
    _ = @import("test/layering.zig");
}

/// Resolve startup config and dispatch to web or terminal desktop entry.
pub fn main(init: std.process.Init) shell.Error!void {
    const log = logger.Logger(.sudoku);
    log.start("starting desktop: {s}", .{about.summaryLine(build_info.debug_build)});
    var arg_it = std.process.Args.iterate(init.minimal.args);
    const overrides = cli.parseOverrides(&arg_it);
    const gpa = std.heap.page_allocator;
    // The platform convention is this entry's to resolve; core receives the path, or why there is none.
    const computed_dir = shell_path.computeDataDir(gpa);
    defer if (computed_dir) |dir| gpa.free(dir) else |_| {};
    const host_dir: startup_config.DataDir = if (computed_dir) |dir|
        .{ .resolved = dir }
    else |err|
        startup_config.DataDir.noDataDir(@errorName(err));

    const cfg = try startup_config.resolveStartupConfig(gpa, init.io, host_dir, overrides);
    startup_config.applyLoggerFromStartup(cfg);

    const arm = selectEntryArm(cfg);
    log.info("entry arm: {s}", .{armLabel(arm)});

    const run_dir = startup_config.dataDirOrWorkingDir(host_dir);
    if (arm == .web) {
        desktop_web.run(init.io, cfg, run_dir);
        return;
    }

    try desktop_terminal.run(init.io, gpa, cfg, run_dir);
}

test "selectEntryArm routes web renderer to desktop web entry" {
    var cfg = config.Config.default();
    cfg.renderers.preferred = .web;
    try std.testing.expectEqual(EntryArm.web, selectEntryArm(cfg));
}

test "selectEntryArm routes non-web renderers to terminal entry" {
    var cfg = config.Config.default();
    cfg.renderers.preferred = .ansi;
    try std.testing.expectEqual(EntryArm.terminal, selectEntryArm(cfg));
}

test "the startup seam fails only with errors this entry's main already carries" {
    const seam_set = @typeInfo(@typeInfo(@TypeOf(startup_config.resolveStartupConfig)).@"fn".return_type.?).error_union.error_set;
    const seam_names = @typeInfo(seam_set).error_set.error_names.?;
    const main_names = @typeInfo(shell.Error).error_set.error_names.?;
    try std.testing.expect(seam_names.len > 0);
    for (seam_names) |name| {
        const carried = for (main_names) |main_name| {
            if (std.mem.eql(u8, name, main_name)) break true;
        } else false;
        try std.testing.expect(carried);
    }
}
