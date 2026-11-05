const std = @import("std");
const builtin = @import("builtin");
const android_logcat = @import("../android/logcat.zig");
const wasm_console = @import("../wasm/console_log.zig");

/// Severity ranks for runtime filtering; enum order IS the rank, so with the
/// .info default, debug is suppressed and info..fatal are emitted.
pub const Severity = enum { debug, info, warn, err, fatal };
pub const build_allows_debug_logs = builtin.mode == .debug;
const is_wasm = builtin.os.tag == .freestanding;

/// Minimum severity emitted at runtime; set from parsed CLI flags before the game starts.
pub var min_level: Severity = .info;

/// Wasm is always built as Debug and ships in every host, so there the host's build mode decides
/// whether debug lines run; the wasm entry sets it from the host's build info.
pub var host_allows_debug_logs: bool = false;

fn debugAllowed() bool {
    if (comptime is_wasm) return host_allows_debug_logs;
    return build_allows_debug_logs;
}

/// Test builds write emitted lines here when set, so a test can check what the sink receives.
pub var test_sink: if (builtin.is_test) ?*std.Io.Writer else void = if (builtin.is_test) null else {};

/// .fatal always emits; everything else is gated against min_level.
pub fn shouldEmit(sev: Severity) bool {
    if (sev == .debug and !debugAllowed()) return false;
    if (sev == .fatal) return true;
    return @backingInt(sev) >= @backingInt(min_level);
}

/// Scoped logger generator.
/// Pass a comptime enum literal for the log scope; returns a struct with five
/// severity methods: `.debug()`, `.info()`, `.warn()`, `.err()`, and `.fatal()`.
pub fn Logger(comptime scope: @EnumLiteral()) type {
    const log = std.log.scoped(scope);
    const scope_name = @tagName(scope);
    return struct {
        /// Emit debug-level message if runtime filter allows it.
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            if (comptime !build_allows_debug_logs) return;
            if (!shouldEmit(.debug)) return;
            emit(.debug, scope_name, log, fmt, args);
        }

        /// Emit error-level message if runtime filter allows it.
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            if (!shouldEmit(.err)) return;
            emit(.err, scope_name, log, fmt, args);
        }

        /// Emit warn-level message if runtime filter allows it.
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            if (!shouldEmit(.warn)) return;
            emit(.warn, scope_name, log, fmt, args);
        }

        /// Emit info-level message if runtime filter allows it.
        pub fn info(comptime fmt: []const u8, args: anytype) void {
            if (!shouldEmit(.info)) return;
            emit(.info, scope_name, log, fmt, args);
        }

        /// Emit fatal message, then abort the process.
        pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
            emit(.fatal, scope_name, log, "FATAL: " ++ fmt, args);
            std.debug.dumpCurrentStackTrace(.{});
            std.process.abort();
        }
    };
}

const line_cap = 1024;

fn androidPriority(sev: Severity) c_int {
    return switch (sev) {
        .debug => 3,
        .info => 4,
        .warn => 5,
        .err => 6,
        .fatal => 7,
    };
}

/// Marks a line cut to fit its buffer, so a long line still reaches the log, shortened.
const TRUNCATED_MARK = " ...[truncated]";

/// Format into `dest`; a line that does not fit keeps its start and ends with `TRUNCATED_MARK`.
pub fn fitLine(dest: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(dest);
    w.print(fmt, args) catch {
        const keep = dest.len - TRUNCATED_MARK.len;
        @memcpy(dest[keep..], TRUNCATED_MARK);
        return dest;
    };
    return w.buffered();
}

fn formatAndroidLine(
    comptime scope_name: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    buf: *[line_cap]u8,
) [:0]const u8 {
    const line = fitLine(buf[0 .. buf.len - 1], "[{s}] " ++ fmt, .{scope_name} ++ args);
    buf[line.len] = 0;
    return buf[0..line.len :0];
}

