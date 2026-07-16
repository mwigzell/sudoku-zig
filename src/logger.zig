const std = @import("std");

pub fn Logger(comptime scope: @EnumLiteral()) type {
    const log = std.log.scoped(scope);
    return struct {
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            log.debug(fmt, args);
        }
        pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
            log.err("FATAL: " ++ fmt, args);
            std.debug.dumpCurrentStackTrace(.{});
            std.process.abort();
        }
    };
}

test "debug emits formatted output" {
    Logger(.logger).debug("This is a debug log message.", .{});
}
