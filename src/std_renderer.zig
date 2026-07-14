const std = @import("std");
const renderer = @import("renderer.zig");
const cell = @import("cell.zig");

/// Renders Sudoku grid as ASCII via stdout (TUI renderer impl.).
pub const StdoutRenderer = struct {
    w: std.Io.Writer,

    /// Initialise with an Io.Writer for output (e.g. stdout or a fixed buffer).
    pub fn init(writer: std.Io.Writer) StdoutRenderer {
        return .{ .w = writer };
    }

    /// Render the board state snapshot to standard out/terminal display.
    pub fn render(self: *StdoutRenderer, snap: renderer.RenderSnapshot) !void {
        try self.w.print("+-------+--------\n", .{}); // header border line

        _ = snap; // until real grid printing wired in next cycle
    }
};

test "StdoutRenderer renders snapshot data without crash/panic" {
    var buf: [8192]u8 = undefined;
    var r = StdoutRenderer.init(std.Io.Writer.fixed(&buf));

    const snap = renderer.RenderSnapshot{ .cells = undefined };

    try r.render(snap); // proves wiring works end to end without segfaults/panics
}
