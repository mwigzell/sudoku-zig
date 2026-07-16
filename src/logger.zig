const std = @import("std");

pub fn Logger(comptime scope: @EnumLiteral()) type {
    return struct {
        fn _impl(
            comptime level_text: []const u8,
            comptime fmt: []const u8,
            args: anytype,
        ) void {
            std.debug.print("{s} [{s}] ", .{ level_text, @tagName(scope) });
            std.debug.print(fmt ++ "\n", args);
        }

        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            if (comptime !std.log.logEnabled(.debug, scope)) return;
            _impl("[DEBUG]", fmt, args);
        }

        pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
            _impl("[FATAL]", fmt, args);
            std.debug.dumpCurrentStackTrace(.{});
            std.process.abort();
        }
    };
}

test "debug emits formatted output" {
    const log = Logger(.main);
    log.debug("This is a debug log message.", .{});
}
