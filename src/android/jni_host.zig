//! Android host logic — JNI name mangling lives in `entry_android.zig` at the `src/` module root.
const std = @import("std");
const builtin = @import("builtin");
const web_host = @import("../web_host/mod.zig");
const config = @import("../core/config.zig");
/// `file_name` only: tests name the settings file. Production reads it through the startup seam.
const config_store = @import("../core/config_store.zig");
const startup_config = @import("../core/startup/config.zig");
const save_defaults = @import("../core/save_defaults.zig");
const logcat = @import("logcat.zig");
const logger = @import("../core/logger.zig");
const about = @import("../core/about.zig");
const build_info = @import("../build_info.zig");

const log = logger.Logger(.android_host);
extern fn sudoku_jstring_utf_chars(env: ?*anyopaque, jstr: ?*anyopaque) ?[*:0]const u8;
extern fn sudoku_release_jstring_utf_chars(env: ?*anyopaque, jstr: ?*anyopaque, chars: ?[*:0]const u8) void;
extern fn sudoku_new_jstring_utf(env: ?*anyopaque, chars: ?[*:0]const u8) ?*anyopaque;

/// What Java polls once a boot starts: the port it serves on, and whether a refused settings read
/// stopped it before it served anything.
const BootRecord = struct {
    ready_port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    startup_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Back to "not serving, no failure" for a fresh boot.
    fn reset(self: *BootRecord) void {
        self.ready_port.store(0, .release);
        self.startup_failed.store(false, .release);
    }
};

/// The running boot's record: the host thread writes it, the JNI surface reads it. One boot runs at
/// a time, so one record is the whole of it.
var boot: BootRecord = .{};
/// What Java reads when a boot stopped on a settings refusal, so it can report at once instead of
/// waiting out its own readiness timeout.
const BOOT_REFUSED: i32 = -1;

const HostState = struct {
    thread: ?std.Thread = null,
    threaded: ?*std.Io.Threaded = null,
    data_dir: []const u8 = ".",
    owned_data_dir: ?[]u8 = null,
};

var host_state: HostState = .{};

fn extractReadyPort(url: []const u8) ?u16 {
    const start = std.mem.lastIndexOfScalar(u8, url, ':') orelse return null;
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    if (slash <= start + 1) return null;
    return std.fmt.parseInt(u16, url[start + 1 .. slash], 10) catch |err| {
        log.err("ready url {s} has no port: {s}", .{ url, @errorName(err) });
        return null;
    };
}

fn recordReady(_: std.Io, url: []const u8) void {
    const port = extractReadyPort(url) orelse return;
    boot.ready_port.store(port, .release);
}

/// The settings this boot serves with, read through the startup seam the desktop entry uses.
/// `null` means the seam refused: nothing is served, because a file that exists and cannot be
/// used is not a first start. A missing file is a first start and still plays on the defaults.
fn resolveHostConfig(io: std.Io, data_dir: []const u8) ?config.Config {
    return startup_config.resolveStartupConfig(std.heap.page_allocator, io, .{ .resolved = data_dir }, .{}) catch |err| switch (err) {
        // The seam's one error is the settings refusal its store already logged; defaulting here
        // would make an unusable file look like a first start and serve it.
        error.System => null,
    };
}

/// One boot: read settings through the startup seam, then serve loopback until shutdown. A refusal
/// starts no server and records the failure for Java; the seam's store has already written the
/// failure's one log line, so the host adds none of its own.
fn bootHost(io: std.Io, data_dir: []const u8) void {
    log.start("starting android host: {s}", .{about.summaryLine(build_info.debug_build)});
    const cfg = resolveHostConfig(io, data_dir) orelse {
        boot.startup_failed.store(true, .release);
        return;
    };
    startup_config.applyLoggerFromStartup(cfg);
    web_host.runWithHostConfig(io, web_host.bindLoopback, cfg, data_dir, data_dir, recordReady) catch |err| {
        log.fatal("web server failed to start: {s}", .{@errorName(err)});
    };
}

fn hostThreadMain(state: *HostState) void {
    const threaded = state.threaded orelse return;
    bootHost(threaded.io(), state.data_dir);
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
    return std.heap.page_allocator.dupe(u8, bytes) catch |err| {
        log.err("data dir copy failed: {s}", .{@errorName(err)});
        return null;
    };
}

