// Process entry: resolve startup config, dispatch to the desktop web or terminal entry arm.
const std = @import("std");
const sudoku = @import("native/shell/sudoku.zig");
const logger = @import("logger.zig");
const desktop_web = @import("native/desktop_web.zig");
const desktop_terminal = @import("native/desktop_terminal.zig");
const startup_config = @import("startup_config.zig");
const shell_path = @import("native/shell/path.zig");
// Wasm JSON contract tests — not reachable from the native play path (see wasm_entry.zig).
const wasm_wire = @import("wasm/wire.zig");
const wasm_boundary = @import("wasm/boundary.zig");
const settings_store = @import("settings_store.zig");
const web_host = @import("web_host/mod.zig");
const open_browser = @import("native/open_browser.zig");
const android_jni_host = @import("android/jni_host.zig");

test {
    _ = .{ sudoku, desktop_web, desktop_terminal, web_host, open_browser, android_jni_host, wasm_wire, wasm_boundary, startup_config, settings_store };
}

pub fn main(init: std.process.Init) sudoku.Error!void {
    var arg_it = std.process.Args.iterate(init.minimal.args);
    const gpa = std.heap.page_allocator;
    const cfg = startup_config.resolveStartupConfig(gpa, init.io, &arg_it) catch unreachable;
    startup_config.applyLoggerFromStartup(cfg);

    const log = logger.Logger(.sudoku);
    log.debug("Starting sudoku game.", .{});

    const data_dir = shell_path.computeDataDir(gpa) catch ".";
    defer if (!std.mem.eql(u8, data_dir, ".")) gpa.free(data_dir);

    if (cfg.preferred_renderer == .web) {
        desktop_web.run(init.io, cfg, data_dir);
        return;
    }

    try desktop_terminal.run(init.io, gpa, cfg, data_dir);
}
