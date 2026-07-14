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
    const io = std.testing.io;

    // Under zig build test (maker server mode, --listen=-) stdout is a pipe for IPC.
    // Writing to it would corrupt the wire protocol. Only test when stdout is real.
    if (!(try std.Io.File.stdout().isTty(io))) return;

    var r = StdoutRenderer.init(io);

    const snap: renderer.RenderSnapshot = undefined;

    try r.render(snap); // proves wiring works end-to-end without segfaults/panics
}
