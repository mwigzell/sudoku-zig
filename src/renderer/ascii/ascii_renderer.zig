const board = @import("../../board.zig");
const cell = @import("../../cell.zig");
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

        pub fn render(self: *@This(), view: board.Board.BoardView, status_msg: ?[]const u8) anyerror!void {
            _ = status_msg; // reserved for status bar, not legend

            try self.writer.writeAll(columnHeader());
            try self.writer.writeAll(topBorder());

            for (0..9) |row| {
                var rowBuf: [256]u8 = undefined;
                const line = try self.styler.formatRow(row, view, &rowBuf);
                try self.writer.writeAll(line);

                if (row == 2 or row == 5) {
                    try self.writer.writeAll(midBorder());
                }
            }

            try self.writer.writeAll(bottomBorder());
        }

        pub fn showLegend(self: *@This(), commands: game_engine.AvailableCommands) anyerror!void {
            var names: [7][]const u8 = undefined;
            const count = commands.getNames(&names);

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const entries = try disambiguate.getMinimumPrefixes(arena.allocator(), names[0..count]);
            const str = try legend.formatLegend(arena.allocator(), entries);
            _ = try self.writer.print("  Command: {s}\n", .{str});
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — go through the real renderer path, not a mock or wrapper

const game_engine = @import("../../game_engine.zig");
const disambiguate = @import("../../command/disambiguate.zig");
const legend = @import("../../command/legend.zig");

test "showLegend: writes Command: with Fill Clear Quit" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(&aw.writer, &s);

    const cmds = game_engine.AvailableCommands{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .save = false,
        .open = false,
    };
    try renderer.showLegend(cmds);

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "  Command:") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(F)ill") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(C)lear") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(Q)uit") != null);
}

test "render: renders empty board end-to-end" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(&aw.writer, &s);

    const b = board.Board.init();
    try renderer.render(b.asView(), null);

    const contents = aw.writer.buffered();

    try std.testing.expectEqualStrings(
        "   A B C │ D E F │ G H I \n" ++
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
            " ╰───────┴───────┴───────╯\n",
        contents,
    );
}

test "render: renders with digits placed" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(&aw.writer, &s);

    const givens_row = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 3, 0, 0, 0, 1, 0,
        0, 9, 8, 0, 2, 7, 0, 6, 0,
    };
    var rest: [54]u8 = undefined;
    @memset(&rest, 0);

    var flat: [81]u8 = undefined;
    @memcpy(flat[0..27], &givens_row);
    @memcpy(flat[27..], &rest);

    const b = try board.fromFlat(flat, .{});
    try renderer.render(b.asView(), null);

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "9") != null);
}
