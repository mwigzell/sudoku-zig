const board = @import("board.zig");
const cell = @import("cell.zig");
const styler = @import("styler.zig");
const std = @import("std");
const Io = std.Io;
pub fn columnHeader() []const u8 {
    return "   A B C | D E F | G H I \n";
}

/// Return the horizontal box-border line.
pub fn horizBorder() []const u8 {
    return " +-------+-------+-------+\n";
}

pub fn AsciiRenderer(StylerType: type) type {
    return struct {
        writer: *Io.Writer,
        styler: *StylerType,

        pub fn init(writer: *Io.Writer, styler_ptr: *StylerType) @This() {
            return .{ .writer = writer, .styler = styler_ptr };
        }
        pub fn render(self: *@This(), view: board.Board.BoardView) !void {
            try std.Io.Writer.writeAll(self.writer, columnHeader());
            try std.Io.Writer.writeAll(self.writer, horizBorder());
            for (0..9) |row| {
                var rowBuf: [256]u8 = undefined;
                const line = try self.styler.formatRow(row, view, &rowBuf);
                try std.Io.Writer.writeAll(self.writer, line);

                if (row == 2 or row == 5) {
                    try std.Io.Writer.writeAll(self.writer, horizBorder());
                }
            }

            try std.Io.Writer.writeAll(self.writer, horizBorder());
        }
    };
}

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
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(&aw.writer, &s);
    var b = board.Board.init();
    try renderer.render(b.asView());

    const contents = aw.writer.buffered();

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

    try std.testing.expectEqualStrings(expected, contents);
}
