const board = @import("../../board.zig");
const cell = @import("../../cell.zig");
const styler = @import("styler.zig");
const std = @import("std");
const Io = std.Io;
const facade = @import("../../renderer/facade.zig");


/// Terminal renderer for the 9x9 Sudoku board.
///
/// Implements the Renderer Facade vtable (Issue 29) so the same game
/// engine loop works unmodified when wasm-targeted: a WASM renderer will
/// fill the same vtable shape pointing to Canvas/JS interop instead.
///
/// Parameterised over StylerType so tests can use PlainStyler and
/// production code swaps in ANSI-capable styler at runtime.

// Box-drawing border strings - shared constants for the 9x9 grid.
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

/// Terminal implementation of the Renderer Facade.
///
/// Stores an Io handle (stdin reads), a writer pointer, and a styler
/// reference. Instance methods are routed through the Facade vtable via Make()
/// wrapper functions that coerce fn values to fn pointers.
pub fn AsciiRenderer(StylerType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: *Io.Writer,
        styler: *StylerType,
        io: std.Io,

        /// Construct with Io handle (stdin), writer (all output), and styler pointer.
        pub fn init(allocator: std.mem.Allocator, io: std.Io, writer: *Io.Writer, styler_ptr: *StylerType) @This() {
            return .{ .allocator = allocator, .io = io, .writer = writer, .styler = styler_ptr };
        }

        /// Draw the full board: column header, borders, styled rows via formatRow,
        /// with box-drawing borders between 3x3 boxes. status_msg is reserved.
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

        /// Implement Facade showLegend_fn. Build command legend from AvailableCommands,
        /// disambiguate prefixes, print "Command: ...". Arena allocates temp strings.
        pub fn showLegend(self: *@This(), commands: game_engine.AvailableCommands) anyerror!void {
            var names: [7][]const u8 = undefined;
            const count = commands.getNames(&names);

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const entries = try disambiguate.getMinimumPrefixes(arena.allocator(), names[0..count]);
            const str = try legend.formatLegend(arena.allocator(), entries);
            _ = try self.writer.print("  Command: {s}\n", .{str});
        }

        /// Implement Facade showError_fn. Print the error message, then
        /// "Press Enter to continue..." and wait on stdin. Replaces old waitAck().
        pub fn showError(self: *@This(), msg: []const u8) facade.Error!void {
            try self.writer.print("{s}\n", .{msg});
            try self.writer.print("Press Enter to continue... ", .{});

            var buf: [512]u8 = undefined;
            const in_ = Io.File.stdin().reader(self.io, &buf);
            _ = try in_.takeDelimiter('\n') orelse return facade.Error.ReadEOF;
        }

        /// Implement Facade saveDialog_fn. Prompt for filename with default, return owned string.
        pub fn saveDialog(self: *@This(), default_name: []const u8) facade.Error!facade.SaveFileResult {
            try self.writer.print("Save to [{s}]: ", .{default_name});

            var buf: [512]u8 = undefined;
            const in_ = Io.File.stdin().reader(self.io, &buf);
            const input = try in_.takeDelimiter('\n') orelse return facade.Error.ReadEOF;

            const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
            if (trimmed.len == 0) {
                // User pressed Enter — use default filename
                const owned = self.allocator.dupe(u8, default_name) catch return facade.Error.OutOfMemory;
                return .{ .FileName = owned };
            }

            const owned = self.allocator.dupe(u8, trimmed) catch return facade.Error.OutOfMemory;
            return .{ .FileName = owned };
        }
    };
}

// Tests - real renderer path, no mocks. Use Io.Writer.Allocating to
// capture output for assertions instead of hitting stdout.

const game_engine = @import("../../game_engine.zig");
const disambiguate = @import("../../command/disambiguate.zig");
const legend = @import("../../command/legend.zig");

test "showLegend: writes Command: with Fill Clear Quit" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, io, &aw.writer, &s);

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
    const io = std.testing.io;

    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, io, &aw.writer, &s);

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
    const io = std.testing.io;

    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, io, &aw.writer, &s);

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
