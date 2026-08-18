const board = @import("../../board.zig");
const cell = @import("../../board/cell.zig");
const parser = @import("parser.zig");
const _command = @import("../../command.zig");
const save = @import("../../engine/save.zig");
const styler = @import("styler.zig");
const std = @import("std");
const Io = std.Io;
const facade = @import("../../renderer/facade.zig");
const input_source = @import("../../host/input_source.zig");
const PuzzleGen = @import("../../puzzle_gen.zig").PuzzleGen;
const Difficulty = @import("../../puzzle_gen.zig").Difficulty;

/// Terminal renderer for the 9x9 Sudoku board.
///
/// Implements the Facade vtable so the same game engine loop works over ASCII and
/// other renderers (a web renderer would fill this same shape with Canvas/JS
/// interop).
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
/// Stores a writer pointer, a styler
/// reference. Instance methods are routed through the Facade vtable via Make()
/// wrapper functions that coerce fn values to fn pointers.
pub fn AsciiRenderer(StylerType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: *Io.Writer,
        styler: *StylerType,
        inputSource: input_source.ReaderSource,
        last_filename: ?[]u8,

        /// Construct with writer (all output), styler pointer, and input source.
        pub fn init(allocator: std.mem.Allocator, writer: *Io.Writer, styler_ptr: *StylerType, inputSource: input_source.ReaderSource) @This() {
            return .{ .allocator = allocator, .writer = writer, .styler = styler_ptr, .inputSource = inputSource, .last_filename = null };
        }

        /// Destroy writer + styler heap pointers; keep last_filename free.
        pub fn deinit(self: *@This()) void {
            if (self.last_filename) |name| {
                self.allocator.free(name);
            }
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

        /// Implement Facade showLegend_fn. Build command legend from Legend,
        /// disambiguate prefixes, print "Command: ...". Arena allocates temp strings.
        pub fn showLegend(self: *@This(), commands: legend.Legend) anyerror!void {
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
            const raw = self.inputSource.readline() catch return facade.Error.System;
            // Caller needs an owned copy of the trimmed line
            const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
            defer self.allocator.free(raw);
            return self.allocator.dupe(u8, trimmed) catch return facade.Error.System;
        }

        /// Implement Facade showError_fn. Print the error message, then
        /// "Press Enter to continue..." and wait on stdin (via injected input source).
        pub fn showError(self: *@This(), msg: []const u8) facade.Error!void {
            self.writer.print("{s}\n", .{msg}) catch return facade.Error.System;
            self.writer.print("Press Enter to continue... ", .{}) catch return facade.Error.System;

            const line = try self.readLine();
            defer self.allocator.free(line);
        }

        /// Internal — prompt for filename with default, return owned string.
        fn saveAsDialog(self: *@This(), default_name: []const u8) facade.Error!_command.SaveFileResult {
            self.writer.print("Save to [{s}]: ", .{default_name}) catch return facade.Error.System;

            const line = self.readLine() catch return .Cancelled;

            if (line.len == 0) {
                defer self.allocator.free(line);
                const owned = self.allocator.dupe(u8, default_name) catch return facade.Error.System;
                return .{ .FileName = owned };
            }
            // Caller owns `line` — no free needed when returned directly.
            return .{ .FileName = line };
        }

        /// Internal — prompt for file path, return owned string.
        fn openDialog(self: *@This()) facade.Error!_command.OpenFileResult {
            self.writer.print("Open file: ", .{}) catch return facade.Error.System;

            const line = self.readLine() catch return .Cancelled;

            if (line.len == 0) {
                defer self.allocator.free(line);
                return .Cancelled;
            }
            // Caller owns `line` — no free needed when returned directly.
            return .{ .FileName = line };
        }

        /// Internal — difficulty sub-menu; returns an owned puzzle string.
        fn generatePuzzle(self: *@This()) facade.Error!_command.PuzzleResult {
            self.writer.writeAll("Difficulty:\n") catch return facade.Error.System;
            const levels = [_][]const u8{ "Easy", "Medium", "Hard" };
            for (levels, 0..) |name, i| {
                self.writer.print("  {d}) {s}\n", .{ i + 1, name }) catch return facade.Error.System;
            }
            self.writer.writeAll("> ") catch return facade.Error.System;

            const pick = self.readLine() catch return facade.Error.System;
            defer self.allocator.free(pick);

            const diff = if (std.mem.eql(u8, pick, "1")) Difficulty.easy else if (std.mem.eql(u8, pick, "2")) Difficulty.medium else if (std.mem.eql(u8, pick, "3")) Difficulty.hard else return .Cancelled;

            const puzzle = PuzzleGen.generate(diff);
            const owned = std.heap.page_allocator.dupe(u8, puzzle) catch return facade.Error.System;
            return .{ .PuzzleString = owned };
        }

        pub fn newGameOptions(self: *@This()) facade.Error!_command.PuzzleResult {
            const options = [_][]const u8{ "Generate New Puzzle", "Open From File", "Load From URL", "Paste Puzzle String" };
            self.writer.writeAll("\nNew game:\n") catch return facade.Error.System;
            for (options, 0..) |opt, i| {
                self.writer.print("{d}) {s}\n", .{ i + 1, opt }) catch return facade.Error.System;
            }
            self.writer.writeAll("> ") catch return facade.Error.System;

            const selection = self.readLine() catch return facade.Error.System;
            defer self.allocator.free(selection);

            if (std.mem.eql(u8, selection, "1")) return self.generatePuzzle();
            if (std.mem.eql(u8, selection, "2")) {
                const file_result = self.openDialog() catch return .Cancelled;
                return switch (file_result) {
                    .FileName => |path| .{ .PuzzleFile = path },
                    .Cancelled => .Cancelled,
                };
            }
            // No other menu choice is defined yet — a hard puzzle is generated and handed back.
            const puzzle = PuzzleGen.hard();
            const owned = std.heap.page_allocator.dupe(u8, puzzle) catch return facade.Error.System;
            return .{ .PuzzleString = owned };
        }

        /// Implement Facade getCommandInput_fn. Reads a line, parses it.
        pub fn getCommandInput(self: *@This(), names: []const []const u8) facade.Error!_command.ParseCommandResult {
            self.writer.writeAll(">") catch return facade.Error.System;
            self.writer.writeAll(" ") catch return facade.Error.System;

            const raw = self.inputSource.readline() catch return .{ .valid = _command.Command.quit };

            defer self.allocator.free(raw);

            if (names.len == 0) {
                return .{ .error_msg = "no commands available" };
            }

            var rsl = parser.parseWithCommands(raw, names);
            // Intercept save_as: get real filename from dialog, cache for future .save
            if (std.meta.activeTag(rsl) == .valid and
                std.meta.activeTag(rsl.valid) == .save_as)
            {
                const file_result = self.saveAsDialog(save.DEFAULT_SAVE_FILE) catch return .{ .error_msg = "cancelled" };
                switch (file_result) {
                    .FileName => |path| {
                        // Cache owns the path string; SaveData.path points to it as const (no extra dupe)
                        if (self.last_filename) |old| self.allocator.free(old);
                        self.last_filename = path;
                        rsl.valid.save_as.path = self.last_filename.?;
                    },
                    .Cancelled => return .{ .error_msg = "cancelled" },
                }
            }

            // Intercept save: use cached filename or prompt via dialog
            if (std.meta.activeTag(rsl) == .valid and
                std.meta.activeTag(rsl.valid) == .save)
            {
                if (self.last_filename) |cached| {
                    rsl.valid.save.path = cached;
                } else {
                    const file_result = self.saveAsDialog(save.DEFAULT_SAVE_FILE) catch return .{ .error_msg = "cancelled" };
                    switch (file_result) {
                        .FileName => |new_path| {
                            // Cache owns the path string; SaveData.path points to it as const
                            if (self.last_filename) |old| self.allocator.free(old);
                            self.last_filename = new_path;
                            rsl.valid.save.path = new_path;
                        },
                        .Cancelled => return .{ .error_msg = "cancelled" },
                    }
                }
            }

            // Intercept open: use cached filename or prompt via dialog
            if (std.meta.activeTag(rsl) == .valid and
                std.meta.activeTag(rsl.valid) == .open)
            {
                if (self.last_filename) |cached| {
                    rsl.valid.open.path = cached;
                } else {
                    const file_result = self.openDialog() catch return .{ .error_msg = "cancelled" };

                    switch (file_result) {
                        .FileName => |new_path| {
                            if (self.last_filename) |old| self.allocator.free(old);

                            self.last_filename = new_path;

                            rsl.valid.open.path = new_path;
                        },

                        .Cancelled => return .{ .error_msg = "cancelled" },
                    }
                }
            }

            // Intercept new: clear puzzle data, game engine handles it
            if (std.meta.activeTag(rsl) == .valid and
                std.meta.activeTag(rsl.valid) == .new)
            {
                const choice_result = self.newGameOptions() catch return .{ .error_msg = "cancelled" };
                switch (choice_result) {
                    .PuzzleString => |puzzle_str| {
                        rsl.valid.new.puzzle = puzzle_str;
                    },
                    .PuzzleFile => |path| {
                        rsl.valid.new.file = path;
                    },
                    .Cancelled => return .{ .error_msg = "cancelled" },
                }
            }

            return rsl;
        }
    };
}

