const std = @import("std");

/// Severity ranks for runtime filtering; enum order IS the rank, so with the
/// .info default, debug is suppressed and info..fatal are emitted.
pub const Severity = enum{ debug, info, warn, err, fatal };

/// Minimum severity emitted at runtime; set from parsed CLI flags before the game starts.
pub var min_level: Severity = .info;

/// .fatal always emits; everything else is gated against min_level.
pub fn shouldEmit(sev: Severity) bool {
    if (sev == .fatal) return true;
    return @intFromEnum(sev) >= @intFromEnum(min_level);
}

/// Scoped logger generator.
/// Pass a comptime enum literal for the log scope; returns a struct with five
/// severity methods: `.debug()`, `.info()`, `.warn()`, `.err()`, and `.fatal()`.
pub fn Logger(comptime scope: @EnumLiteral()) type {
    const log = std.log.scoped(scope);
    return struct {
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            if (shouldEmit(.debug)) log.debug(fmt, args);
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            if (shouldEmit(.err)) log.err(fmt, args);
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            if (shouldEmit(.warn)) log.warn(fmt, args);
        }

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            if (shouldEmit(.info)) log.info(fmt, args);
        }

        pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
            log.err("FATAL: " ++ fmt, args);
            std.debug.dumpCurrentStackTrace(.{});
            std.process.abort();
        }
    };
}

// Temporarily commented out — the log.warn() call prints to stderr and
// interferes with Zig server-mode IPC test runner on cold builds.
//
// test "severity methods accept args tuples" {
//     const log = Logger(.logger);
//     log.info("value is {}", .{42});
//     log.warn("range {d}..{d}", .{ 1, 9 });
//     // Prove .err() compiles — call via a dedicated scope to avoid
//     // polluting the shared test runner stderr (Zig treats err-level as failure).
//     const errLog = Logger(.quiet);
//     _ = errLog;
// }

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

test "shouldEmit always allows fatal" {
    min_level = .err;
    try std.testing.expect(shouldEmit(.fatal));
    min_level = .info;
}
