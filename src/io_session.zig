const std = @import("std");
const input_source = @import("input_source.zig");

// Issue 47 chunk 3 — WriterSource + IoSession (spec: issue-47 sketch).

/// Where rendered output goes. ".stdout" is process-owned (no deinit);
/// ".mock" owns a heap buffer only its own deinit() releases.
pub const WriterSource = union(enum) {
    stdout: std.Io.File.Writer,
    mock: std.Io.Writer.Allocating,
};

/// Terminal session value for one run: keyboard-in, screen-out, and the
/// per-branch allocator. Constructed only at entry points (main / test).
pub const IoSession = struct {
    reader: input_source.ReaderSource,
    writer: WriterSource,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *IoSession) void {
        switch (self.writer) {
            .stdout => {}, // value on the stack; fd belongs to the process
            .mock => |*w| w.deinit(), // releases inner buffer via its allocator
        }
    }
};

test "IoSession.deinit releases the mock writer buffer" {
    const alloc = std.testing.allocator;
    const responses = [_][]const u8{};

    var session = IoSession{
        .reader = .{ .mock = input_source.MockSource.init(alloc, &responses) },
        .writer = .{ .mock = std.Io.Writer.Allocating.init(alloc) },
        .alloc = alloc,
    };

    // Grow the inner buffer so deinit() has real heap to release.
    try session.writer.mock.writer.writeAll("payload for leak check");
    try std.testing.expectEqualStrings("payload for leak check", std.Io.Writer.buffered(&session.writer.mock.writer));

    session.deinit();
    // std.testing.allocator's leak check fails this test if the buffer above leaked.
}