// Tests - real renderer path, no mocks. Use Io.Writer.Allocating to
// capture output for assertions instead of hitting stdout.

const game_engine = @import("../../engine/game_engine.zig");
const disambiguate = @import("disambiguate.zig");
const legend = @import("../legend.zig");

test "showLegend: writes Command: with Fill Clear Quit" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, io) });

    const cmds = legend.Legend{
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
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, io) });

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
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, io) });

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
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // MockSource provides a canned "Enter" press so showError doesn't hang.
    const responses = [_][]const u8{"\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
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
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
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
        },
    }

    const contents = aw.writer.buffered();
    try std.testing.expectEqualStrings("Save to [test.sud]: ", contents);
}

test "saveAsDialog: custom input returns user filename" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"my_puzzle.sud\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
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
        },
    }
}

test "saveAsDialog: EOF returns Cancelled" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &[0][]const u8{}),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
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
        },
    }
}

test "openDialog: user enters a file path" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"my_save.sud\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
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
        },
    }

    const contents = aw.writer.buffered();
    try std.testing.expectEqualStrings("Open file: ", contents);
}

test "openDialog: EOF returns Cancelled" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &[0][]const u8{}),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
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
        },
    }
}

test "openDialog: empty input returns Cancelled" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
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
        },
    }
}