/// Starts the loopback worker using the app files dir passed from Java.
pub fn startHost(env: ?*anyopaque, data_dir_jstring: ?*anyopaque) void {
    if (host_state.thread != null) return;

    const threaded = std.heap.page_allocator.create(std.Io.Threaded) catch |err| {
        log.fatal("host io setup failed: {s}", .{@errorName(err)});
        return;
    };
    threaded.* = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = std.process.Environ.empty });
    host_state.threaded = threaded;
    if (copyJStringUtf8(env, data_dir_jstring)) |path| {
        setDataDirOwned(path);
    } else {
        setDataDirDefault();
    }
    boot.reset();
    host_state.thread = std.Thread.spawn(.{}, hostThreadMain, .{&host_state}) catch |err| {
        log.fatal("host thread failed to start: {s}", .{@errorName(err)});
        return;
    };
}

/// JNI surface: where the boot stands, as one value Java polls — `0` while it is still starting,
/// `-1` when a settings refusal stopped it before it served anything, and the port once it serves.
/// The refusal used to reach Java only when its port poll timed out, so the sentence arrived after
/// the full timeout; a state it can read means the failure is reported when it happens.
pub fn bootState() i32 {
    if (boot.startup_failed.load(.acquire)) return BOOT_REFUSED;
    return boot.ready_port.load(.acquire);
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
    // The port goes with the host; a recorded refusal stays until the next boot replaces it.
    boot.ready_port.store(0, .release);
    setDataDirDefault();
}

/// JNI surface: expose native-owned log identity for platform log transport.
pub fn logIdentity(env: ?*anyopaque) ?*anyopaque {
    const env_raw = env orelse return null;
    return sudoku_new_jstring_utf(env_raw, logcat.logIdentity());
}

/// JNI surface: core's default folder name, which Java places under Downloads.
pub fn defaultFolderName(env: ?*anyopaque) ?*anyopaque {
    const env_raw = env orelse return null;
    return sudoku_new_jstring_utf(env_raw, save_defaults.DEFAULT_FOLDER_NAME);
}

/// Core's sentence for a boot a refused settings read stopped, or nothing when startup did not
/// fail: Java keeps its own copy for a page that never loaded. Returned as a sentinel-ended slice
/// so the JNI surface can hand it to Java without a copy.
pub fn startupFailureText() [:0]const u8 {
    return if (boot.startup_failed.load(.acquire)) startup_config.ANDROID_SETTINGS_REFUSED_MSG else "";
}

/// JNI surface: the sentence above, for the boot-failure page and toast Java draws.
pub fn startupFailureMessage(env: ?*anyopaque) ?*anyopaque {
    const env_raw = env orelse return null;
    return sudoku_new_jstring_utf(env_raw, startupFailureText());
}

/// How long a test waits for a boot to reach serving or to end.
const BOOT_WAIT_MS: u32 = 4000;
/// One poll interval while a test waits on a boot.
const BOOT_POLL_MS: u32 = 10;

/// Set once a test's boot thread has returned, so a test can report rather than hang.
var boot_finished = std.atomic.Value(bool).init(false);

/// Sleeps one poll interval; a test has no reason to be cancelled mid-wait.
fn bootPollSleep(io: std.Io) void {
    io.sleep(.fromMilliseconds(BOOT_POLL_MS), .awake) catch |err| log.info("expected: poll sleep cut short ({s})", .{@errorName(err)});
}

/// Runs one boot on its own thread, the way `startHost` does, and records that it ended.
fn bootOnThread(io: std.Io, data_dir: []const u8) void {
    bootHost(io, data_dir);
    boot_finished.store(true, .release);
}

/// Starts a boot over `data_dir` with a clean record, as `startHost` does.
fn startBootForTest(io: std.Io, data_dir: []const u8) !std.Thread {
    boot.reset();
    boot_finished.store(false, .release);
    return std.Thread.spawn(.{}, bootOnThread, .{ io, data_dir });
}

