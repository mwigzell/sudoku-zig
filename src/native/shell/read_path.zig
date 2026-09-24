// Shared resolve + readAll for session handlers that load file bytes (open, import).
const std = @import("std");
const file_transport = @import("file_transport.zig");

pub const Stage = enum { resolve, read };

pub const ReadResult = struct {
    /// Owned resolved path; free with `transport.free`.
    resolved: []u8,
    /// Owned file contents; free with `transport.free`.
    bytes: []u8,
};

/// Resolve `file_path` and read all bytes. On failure, `stage_out` is the step that failed.
/// Caller frees both buffers via `transport.free` on success.
pub fn readFileBytes(
    transport: file_transport.FileTransport,
    file_path: []const u8,
    stage_out: *Stage,
) file_transport.TransportError!ReadResult {
    stage_out.* = .resolve;
    const resolved = try transport.resolve(transport.context, file_path);
    errdefer transport.free(transport.context, resolved);

    stage_out.* = .read;
    const bytes = try transport.readAll(transport.context, resolved);

    return .{ .resolved = resolved, .bytes = bytes };
}

test "readFileBytes round-trips through transport" {
    file_transport.NativeTransport.resetSession();
    defer file_transport.NativeTransport.deinitSession();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    const path = "/tmp/sudoku_read_path_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    const payload = "one-line payload";
    try transport.write(transport.context, path, payload);

    var stage: Stage = .resolve;
    const read = try readFileBytes(transport, path, &stage);
    defer transport.free(transport.context, read.resolved);
    defer transport.free(transport.context, read.bytes);
    try std.testing.expectEqual(stage, .read);
    try std.testing.expectEqualSlices(u8, payload, read.bytes);
}
