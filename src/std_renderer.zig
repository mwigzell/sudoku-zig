const std = @import("std");
const renderer = @import("renderer.zig");
const io_sink = @import("io_sink.zig");

/// Tagged union abstracting "where output goes".
pub const OutputSink = union(enum) {
    file: *io_sink.IoSink,
    memory: *io_sink.InMemoryOutput,
};

/// Renders Sudoku grid as ASCII to the configured output destination.
pub const StdoutRenderer = struct {
    sink: OutputSink,

    pub fn init(sink: OutputSink) @This() {
        return .{ .sink = sink };
    }

    /// Render the board state snapshot to the configured output.
    pub fn render(self: *@This(), snap: renderer.RenderSnapshot) anyerror!void {
        switch (self.sink) {
            .file => |s| {
                var w = s.writer();
                const stdout = &w.interface;
                try stdout.print("+-------+--------\n", .{});
            },
            .memory => |m| {
                try m.writeAll("+-------+--------\n");
            },
        }

        _ = snap; // until full grid printing wired up
    }
};

test "StdoutRenderer renders via in-memory sink" {
    var mem = io_sink.InMemoryOutput.init();
    var r = StdoutRenderer.init(.{ .memory = &mem });

    const snap: renderer.RenderSnapshot = undefined;
    try r.render(snap);

    try std.testing.expectEqualStrings("+-------+--------\n", mem.contents());
}