/// Waits for the boot to serve or to end, then lets it go: a boot that served is asked to stop, so
/// this cannot wait on a host the test expects to have refused.
fn finishBoot(io: std.Io, host: std.Thread) void {
    var waited: u32 = 0;
    while (waited < BOOT_WAIT_MS and !boot_finished.load(.acquire) and boot.ready_port.load(.acquire) == 0) : (waited += BOOT_POLL_MS) bootPollSleep(io);
    if (!boot_finished.load(.acquire)) {
        web_host.requestShutdown(io);
        waited = 0;
        while (waited < BOOT_WAIT_MS and !boot_finished.load(.acquire)) : (waited += BOOT_POLL_MS) bootPollSleep(io);
    }
    // A boot left inside `accept` is not joined, so a failed expectation reports instead of hanging.
    if (boot_finished.load(.acquire)) host.join();
}

/// A data directory in the test's own temp tree, which nothing else reads or writes.
fn testDataDir(tmp_sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp_sub_path});
}

/// A settings file no read can use: bytes that do not parse, so the store refuses them.
const CORRUPT_CONFIG = "{\"config\":{";

/// A settings file whose two choices are both off the code defaults, so reading it is the only way
/// they reach the host.
const GOOD_CONFIG = "{\"config\":{\"difficulty\":\"hard\",\"theme\":\"light\"}}";

/// The lines of `text` emitted at warn severity.
fn warnLines(text: []const u8) usize {
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "warn")) lines += 1;
    }
    return lines;
}

test "a settings file the store refuses records the failure and serves nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testDataDir(&tmp.sub_path);
    defer std.testing.allocator.free(data_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = config_store.file_name, .data = CORRUPT_CONFIG });

    var logged: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    const host = try startBootForTest(io, data_dir);
    finishBoot(io, host);

    try std.testing.expect(boot_finished.load(.acquire));
    try std.testing.expect(boot.startup_failed.load(.acquire));
    try std.testing.expectEqual(@as(i32, -1), bootState());
    // The store writes the refusal once; the host does not re-word it.
    try std.testing.expectEqual(@as(usize, 1), warnLines(sink.buffered()));
    try std.testing.expect(std.mem.indexOf(u8, sink.buffered(), "using defaults") == null);
}

test "a settings file the store can read starts the host as today and records no failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testDataDir(&tmp.sub_path);
    defer std.testing.allocator.free(data_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = config_store.file_name, .data = GOOD_CONFIG });

    const host = try startBootForTest(io, data_dir);
    finishBoot(io, host);

    try std.testing.expect(boot_finished.load(.acquire));
    try std.testing.expect(!boot.startup_failed.load(.acquire));
    try std.testing.expect(bootState() > 0);
    // A boot that served has no refusal sentence for Java to show.
    try std.testing.expectEqualStrings("", startupFailureText());
}

test "a boot that has neither served nor failed reads as still starting" {
    boot.reset();
    try std.testing.expectEqual(@as(i32, 0), bootState());
}

test "the host takes its settings from the file through the startup seam" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testDataDir(&tmp.sub_path);
    defer std.testing.allocator.free(data_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = config_store.file_name, .data = GOOD_CONFIG });

    const cfg = resolveHostConfig(io, data_dir) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(config.Difficulty.hard, cfg.difficulty);
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);

    // A first start has no file and plays on the defaults rather than refusing.
    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    const empty_dir = try testDataDir(&empty.sub_path);
    defer std.testing.allocator.free(empty_dir);
    const defaults = resolveHostConfig(io, empty_dir) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(config.Config.default().difficulty, defaults.difficulty);
    try std.testing.expectEqual(config.Config.default().theme, defaults.theme);

    try tmp.dir.writeFile(io, .{ .sub_path = config_store.file_name, .data = CORRUPT_CONFIG });
    try std.testing.expect(resolveHostConfig(io, data_dir) == null);
}

test {
    _ = .{ web_host, config };
}

test "the boot exposes core's refusal sentence, and nothing when it did not fail" {
    const io = std.testing.io;

    // No boot has refused, so Java keeps its own copy for a page that never loaded.
    boot.reset();
    try std.testing.expectEqualStrings("", startupFailureText());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try testDataDir(&tmp.sub_path);
    defer std.testing.allocator.free(data_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = config_store.file_name, .data = CORRUPT_CONFIG });

    const host = try startBootForTest(io, data_dir);
    finishBoot(io, host);

    try std.testing.expect(boot.startup_failed.load(.acquire));
    try std.testing.expectEqualStrings(startup_config.ANDROID_SETTINGS_REFUSED_MSG, startupFailureText());
}
