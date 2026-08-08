const board = @import("../../board.zig");
const cell = @import("../../cell.zig");
const command_parse = @import("../../command/parse.zig");
const styler = @import("styler.zig");
const std = @import("std");
const Io = std.Io;
const facade = @import("../../renderer/facade.zig");
const input_source = @import("../../input_source.zig");


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
        inputSource: input_source.ReaderSource,

        /// Construct with Io handle (stdin), writer (all output), styler pointer, and input source.
        pub fn init(allocator: std.mem.Allocator, io: std.Io, writer: *Io.Writer, styler_ptr: *StylerType, inputSource: input_source.ReaderSource) @This() {
            return .{ .allocator = allocator, .io = io, .writer = writer, .styler = styler_ptr, .inputSource = inputSource };
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
            var names: [9][]const u8 = undefined;
            const count = commands.getNames(&names);

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const entries = try disambiguate.getMinimumPrefixes(arena.allocator(), names[0..count]);
            const str = try legend.formatLegend(arena.allocator(), entries);
            _ = try self.writer.print("  Command: {s}\n", .{str});
        }

        /// Read one line from the injected input source.
        /// Caller owns returned string and must free it.
        pub fn readLine(self: *@This()) facade.Error![]u8 {
            const raw = self.inputSource.readline(self.io) catch return facade.Error.UnexpectedEOF;
            // Caller needs an owned copy of the trimmed line
            const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
            defer self.allocator.free(raw);
            return self.allocator.dupe(u8, trimmed) catch return facade.Error.OutOfMemory;
        }

        /// Implement Facade showError_fn. Print the error message, then
        /// "Press Enter to continue..." and wait on stdin (via injected input source).
        pub fn showError(self: *@This(), msg: []const u8) facade.Error!void {
            self.writer.print("{s}\n", .{msg}) catch return facade.Error.WriteFault;
            self.writer.print("Press Enter to continue... ", .{}) catch return facade.Error.WriteFault;

            const line = try self.readLine();
            defer self.allocator.free(line);
        }

        /// Internal — prompt for filename with default, return owned string.
        pub fn saveAsDialog(self: *@This(), default_name: []const u8) facade.Error!facade.SaveFileResult {
            self.writer.print("Save to [{s}]: ", .{default_name}) catch return facade.Error.WriteFault;

            const line = self.readLine() catch return .Cancelled;

            if (line.len == 0) {
                defer self.allocator.free(line);
                const owned = self.allocator.dupe(u8, default_name) catch return facade.Error.OutOfMemory;
                return .{ .FileName = owned };
            }
            // Caller owns `line` — no free needed when returned directly.
            return .{ .FileName = line };
            }

        /// Internal — prompt for file path, return owned string.
        pub fn openDialog(self: *@This()) facade.Error!facade.OpenFileResult {
            self.writer.print("Open file: ", .{}) catch return facade.Error.WriteFault;

            const line = self.readLine() catch return .Cancelled;

            if (line.len == 0) {
                defer self.allocator.free(line);
                return .Cancelled;
            }
            // Caller owns `line` — no free needed when returned directly.
            return .{ .FileName = line };
        }

        /// Implement Facade newGameOptions_fn. Stubbed — always returns the easy puzzle string.
        pub fn newGameOptions(self: *@This()) facade.Error!facade.PuzzleReturn {
            const puzzle_gen = @import("../../puzzle_gen.zig").PuzzleGen;
            const puzzle = puzzle_gen.easy();
            const owned = self.allocator.dupe(u8, puzzle) catch return facade.Error.OutOfMemory;
            return .{ .PuzzleString = owned };
        
        }

        /// Implement Facade getCommandInput_fn. Reads a line, parses it.
        pub fn getCommandInput(self: *@This(), avail: game_engine.AvailableCommands) facade.Error!facade.ParseCommandResult {
            self.writer.writeAll("> ") catch return facade.Error.WriteFault;

            const raw = self.inputSource.readline(self.io)
                catch return .{ .valid = command_parse.Command.quit };
            defer self.allocator.free(raw);

            var names: [9][]const u8 = undefined;
            const count = avail.getNames(&names);
            if (count == 0) {
                return .{ .error_msg = "no commands available" };
            }

            var rsl = command_parse.parseWithCommands(raw, names[0..count]);
            // Intercept save_as: get real filename from dialog
            if (std.meta.activeTag(rsl) == .valid and
                    std.meta.activeTag(rsl.valid) == .save_as) {
                    const file_result = self.saveAsDialog(".sudoku_save.sud") catch return .{.error_msg = "cancelled"};
                switch (file_result) {
                    .FileName => |path| rsl.valid.save_as.path = path,
                    .Cancelled => return .{ .error_msg = "cancelled" },
                }
            }
            return rsl;
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
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, io, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator) });

    const cmds = game_engine.AvailableCommands{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .save = false,
        .open = false,
        .new = true,
        .save_as = true,
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
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, io, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator) });

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
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, io, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator) });

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



