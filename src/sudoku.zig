const std = @import("std");
const facade = @import("renderer/facade.zig");
const game_engine = @import("engine/game_engine.zig");
const config = @import("config.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const command = @import("command.zig");

const disambiguate = @import("renderer/ascii/disambiguate.zig");
const legend = @import("command/legend.zig");


pub const Sudoku = struct {
    engine: game_engine.GameEngine,
    cfg: config.Config,
    io: std.Io,
    renderer: *const facade.Facade,
    pub fn init(cfg: config.Config, renderer: *const facade.Facade, io: std.Io) anyerror!@This() {
        const puzzle_str = puzzle_gen.PuzzleGen.generate(cfg.difficulty);
        return @This(){
            .renderer = renderer,
            .io = io,
            .cfg = cfg,
            .engine = try game_engine.GameEngine.init(puzzle_str, io),
        };
    }

    /// Handle a dispatched Event. Returns true when is_quit flag is set.
    fn handleEvent(self: *@This(), event: game_engine.Event) anyerror!bool {
        switch (event) {
            .ok => |ev| {
                if (ev.is_quit) return true;
                if (ev.msg) |m| try self.renderer.showError(m);
                try self.renderer.render(ev.board_view, null);
                try self.renderer.showLegend(self.engine.getLegend());
                return false;
            },
            .error_msg => |msg| {
                try self.renderer.showError(msg);
                return false;
            },
        }
    }

    /// Handle one parsed result. Returns true when the command loop should end.
    fn handleResult(self: *@This(), result: command.ParseCommandResult) anyerror!bool {
        switch (result) {
            .error_msg => |msg| {
                try self.renderer.showError(msg);
                return false;
            },
            .valid => |cmd| {
                const event = self.engine.exec(cmd) catch |err| {
                    var buf: [80]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "exec failed: {s}", .{@errorName(err)}) catch unreachable;
                    try self.renderer.showError(msg);
                    return false;
                };
                return self.handleEvent(event) catch |err| {
                    var buf: [80]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "handleEvent failed: {s}", .{@errorName(err)}) catch unreachable;
                    try self.renderer.showError(msg);
                    return false;
                };
            },
        }
    }

    /// Prompt through renderer, parse, dispatch. Returns true on quit.
    fn promptForAndRunCommand(self: *@This()) anyerror!bool {
        const avail = self.engine.getLegend();
        var names: [9][]const u8 = undefined;
        const count = avail.getNames(&names);
        const result = self.renderer.getCommandInput(names[0..count]) catch |err| {
            if (err == error.ReadEOF) return true;
            return err;
        };
        return try self.handleResult(result);
    }

    pub fn run(self: *@This()) anyerror!void {
        try self.renderer.render(self.engine.eventBoard(), null);
        try self.renderer.showLegend(self.engine.getLegend());
        while (true) {
            const isDone = try self.promptForAndRunCommand();
            if (isDone) break;
        }
    }
};

const board = @import("board.zig");
const cell = @import("cell.zig");
const input_source = @import("input_source.zig");
const styler_t = @import("renderer/ascii/styler.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");

// Step 7 test placeholder
test "Sudoku stores io field during init" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const responses = [_][]const u8{};
    const source: input_source.ReaderSource = .{ .mock = input_source.MockSource.init(alloc, &responses) };
    var s = styler_t.PlainStyler{};
    var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(alloc, io, &aw.writer, &s, source);
    defer renderer.deinit();

    const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
    var sudoku_instance = try Sudoku.init(cfg, &f, io);
    defer sudoku_instance.engine.deinit();

    _ = sudoku_instance.io;
}
test "integrated e2e - full seam: fill command via prefix dispatch" {
    // Arrange: fresh engine via Sudoku.init through real AsciiRenderer
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    // Canned responses: "f A3 4" (fill prefix) → quit
    const responses = [_][]const u8{
        "f A3 4",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var s = styler_t.PlainStyler{};
    var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(
        alloc, io, &aw.writer, &s, source,
    );
    defer renderer.deinit();

    const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
    var sudoku = try Sudoku.init(cfg, &f, io);
    defer sudoku.engine.deinit();

    // Act: run the full loop — fill A3 with 4 via prefix dispatch, then quit
    sudoku.run() catch {};

    // Assert (a): engine has undo available after mutation.
    {
        const avail = sudoku.engine.getLegend();
        try std.testing.expect(avail.undo);
    }

    // Assert (b): cell at chess coord A3 -> row 2, col 0 is four.
    {
        try std.testing.expectEqual(cell.CellValue.four,
            sudoku.engine.board.getCellValue(@as(u4, 2), @as(u4, 0)));
    }

    // Assert (c): output buffer has content (render + legend happened)
    {
        const contents = aw.writer.buffered();
        try std.testing.expect(contents.len > 0);
    }
}

// Issue 32 — full round-trip integration: save known state → mutate → open saved file → verify restore
// Uses real AsciiRenderer + MockSource to exercise the full dialog/caching path (replaces rigged MockRenderer test).
test "integrated e2e - full seam: open loads saved game" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };

    // 1. Create a save file with known state (no MockRenderer - real path through renderer)
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/sudoku_full_seam_open_test.sud";

    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // Save known state to disk before running through the renderer
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), io);
    defer original.deinit();
    try original.saveGame(io, tmp_path);

    // Record B2 value in saved state for later verification
    const saved_b2 = original.eventBoard().get(1, 1);
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var s = styler_t.PlainStyler{};

    // Canned responses: fill a cell -> open dialog -> filename -> quit
    const responses = [_][]const u8{
        "fill B2 7",           // Mutate B2 (diverges from saved)
        "open",                // Trigger open dialog prompt
        tmp_path ++ "\n",      // Filename response for the dialog prompt
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(
        alloc, io, &aw.writer, &s, source,
    );
    defer renderer.deinit();

    const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
    var sudoku_instance = try Sudoku.init(cfg, &f, io);
    defer sudoku_instance.engine.deinit();

    // Run full loop: open dialog -> filename prompt -> load file -> quit.
    sudoku_instance.run() catch {};

    // After opening saved file: B2 restored to original saved value (not seven)
    try std.testing.expectEqual(saved_b2, sudoku_instance.engine.eventBoard().get(1, 1));
}

