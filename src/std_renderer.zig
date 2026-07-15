const std = @import("std");
const board = @import("board.zig");
const cell = @import("cell.zig");
const renderer = @import("renderer.zig");
const io_sink = @import("io_sink.zig");

/// Tagged union abstracting "where output goes".
pub const OutputSink = union(enum) {
    file: *io_sink.IoSink,
    memory: *io_sink.InMemoryOutput,
};

pub fn columnHeader() []const u8 {
    return "   A B C | D E F | G H I \n";
}

/// Return the horizontal box-border line.
pub fn horizBorder() []const u8 {
    return " +-------+-------+-------+\n";
}

/// Format a single data row into `buf` and return the filled slice.
pub fn cellRow(row: usize, snap: renderer.RenderSnapshot, buf: []u8) ![]u8 {
    const display: [9]u8 = blk: {
        var chars: [9]u8 = undefined;
        for (0..9) |col| {
            chars[col] = cell.displayChar(snap.cells[row][col].value);
        }
        break :blk chars;
    };

    return std.fmt.bufPrint(
        buf,
        "{d}| {c} {c} {c} | {c} {c} {c} | {c} {c} {c} |\n",
        .{ row + 1,
            display[0], display[1], display[2],
            display[3], display[4], display[5],
            display[6], display[7], display[8] },
    );
}

/// Renders Sudoku grid as ASCII to the configured output destination.
pub const StdoutRenderer = struct {
    sink: OutputSink,

    pub fn init(sink: OutputSink) @This() {
        return .{ .sink = sink };
    }

    /// Render the board state snapshot to the configured output.
    pub fn render(self: *@This(), snap: renderer.RenderSnapshot) anyerror!void {
        try lineToSink(self, columnHeader());
        try lineToSink(self, horizBorder());

        for (0..9) |row| {
            var rowBuf: [64]u8 = undefined;
            const data = try cellRow(row, snap, &rowBuf);
            try lineToSink(self, data);

            if (row == 2 or row == 5) {
                try lineToSink(self, horizBorder());
            }
        }

        try lineToSink(self, horizBorder());
    }
};

/// Write a single-line slice to whichever sink is configured.
fn lineToSink(r: *StdoutRenderer, line: []const u8) anyerror!void {
    switch (r.sink) {
        .file => |s| {
            const w = s.writer();
            const io_w = @constCast(&w.interface);
            try io_w.print("{s}", .{line});
        },
        .memory => |m| try m.writeAll(line),
    }
}

// ---------------------------------------------------------------------------
// Tests (co-located) — each helper tested before render() assembles them
// ---------------------------------------------------------------------------

test "column header" {
    try std.testing.expectEqualStrings(
        "   A B C | D E F | G H I \n",
        columnHeader(),
    );
}

test "horizontal border" {
    try std.testing.expectEqualStrings(
        " +-------+-------+-------+\n",
        horizBorder(),
    );
}

test "cell row (empty)" {
    var snap: renderer.RenderSnapshot = undefined;
    for (0..9) |row| {
        for (0..9) |col| {
            snap.cells[row][col] = renderer.RenderCell{
                .value = .zero,
                .locked = false,
                .conflicting = false,
            };
        }
    }

    var buf: [64]u8 = undefined;
    const line = try cellRow(0, snap, &buf);
    try std.testing.expectEqualStrings("1|       |       |       |\n", line);
}

test "cell row (digits placed)" {
    var snap: renderer.RenderSnapshot = undefined;
    for (0..9) |row| {
        for (0..9) |col| {
            snap.cells[row][col] = renderer.RenderCell{
                .value = .zero,
                .locked = false,
                .conflicting = false,
            };
        }
    }

    // Row index 7: full row of digits 5 1 3 | 6 7 8 | 2 4 9
    const vals = [_]cell.CellValue{ .five, .one, .three, .six, .seven, .eight, .two, .four, .nine };
    for (0..9) |col| {
        snap.cells[7][col] = renderer.RenderCell{
            .value = vals[col],
            .locked = true,
            .conflicting = false,
        };
    }

    var buf: [64]u8 = undefined;
    const line = try cellRow(7, snap, &buf);
    try std.testing.expectEqualStrings("8| 5 1 3 | 6 7 8 | 2 4 9 |\n", line);
}

test "StdoutRenderer renders empty board end-to-end" {
    var mem = io_sink.InMemoryOutput.init();
    var r = StdoutRenderer.init(.{ .memory = &mem });

    const b = board.Board.init();
    var mut_b = b;
    try r.render(mut_b.assembleRenderSnapshot());

    // Build expected output mechanically from tested helpers — no hand-counted space strings
    const snap = mut_b.assembleRenderSnapshot();
    var mem_expected = blk: {
        var out = io_sink.InMemoryOutput.init();
        try out.writeAll(columnHeader());
        try out.writeAll(horizBorder());
        for (0..3) |row| {
            var buf: [64]u8 = undefined;
            try out.writeAll(try cellRow(row, snap, &buf));
        }
        try out.writeAll(horizBorder());
        for (3..6) |row| {
            var buf: [64]u8 = undefined;
            try out.writeAll(try cellRow(row, snap, &buf));
        }
        try out.writeAll(horizBorder());
        for (6..9) |row| {
            var buf: [64]u8 = undefined;
            try out.writeAll(try cellRow(row, snap, &buf));
        }
        try out.writeAll(horizBorder());
        break :blk out;
    };

    try std.testing.expectEqualStrings(mem_expected.contents(), mem.contents());
}