test "newGameOptions: option 1 shows difficulty sub-menu and returns easy puzzle" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "1\n", "1\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.newGameOptions();
    switch (result) {
        .PuzzleString => |puzzle| {
            defer std.heap.page_allocator.free(puzzle);
            const easy = PuzzleGen.easy();
            try std.testing.expectEqualStrings(easy, puzzle);
        },
        .PuzzleFile => |path| {
            std.testing.allocator.free(path);
            try std.testing.expect(false);
        },
        .Cancelled => try std.testing.expect(false),
    }

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "1) Easy") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "2) Medium") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "3) Hard") != null);
}

test "newGameOptions: option 1 sub-selection 2 returns medium puzzle" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "1\n", "2\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.newGameOptions();
    switch (result) {
        .PuzzleString => |puzzle| {
            defer std.heap.page_allocator.free(puzzle);
            try std.testing.expectEqualStrings(PuzzleGen.medium(), puzzle);
        },
        .PuzzleFile => |path| {
            std.testing.allocator.free(path);
            try std.testing.expect(false);
        },
        .Cancelled => try std.testing.expect(false),
    }
}

test "newGameOptions: option 1 sub-selection 3 returns hard puzzle" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "1\n", "3\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.newGameOptions();
    switch (result) {
        .PuzzleString => |puzzle| {
            defer std.heap.page_allocator.free(puzzle);
            try std.testing.expectEqualStrings(PuzzleGen.hard(), puzzle);
        },
        .PuzzleFile => |path| {
            std.testing.allocator.free(path);
            try std.testing.expect(false);
        },
        .Cancelled => try std.testing.expect(false),
    }
}

test "newGameOptions: out-of-range sub-selection returns Cancelled" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "1\n", "9\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.newGameOptions();
    switch (result) {
        .Cancelled => try std.testing.expect(true),
        .PuzzleString => |puzzle| {
            std.heap.page_allocator.free(puzzle);
            try std.testing.expect(false);
        },
        .PuzzleFile => |path| {
            std.testing.allocator.free(path);
            try std.testing.expect(false);
        },
    }
}

