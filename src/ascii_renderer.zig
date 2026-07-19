const board = @import("board.zig");
const cell = @import("cell.zig");
const styler = @import("styler.zig");
const std = @import("std");
const Io = std.Io;

pub fn columnHeader() []const u8 {
    return "   A B C │ D E F │ G H I \n";
}

pub fn topBorder() []const u8 {
    return " ╭───────┼───────┼───────╮\n";
}

pub fn midBorder() []const u8 {
    return " ├───────┼───────┼───────┤\n";
}

pub fn bottomBorder() []const u8 {
    return " ╰───────┴───────┴───────╯\n";
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
            try std.Io.Writer.writeAll(self.writer, topBorder());

            for (0..9) |row| {
                var rowBuf: [256]u8 = undefined;
                const line = try self.styler.formatRow(row, view, &rowBuf);
                try std.Io.Writer.writeAll(self.writer, line);

                if (row == 2 or row == 5) {
                    try std.Io.Writer.writeAll(self.writer, midBorder());
                }
            }

            try std.Io.Writer.writeAll(self.writer, bottomBorder());
        }
    };
}

// Tests (co-located) — helper functions + render path
//
// These are foundational: columnHeader / topBorder / midBorder / bottomBorder
// and the row-level tests feed directly into AsciiRenderer.render(). The higher
// level end-to-end test auto-passes when these lower-level primitives are correct.
// DO NOT REMOVE these tests if you think "it's duplicated end-to-end" — they're
// not; they're what make the end-to-end pass. Without them a regression in a
// helper string or separator goes undetected until someone spots a visual glitch.
test "column header" {
    try std.testing.expectEqualStrings(
        "   A B C │ D E F │ G H I \n",
        columnHeader(),
    );
}

test "top border" {
    try std.testing.expectEqualStrings(
        " ╭───────┼───────┼───────╮\n",
        topBorder(),
    );
}

test "mid border" {
    try std.testing.expectEqualStrings(
        " ├───────┼───────┼───────┤\n",
        midBorder(),
    );
}

test "bottom border" {
    try std.testing.expectEqualStrings(
        " ╰───────┴───────┴───────╯\n",
        bottomBorder(),
    );
}


test "cell row (empty)" {
    var b = board.Board.init();
    const view = b.asView();

    var buf: [64]u8 = undefined;
    var styler_inst = styler.PlainStyler{};
    const line = try styler_inst.formatRow(0, view, &buf);
    try std.testing.expectEqualStrings("1│       │       │       │\n", line);
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
    var styler_inst = styler.PlainStyler{};
    const line = try styler_inst.formatRow(7, view, &buf);
    try std.testing.expectEqualStrings("8│ 5 1 3 │ 6 7 8 │ 2 4 9 │\n", line);
}
test "AsciiRenderer renders empty board end-to-end via PlainStyler" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(&aw.writer, &s);
    var b = board.Board.init();
    try renderer.render(b.asView());

    const contents = aw.writer.buffered();

    // expected: column header, top/mid/bottom borders, 9 empty data rows
    // PlainStyler formatRow uses │ separators and template "{d}| {c}..."
    const expected = "   A B C │ D E F │ G H I \n" ++
        " ╭───────┼───────┼───────╮\n" ++
        "1│       │       │       │\n" ++
        "2│       │       │       │\n" ++
        "3│       │       │       │\n" ++
        " ├───────┼───────┼───────┤\n" ++
        "4│       │       │       │\n" ++
        "5│       │       │       │\n" ++
        "6│       │       │       │\n" ++
        " ├───────┼───────┼───────┤\n" ++
        "7│       │       │       │\n" ++
        "8│       │       │       │\n" ++
        "9│       │       │       │\n" ++
        " ╰───────┴───────┴───────╯\n";

    try std.testing.expectEqualStrings(expected, contents);
}

test "AsciiRenderer renders via AnsiStyler - dim givens preserved" {
    const givens_row = [_]u8{
        5, 3, 0, 0, 7, 0, 0, 0, 0,
        6, 0, 0, 1, 9, 5, 0, 0, 0,
        0, 9, 8, 0, 0, 0, 0, 6, 0,
    };
    var rest: [54]u8 = undefined;
    @memset(&rest, 0);

    var flat: [81]u8 = undefined;
    @memcpy(flat[0..27], &givens_row);
    @memcpy(flat[27..], &rest);

    var b = try board.fromFlat(flat);
    const view = b.asView();

    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.AnsiStyler{};
    var renderer = AsciiRenderer(styler.AnsiStyler).init(&aw.writer, &s);
    try renderer.render(view);

    const contents = aw.writer.buffered();

    const dim_count = std.mem.count(u8, contents, "\x1b[2m");
    try std.testing.expect(dim_count > 0);
}

