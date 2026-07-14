const std = @import("std");
const renderer = @import("renderer.zig");
const cell = @import("cell.zig");
const default_puzzle = @import("default_puzzle.zig");
const io_sink = @import("io_sink.zig");

/// Renders Sudoku grid as ASCII via an output sink.
pub const StdoutRenderer = struct {
    sink: *io_sink.IoSink,

    pub fn init(r: *io_sink.IoSink) StdoutRenderer {
        return .{
            .sink = r,
        };
    }

    /// Render the board state snapshot to stdout/terminal display.
    pub fn render(self: *StdoutRenderer, snap: renderer.RenderSnapshot) !void {
        var w = self.sink.writer();
        const writer = &w.interface;
        try writer.print("+-------+--------\n", .{}); // header border line

        _ = snap; // until real grid printing wired in next cycle
    }
};

test "StdoutRenderer renders snapshot data without crash/panic" {
    const io = std.testing.io;

    var sink: io_sink.IoSink = undefined;
    sink = try io_sink.IoSink.init(io).toTemp(std.testing.allocator);
    defer sink.deinit(std.testing.allocator);

    var r = StdoutRenderer.init(&sink);

    const snap: renderer.RenderSnapshot = undefined;
    try r.render(snap);

    // Re-open the same temp file for reading to verify output (don't close sink.out — deinit does that)
    const tdir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tdir.close(io);

    const path = sink.temp_path_owned orelse unreachable;
    var read_file = try tdir.openFile(io, path, .{ .mode = .read_only });
    defer read_file.close(io);

    var buf: [256]u8 = undefined;
    const n = try read_file.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("+-------+--------\n", buf[0..n]);
}
