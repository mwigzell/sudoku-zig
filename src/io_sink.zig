const std = @import("std");

/// Fixed-size in-memory output buffer. No std.Io, no heap allocation, no async scheduling.
pub const InMemoryOutput = struct {
    buf: [4096]u8 = undefined,
    written: usize = 0,

    pub fn init() @This() {
        return .{};
    }

    /// Append bytes up to buffer capacity.
    pub fn writeAll(self: *@This(), data: []const u8) !void {
        if (self.written + data.len > self.buf.len) {
            return error.NoSpaceLeftOnDevice;
        }
        @memcpy(self.buf[self.written .. self.written + data.len], data);
        self.written += data.len;
    }

    /// Get all written bytes as a slice (without taking ownership).
    pub fn contents(self: *@This()) []u8 {
        return self.buf[0..self.written];
    }
};

/// An output sink pairing an `Io` context with a file destination.
pub const IoSink = struct {
    io: std.Io,
    out: std.Io.File,
    temp_path_owned: ?[]u8 = null,
    needs_cleanup: bool = false,

    pub fn initStdout(io: std.Io) @This() {
        return .{ .io = io, .out = std.Io.File.stdout() };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.needs_cleanup) {
            if (self.temp_path_owned) |path| {
                defer allocator.free(path);

                const tmp_dir = std.Io.Dir.openDirAbsolute(self.io, "/tmp", .{}) catch return;
                defer tmp_dir.close(self.io);

                self.out.close(self.io);
                _ = tmp_dir.deleteFile(self.io, path) catch {};
            }
        } else {
            self.out.close(self.io);
        }
        self.needs_cleanup = false;
        self.temp_path_owned = null;
    }

    /// Return an Io.File.Writer with ZERO buffering.
    ///
    /// ziglings 026_hello2.zig demonstrates this: passing `&.{}` (empty struct
    /// literal) means writes go directly to the file handle and are immediately
    /// visible. Any real buffer [N]u8 holds data until flushed — when a writer
    /// with a buffer goes out of scope mid-function (e.g. inside render()),
    /// buffered bytes are silently lost.
    pub fn writer(self: *@This()) std.Io.File.Writer {
        return self.out.writer(self.io, &.{});
    }
};

/// Builder for IoSink (for production code that needs real I/O paths).
pub const SinkBuilder = struct {
    io: std.Io,

    pub fn toStdout(self: *const @This()) IoSink {
        return IoSink.initStdout(self.io);
    }

    pub fn toTemp(self: *const @This(), allocator: std.mem.Allocator) !IoSink {
        const tmp_dir = try std.Io.Dir.openDirAbsolute(self.io, "/tmp", .{});
        defer tmp_dir.close(self.io);

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

pub fn sink(io: std.Io) SinkBuilder {
    return .{ .io = io };
}

test "InMemoryOutput writes and reads back" {
    var mem = InMemoryOutput.init();
    try mem.writeAll("hello memory\n");
    try std.testing.expectEqualStrings("hello memory\n", mem.contents());
}