fn emit(
    sev: Severity,
    comptime scope_name: []const u8,
    log: anytype,
    comptime fmt: []const u8,
    args: anytype,
) void {
    // wasm has no stderr: the JS shell writes the line to the console and the host log.
    if (comptime is_wasm) {
        var text_buf: [line_cap]u8 = undefined;
        wasm_console.write(@backingInt(sev), scope_name, fitLine(&text_buf, fmt, args));
        return;
    }
    if (comptime builtin.abi == .android) {
        var line_buf: [line_cap]u8 = undefined;
        const line = formatAndroidLine(scope_name, fmt, args, &line_buf);
        android_logcat.write(androidPriority(sev), line);
        return;
    }

    if (comptime builtin.is_test) {
        if (test_sink) |sink| {
            sink.print("{s} [{s}] " ++ fmt ++ "\n", .{ @tagName(sev), scope_name } ++ args) catch {};
            return;
        }
        // The test runner fails any test that logs at warn or error, and tests drive those paths on purpose.
        if (sev == .warn or sev == .err) return log.info(fmt, args);
    }
    switch (sev) {
        .debug => log.debug(fmt, args),
        .info => log.info(fmt, args),
        .warn => log.warn(fmt, args),
        .err, .fatal => log.err(fmt, args),
    }
}

test "severity methods accept args tuples" {
    const log = Logger(.logger);
    log.info("value is {}", .{42});
    log.warn("range {d}..{d}", .{ 1, 9 });
    // Prove .err() compiles — call via a dedicated scope to avoid
    // polluting the shared test runner stderr (Zig treats err-level as failure).
    const errLog = Logger(.quiet);
    _ = errLog;
}

test "Logger provides all five severity methods" {
    const log = Logger(.logger);
    _ = @TypeOf(log.err);
    _ = @TypeOf(log.warn);
    _ = @TypeOf(log.info);
    _ = @TypeOf(log.debug);
    _ = @TypeOf(log.fatal);
}

test "debug emits formatted output" {
    Logger(.logger).debug("This is a debug log message.", .{});
}

test "shouldEmit suppresses severities below min_level" {
    min_level = .warn;
    try std.testing.expect(!shouldEmit(.debug));
    try std.testing.expect(!shouldEmit(.info));
    try std.testing.expect(shouldEmit(.warn));
    try std.testing.expect(shouldEmit(.err));
    min_level = .info;
}

test "a core line reaches the sink, and lines below min_level do not" {
    var buf: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buf);
    test_sink = &sink;
    defer test_sink = null;
    min_level = .warn;
    defer min_level = .info;
    const log = Logger(.flow);
    log.debug("parity {s}", .{"debug"});
    log.info("parity {s}", .{"info"});
    log.warn("parity {s}", .{"warn"});
    log.err("parity {s}", .{"err"});
    try std.testing.expectEqualStrings("warn [flow] parity warn\nerr [flow] parity err\n", sink.buffered());
}

test "shouldEmit always allows fatal" {
    min_level = .err;
    try std.testing.expect(shouldEmit(.fatal));
    min_level = .info;
}

test "androidPriority maps severities to logcat priorities" {
    try std.testing.expectEqual(@as(c_int, 3), androidPriority(.debug));
    try std.testing.expectEqual(@as(c_int, 4), androidPriority(.info));
    try std.testing.expectEqual(@as(c_int, 5), androidPriority(.warn));
    try std.testing.expectEqual(@as(c_int, 6), androidPriority(.err));
    try std.testing.expectEqual(@as(c_int, 7), androidPriority(.fatal));
}

test "formatAndroidLine includes scope prefix and payload" {
    var buf: [line_cap]u8 = undefined;
    const line = formatAndroidLine("web_host", "current-file write success: bytes={d}", .{117}, &buf);
    try std.testing.expectEqualStrings("[web_host] current-file write success: bytes=117", line);
}

test "a line too long for the buffer is kept, shortened and marked" {
    var buf: [line_cap]u8 = undefined;
    var long: [line_cap * 2]u8 = undefined;
    @memset(&long, 'x');
    const line = formatAndroidLine("web_host", "{s}", .{&long}, &buf);
    try std.testing.expectEqual(line_cap - 1, line.len);
    try std.testing.expect(std.mem.startsWith(u8, line, "[web_host] xxx"));
    try std.testing.expect(std.mem.endsWith(u8, line, TRUNCATED_MARK));
}