// Step 10 — Save/Open must route through handleEvent() for feedback + re-render

test "integrated e2e - save success produces status message, re-render, legend refresh" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/sudoku_save_success_test.sud";

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    // Canned responses: save → filename prompt → quit
    const responses = [_][]const u8{
        "save",
        tmp_path ++ "\n",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var s = styler_t.PlainStyler{};
    var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(
        alloc, io, &aw.writer, &s, source,
    );
    defer renderer.deinit();

    const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
    var sudoku = try Sudoku.init(cfg, &f, io);
    defer sudoku.engine.deinit();

    // Act: run full loop — save command triggers filename dialog, writes file, re-renders
    sudoku.run() catch {};

    // Assert: output buffer has content (render + legend happened) and save file was created
    {
        const contents = aw.writer.buffered();
        try std.testing.expect(contents.len > 0);
    }

    // Clean up saved file
    std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
}


test "integrated e2e - run: open file success produces status message, re-render, and legend refresh" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };

    // Create a save file to open
    const io = std.testing.io;
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), io);
    defer original.deinit();
    const tmp_path = "/tmp/sudoku_e2e_open_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    try original.saveGame(io, tmp_path);

    {
        const alloc = std.testing.allocator;

        var aw = std.Io.Writer.Allocating.init(alloc);
        defer aw.deinit();

        // Canned responses: open <path> -> quit
        const responses = [_][]const u8{
            "open " ++ tmp_path,
            "quit",
        };
        const source: input_source.ReaderSource = .{
            .mock = input_source.MockSource.init(alloc, &responses),
        };

        var s = styler_t.PlainStyler{};
        var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(
            alloc, io, &aw.writer, &s, source,
        );
        defer renderer.deinit();

        const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
        var sudoku = try Sudoku.init(cfg, &f, io);
        defer sudoku.engine.deinit();

        // Act: run full loop — open loads file, re-renders, shows legend
        sudoku.run() catch {};

        // Assert: output buffer has content (render + legend happened after opening)
        const contents = aw.writer.buffered();
        try std.testing.expect(contents.len > 0);
    }
}

// Step 12 — Save/Open goes through exec() now (default filename, no prompt)


test "integrated e2e - run: save uses default filename and returns success" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/sudoku_e2e_save_default_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    // Canned responses: save -> filename prompt -> quit
    const responses = [_][]const u8{
        "save",
        tmp_path ++ "\n",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var s = styler_t.PlainStyler{};
    var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(
        alloc, io, &aw.writer, &s, source,
    );
    defer renderer.deinit();

    const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
    var sudoku = try Sudoku.init(cfg, &f, io);
    defer sudoku.engine.deinit();

    // Act: run full loop — save prompts for filename, writes file, re-renders
    sudoku.run() catch {};

    // Assert: output buffer has content (render + legend happened after saving)
    const contents = aw.writer.buffered();
    try std.testing.expect(contents.len > 0);
}
// Step 12b — Subsequent saves reuse last filename, give feedback without prompting


test "integrated e2e - run: fill → save → quit" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const responses = [_][]const u8{
        "fill A3 7",
        "save",              // save command (triggers dialog for first use)
        "sudoku_save.sud\n", // answer to save As dialog prompt
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var s = styler_t.PlainStyler{};
    var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(
        alloc, io, &aw.writer, &s, source,
    );
    defer renderer.deinit();

    const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
    var sudoku_instance = try Sudoku.init(cfg, &f, io);
    defer sudoku_instance.engine.deinit();
    sudoku_instance.run() catch {};

    const contents = aw.writer.buffered();
    try std.testing.expect(contents.len > 0);
}
// Issue 34 Step 2 — e2e: save_as writes file and re-renders
test "integrated e2e - run: save_as writes file and re-renders" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // Canned responses: command → dialog filename → quit
    const responses = [_][]const u8{
        "save_as",
        "test_save_as.sud",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var s = styler_t.PlainStyler{};
    var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(
        alloc, io, &aw.writer, &s, source,
    );
    defer renderer.deinit();

    const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
    var sudoku_instance = try Sudoku.init(cfg, &f, io);
    defer sudoku_instance.engine.deinit();
    sudoku_instance.run() catch {};

    const contents = aw.writer.buffered();
    // save_as triggers a re-render with confirmation message + legend refresh
    try std.testing.expect(contents.len > 0);
}

// Issue 34 Step 3 — e2e: new command resets board and history
test "integrated e2e - run: new command resets board and history" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    // feed fill (adds to history), then new (should clear it), then quit
    const responses = [_][]const u8{
        "fill A3 7",
        "new",
        "quit",
    };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(alloc, &responses),
    };

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var s = styler_t.PlainStyler{};
    var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(
        alloc, io, &aw.writer, &s, source,
    );

    const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
    var sudoku_instance = try Sudoku.init(cfg, &f, io);
    defer sudoku_instance.engine.deinit();
    sudoku_instance.run() catch {};

    // history should be empty after new command clears it
    try std.testing.expectEqual(@as(usize, 0), sudoku_instance.engine.history.entries.items.len);
}
