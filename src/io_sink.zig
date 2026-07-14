const std = @import("std");

/// An output sink pairing an `Io` context with a file destination.
pub const IoSink = struct {
    io: std.Io,
    out: std.Io.File,
    temp_path_owned: ?[]u8 = null,
    needs_cleanup: bool = false,

    pub const Builder = struct {
        io: std.Io,

        /// Finalize as stdout (no cleanup needed on deinit).
        pub fn toStdout(self: *const @This()) IoSink {
            return .{ .io = self.io, .out = std.Io.File.stdout() };
        }

        /// Finalize as temp file in `/tmp` (calls `deinit()` will remove it + close handle);
        pub fn toTemp(self: *const @This(), allocator: std.mem.Allocator) !IoSink {
            const tmp_dir = try std.Io.Dir.openDirAbsolute(self.io, "/tmp", .{});
            defer tmp_dir.close(self.io);

            // Generate unique name via crypto RNG bytes -> hex string
            var rand_buf: [8]u8 = undefined;
            self.io.random(&rand_buf);  

            const hex = std.fmt.bytesToHex(&rand_buf, .upper);
            const path: []u8 = try std.fmt.allocPrint(allocator, "sudoku_test_{s}.txt", .{&hex});

            const out_file = try tmp_dir.createFile(self.io, path, .{});

            return .{
                .io = self.io,
                .out = out_file,
                .temp_path_owned = path,
                .needs_cleanup = true,
            };
        }
    };

    pub fn init(io: std.Io) Builder {
        return .{ .io = io };
    }

    pub fn deinit(self: *IoSink, allocator: std.mem.Allocator) void {
        if (self.needs_cleanup) {
            if (self.temp_path_owned) |path| {
                defer allocator.free(path);

                const tmp_dir = std.Io.Dir.openDirAbsolute(self.io, "/tmp", .{}) catch return;
                defer tmp_dir.close(self.io);

                self.out.close(self.io);
                _ = tmp_dir.deleteFile(self.io, path) catch {};
            }
        }
        self.needs_cleanup = false;
        self.temp_path_owned = null;  // marker cleared so double-deinit is a no-op
    }

    pub fn writer(self: *IoSink) std.Io.File.Writer {
        return self.out.writer(self.io, &.{});
    }
};

// Test: Builder.toStdout() produces a valid sink that can write via its writer.
test "IoSink.toStdout returns valid sink" {
    const io = std.testing.io;
    var sink = IoSink.init(io).toStdout();
    defer sink.deinit(std.testing.allocator);

    // Writing should not crash/panic even when stdout is a pipe under server mode
    var writer_out = sink.writer();
    const writer = &writer_out.interface;
    _ = try writer.print("test ok\n", .{});
}

// Test: Builder.toTemp() creates file in /tmp, deinit() cleans it up + closes handle.
test "IoSink.toTemp creates and removes temp file" {
    const io = std.testing.io;
    var sink = try IoSink.init(io).toTemp(std.testing.allocator);
    defer sink.deinit(std.testing.allocator);

    // Should not be null / empty for temp path ownership tracking
    try std.testing.expect(sink.needs_cleanup == true);
    try std.testing.expect(sink.temp_path_owned != null);

    var writer_out = sink.writer();
    const writer = &writer_out.interface;
    _ = try writer.print("data written via totemp path\n", .{});

    // File exists before cleanup
    const tmp_dir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp_dir.close(io);

    const stats = try sink.out.stat(io);
    _ = stats;
}
