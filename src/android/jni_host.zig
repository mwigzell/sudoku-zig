//! Android host logic — JNI name mangling lives in `android_shared.zig` at the `src/` module root.
const std = @import("std");
const builtin = @import("builtin");
const web_host = @import("../web_host/mod.zig");
const config = @import("../config.zig");
const settings_store = @import("../settings_store.zig");
extern fn sudoku_jstring_utf_chars(env: ?*anyopaque, jstr: ?*anyopaque) ?[*:0]const u8;
extern fn sudoku_release_jstring_utf_chars(env: ?*anyopaque, jstr: ?*anyopaque, chars: ?[*:0]const u8) void;

const HostState = struct {
    thread: ?std.Thread = null,
    threaded: ?*std.Io.Threaded = null,
    data_dir: []const u8 = ".",
    owned_data_dir: ?[]u8 = null,
    ready_port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
};

var host_state: HostState = .{};

fn extractReadyPort(url: []const u8) ?u16 {
    const start = std.mem.lastIndexOfScalar(u8, url, ':') orelse return null;
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    if (slash <= start + 1) return null;
    return std.fmt.parseInt(u16, url[start + 1 .. slash], 10) catch null;
}

fn recordReady(_: std.Io, url: []const u8) void {
    const port = extractReadyPort(url) orelse return;
    host_state.ready_port.store(port, .release);
}

fn hostThreadMain(state: *HostState) void {
    const threaded = state.threaded orelse return;
    const io = threaded.io();
    const cfg = settings_store.loadOrDefault(std.heap.page_allocator, io, state.data_dir) catch config.Config.default();
    web_host.runWithHostConfig(io, web_host.bindLoopback, cfg, state.data_dir, recordReady) catch {};
}

fn setDataDirDefault() void {
    if (host_state.owned_data_dir) |path| {
        std.heap.page_allocator.free(path);
        host_state.owned_data_dir = null;
    }
    host_state.data_dir = ".";
}

fn setDataDirOwned(path: []u8) void {
    if (host_state.owned_data_dir) |old| std.heap.page_allocator.free(old);
    host_state.owned_data_dir = path;
    host_state.data_dir = path;
}

fn copyJStringUtf8(env_ptr: ?*anyopaque, jstring_ptr: ?*anyopaque) ?[]u8 {
    if (builtin.abi != .android) return null;
    const env_raw = env_ptr orelse return null;
    const jstr_raw = jstring_ptr orelse return null;

    const chars = sudoku_jstring_utf_chars(env_raw, jstr_raw) orelse return null;
    defer sudoku_release_jstring_utf_chars(env_raw, jstr_raw, chars);

    const bytes = std.mem.sliceTo(chars, 0);
    return std.heap.page_allocator.dupe(u8, bytes) catch null;
}

/// Starts the loopback worker using the app files dir passed from Java.
pub fn startHost(env: ?*anyopaque, data_dir_jstring: ?*anyopaque) void {
    if (host_state.thread != null) return;

    const threaded = std.heap.page_allocator.create(std.Io.Threaded) catch return;
    threaded.* = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = std.process.Environ.empty });
    host_state.threaded = threaded;
    if (copyJStringUtf8(env, data_dir_jstring)) |path| {
        setDataDirOwned(path);
    } else {
        setDataDirDefault();
    }
    host_state.ready_port.store(0, .release);
    host_state.thread = std.Thread.spawn(.{}, hostThreadMain, .{&host_state}) catch return;
}

pub fn readyPort() i32 {
    const port = host_state.ready_port.load(.acquire);
    if (port == 0) return -1;
    return port;
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
    host_state.ready_port.store(0, .release);
    setDataDirDefault();
}

test {
    _ = .{ web_host, config };
}
