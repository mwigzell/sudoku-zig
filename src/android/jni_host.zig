//! Android host logic — JNI name mangling lives in `android_shared.zig` at the `src/` module root.
const std = @import("std");
const web_host = @import("../web_host/mod.zig");
const config = @import("../config.zig");

const HostState = struct {
    thread: ?std.Thread = null,
    threaded: ?*std.Io.Threaded = null,
    data_dir: []const u8 = ".",
};

var host_state: HostState = .{};

fn noopReady(_: std.Io, _: []const u8) void {}

fn hostThreadMain(state: *HostState) void {
    const threaded = state.threaded orelse return;
    const io = threaded.io();
    const cfg = config.Config.default();
    web_host.runWithHostConfig(io, web_host.bindLoopback, cfg, state.data_dir, noopReady) catch {};
}

/// Starts the loopback worker; `data_dir` from JNI is wired in a later step.
pub fn startHost(_: ?*anyopaque, _: ?*anyopaque) void {
    if (host_state.thread != null) return;

    const threaded = std.heap.page_allocator.create(std.Io.Threaded) catch return;
    threaded.* = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = std.process.Environ.empty });
    host_state.threaded = threaded;
    host_state.data_dir = ".";
    host_state.thread = std.Thread.spawn(.{}, hostThreadMain, .{&host_state}) catch return;
}

/// Stops the accept loop and joins the worker.
pub fn stopHost() void {
    if (host_state.threaded) |threaded| web_host.requestShutdown(threaded.io());
    if (host_state.thread) |t| {
        t.join();
        host_state.thread = null;
    }
    if (host_state.threaded) |threaded| {
        threaded.deinit();
        std.heap.page_allocator.destroy(threaded);
        host_state.threaded = null;
    }
}

test {
    _ = .{ web_host, config };
}
