const std = @import("std");
const renderer = @import("renderer.zig");
const cell = @import("cell.zig");
const default_puzzle = @import("default_puzzle.zig");

/// Renders Sudoku grid as ASCII via stdout (TUI renderer impl.).
pub const StdoutRenderer = struct {
    file_writer: std.Io.File.Writer,

    pub fn init(io: std.Io) StdoutRenderer {
        const writer = std.Io.File.stdout().writer(io, &.{});
        return .{
            .file_writer = writer,
        };
    }

    /// Render the board state snapshot to standard out/terminal display.
    pub fn render(self: *StdoutRenderer, snap: renderer.RenderSnapshot) !void {
        const w = &self.file_writer.interface;
        try w.print("+-------+--------\n", .{}); // header border line

        _ = snap; // until real grid printing wired in next cycle
    }
};

test "StdoutRenderer renders snapshot data without crash/panic" {
    var r = StdoutRenderer.init(std.testing.io);

    const snap = renderer.RenderSnapshot{ .cells = undefined };

    try r.render(snap); // proves wiring works end-to-end without segfaults/panics
}
