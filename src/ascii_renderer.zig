const board = @import("board.zig");
const cell = @import("cell.zig");
const std = @import("std");
const Io = std.Io;
pub fn columnHeader() []const u8 {
    return "   A B C | D E F | G H I \n";
}

/// Return the horizontal box-border line.
pub fn horizBorder() []const u8 {
    return " +-------+-------+-------+\n";
}

/// Writer-injected renderer that renders from BoardView directly.
pub const AsciiRenderer = struct {
    writer: *Io.Writer,

    pub fn init(writer: *Io.Writer) AsciiRenderer {
        return .{ .writer = writer };
    }
    pub fn render(self: *AsciiRenderer, view: board.Board.BoardView) !void {
        try std.Io.Writer.writeAll(self.writer, columnHeader());
        try std.Io.Writer.writeAll(self.writer, horizBorder());
        for (0..9) |row| {
            var rowBuf: [64]u8 = undefined;
            const line = try cellRow(row, view, &rowBuf);
            try std.Io.Writer.writeAll(self.writer, line);

            if (row == 2 or row == 5) {
                try std.Io.Writer.writeAll(self.writer, horizBorder());
            }
        }

        try std.Io.Writer.writeAll(self.writer, horizBorder());
    }
};

fn cellRow(row: usize, view: board.Board.BoardView, buf: []u8) ![]u8 {
    const rv = board.Board.asRow(@intCast(row));
    const vals: [9]cell.CellValue = blk: {
        var v: [9]cell.CellValue = undefined;
        for (0..9) |i| {
            v[i] = view.board.cells[rv.indices[i]].value;
        }
        break :blk v;
    };

    return std.fmt.bufPrint(
        buf,
        "{d}| {c} {c} {c} | {c} {c} {c} | {c} {c} {c} |\n", .{
            row + 1,
            cell.displayChar(vals[0]), cell.displayChar(vals[1]), cell.displayChar(vals[2]),
            cell.displayChar(vals[3]), cell.displayChar(vals[4]), cell.displayChar(vals[5]),
            cell.displayChar(vals[6]), cell.displayChar(vals[7]), cell.displayChar(vals[8]),
        });
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
    var b = board.Board.init();
    const view = b.asView();

    var buf: [64]u8 = undefined;
    const line = cellRow(0, view, &buf);
    try std.testing.expectEqualStrings("1|       |       |       |\n", try line);
}

test "cell row (digits placed)" {
    const givens_row = [_]u8{
        // rows 0-6: all empty
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        // row 7: full set 5 1 3 | 6 7 8 | 2 4 9
        5, 1, 3, 6, 7, 8, 2, 4, 9,
        // row 8: all empty
        0, 0, 0, 0, 0, 0, 0, 0, 0,
    };

    var b = try board.fromFlat(givens_row);
    const view = b.asView();

    var buf: [64]u8 = undefined;
    const line = cellRow(7, view, &buf);
    try std.testing.expectEqualStrings("8| 5 1 3 | 6 7 8 | 2 4 9 |\n", try line);
}


test "AsciiRenderer renders empty board end-to-end" {

    const io = std.testing.io;
    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp_dir.close(io);
    
    const outfile = try tmp_dir.createFile(io, ".sudoku_test_empty.txt", .{});
    defer outfile.close(io);
    
    {
        var w = outfile.writer(io, &.{});
        var renderer = AsciiRenderer.init(&w.interface);
        var b = board.Board.init();
        try renderer.render(b.asView());
        try w.flush();
    }

    // Read back using Io.File reader
    {
        var dir2 = try Io.Dir.openDirAbsolute(io, "/tmp", .{});
        defer dir2.close(io);

         const f2 = try dir2.openFile(io, ".sudoku_test_empty.txt", .{});
        defer f2.close(io);


        // expected: column header, 4 borders, 9 empty data rows
        const expected = "   A B C | D E F | G H I \n" ++
            " +-------+-------+-------+\n" ++
            "1|       |       |       |\n" ++
            "2|       |       |       |\n" ++
            "3|       |       |       |\n" ++
            " +-------+-------+-------+\n" ++
            "4|       |       |       |\n" ++
            "5|       |       |       |\n" ++
            "6|       |       |       |\n" ++
            " +-------+-------+-------+\n" ++
            "7|       |       |       |\n" ++
            "8|       |       |       |\n" ++
            "9|       |       |       |\n" ++
            " +-------+-------+-------+\n";
        
        var readBuf: [512]u8 = undefined;
        var reader = Io.File.reader(f2, io, &readBuf);
        const contents = try std.Io.Reader.readAlloc(&reader.interface, std.testing.allocator,
            expected.len);
        defer std.testing.allocator.free(contents);

        try std.testing.expectEqualStrings(expected, contents);
    }
}