test "showError: reads from MockSource and does not panic" {
    const io = std.testing.io;

    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // MockSource provides a canned "Enter" press so showError doesn't hang.
    const responses = [_][]const u8{ "\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    try renderer.showError("something went wrong");

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "something went wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") != null);
}

test "saveAsDialog: empty input returns default filename" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.saveAsDialog("test.sud");

    switch (result) {
        .FileName => |name| {
            defer std.testing.allocator.free(name);
            try std.testing.expectEqualStrings("test.sud", name);
        },
        .Cancelled => {
            try std.testing.expect(false);
        }
    }

    const contents = aw.writer.buffered();
    try std.testing.expectEqualStrings("Save to [test.sud]: ", contents);
}

test "saveAsDialog: custom input returns user filename" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "my_puzzle.sud\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.saveAsDialog("default.sud");

    switch (result) {
        .FileName => |name| {
            defer std.testing.allocator.free(name);
            try std.testing.expectEqualStrings("my_puzzle.sud", name);
        },
        .Cancelled => {
            try std.testing.expect(false);
        }
    }
}

test "saveAsDialog: EOF returns Cancelled" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &[0][]const u8{}),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.saveAsDialog("test.sud");
    switch (result) {
        .Cancelled => try std.testing.expect(true),
        .FileName => |name| {
            defer std.testing.allocator.free(name);
            try std.testing.expect(false);
        }
    }
}

test "openDialog: user enters a file path" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "my_save.sud\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.openDialog();

    switch (result) {
        .FileName => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expectEqualStrings("my_save.sud", path);
        },
        .Cancelled => {
            try std.testing.expect(false);
        }
    }

    const contents = aw.writer.buffered();
    try std.testing.expectEqualStrings("Open file: ", contents);
}

test "openDialog: EOF returns Cancelled" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &[0][]const u8{}),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.openDialog();
    switch (result) {
        .Cancelled => try std.testing.expect(true),
        .FileName => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expect(false);
        }
    }
}

test "openDialog: empty input returns Cancelled" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.openDialog();
    switch (result) {
        .Cancelled => try std.testing.expect(true),
        .FileName => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expect(false);
        }
    }
}

test "newGameOptions: '1' returns Choice Generated" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "1\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.newGameOptions();

    switch (result) {
        .PuzzleString => |puzzle| {
            defer std.testing.allocator.free(puzzle);
        },
        .Cancelled => {
            try std.testing.expect(false);
        }
    }
}


test "getCommandInput: fill A1 5 returns valid Fill" {
    const io = std.testing.io;

    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "fill A1 5\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const avail = game_engine.AvailableCommands{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .save = true,
        .open = true,
        .new = true,
        .save_as = true,
    };

    const result = try renderer.getCommandInput(avail);

    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "fill");
            try std.testing.expectEqual(@as(u4, 0), cmd.fill.row);
            try std.testing.expectEqual(@as(u4, 0), cmd.fill.col);
            try std.testing.expectEqual(cell.CellValue.five, cmd.fill.digit);
        },
        .error_msg => |msg| {
            try std.testing.expect(std.ascii.eqlIgnoreCase(msg, "")); // should not be an error
        },
    }
}

test "getCommandInput: EOF returns Quit" {
    const io = std.testing.io;

    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // Empty mock responses list triggers ReadEOF
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &[0][]const u8{}),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        io,
        &aw.writer,
        &s,
        source,
    );

    const avail = game_engine.AvailableCommands{
        .fill = true,
        .clear = false,
        .quit = true,
        .undo = false,
        .redo = false,
        .save = false,
        .open = false,
        .new = false,
        .save_as = false,
    };

    const result = try renderer.getCommandInput(avail);

    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "quit");
        },
        .error_msg => {
            try std.testing.expect(false); // should map to quit, not an error
        },
    }
}