test "newGameOptions: option 2 returns the entered filename as PuzzleFile" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "2\n", "mypuzzle.sud\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.newGameOptions();
    switch (result) {
        .PuzzleFile => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expectEqualStrings("mypuzzle.sud", path);
        },
        .PuzzleString => |puzzle| {
            std.heap.page_allocator.free(puzzle);
            try std.testing.expect(false);
        },
        .Cancelled => try std.testing.expect(false),
    }

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "Open file:") != null);
}

test "newGameOptions: option 2 empty filename returns Cancelled" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "2\n", "\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.newGameOptions();
    switch (result) {
        .Cancelled => try std.testing.expect(true),
        .PuzzleFile => |path| {
            std.testing.allocator.free(path);
            try std.testing.expect(false);
        },
        .PuzzleString => |puzzle| {
            std.heap.page_allocator.free(puzzle);
            try std.testing.expect(false);
        },
    }
}

test "getCommandInput: fill A1 5 returns valid Fill" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"fill A1 5\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const avail = legend.Legend{
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

    var names: [9][]const u8 = undefined;
    const count = avail.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count]);

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
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // Empty mock responses list triggers ReadEOF
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &[0][]const u8{}),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const avail = legend.Legend{
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

    var names: [9][]const u8 = undefined;
    const count = avail.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count]);

    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "quit");
        },
        .error_msg => {
            try std.testing.expect(false); // should map to quit, not an error
        },
    }
}
test "AsciiRenderer init last_filename is null" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, io) },
    );
    defer renderer.deinit();

    try std.testing.expect(renderer.last_filename == null);
}

// Test 1: save with last_filename set dupe's the cached path, no dialog prompt.
test "getCommandInput: save with last_filename set uses cached path" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // Only one mock response: the command itself. Save intercept uses cached filename, no dialog.
    const responses = [_][]const u8{"s\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );
    defer renderer.deinit();

    // Pre-set last_filename (simulating a previous save/save_as)
    renderer.last_filename = std.testing.allocator.dupe(u8, "cached.sud") catch unreachable;

    const avail = legend.Legend{
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

    var names: [9][]const u8 = undefined;
    const count = avail.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count]);

    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "save");
            try std.testing.expectEqualStrings("cached.sud", cmd.save.path.?);
        },
        .error_msg => |msg| {
            _ = msg;
            try std.testing.expect(false);
        },
    }
}

test "getCommandInput: save with last_filename null prompts and caches" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // First response: command "s", second response: filename from save dialog
    const responses = [_][]const u8{ "s\n", "my_save.sud\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );
    defer renderer.deinit();

    const avail = legend.Legend{
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

    var names: [9][]const u8 = undefined;
    const count = avail.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count]);

    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "save");
            try std.testing.expectEqualStrings("my_save.sud", cmd.save.path.?);
        },
        .error_msg => |msg| {
            try std.testing.expect(std.ascii.eqlIgnoreCase(msg, ""));
        },
    }

    // last_filename should now be cached
    try std.testing.expect(renderer.last_filename != null);
    try std.testing.expectEqualStrings("my_save.sud", renderer.last_filename.?);
}

test "getCommandInput: save then save reuses cached filename without prompting" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // First save: command + dialog response; second save: only command (no dialog)
    const responses = [_][]const u8{ "s\n", "first.sud\n", "s\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );
    defer renderer.deinit();

    const avail = legend.Legend{
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

    var names: [9][]const u8 = undefined;
    const count = avail.getNames(&names);

    // First save — should prompt and cache
    const result1 = try renderer.getCommandInput(names[0..count]);
    switch (result1) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "save");
            try std.testing.expectEqualStrings("first.sud", cmd.save.path.?);
        },
        .error_msg => {
            try std.testing.expect(false);
        },
    }

    // Second save — should use cached, no prompt
    const result2 = try renderer.getCommandInput(names[0..count]);
    switch (result2) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "save");
            try std.testing.expectEqualStrings("first.sud", cmd.save.path.?);
        },
        .error_msg => {
            try std.testing.expect(false);
        },
    }
}
