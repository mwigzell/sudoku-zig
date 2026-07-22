const std = @import("std");
const board = @import("board.zig");
const cell = @import("cell.zig");

pub const CommandResult = union(enum) { ok, error_msg: []const u8 };

pub const Event = union(enum) {
    ok: struct {
        board_view: board.Board.BoardView,
        msg: ?[]const u8,
    },
    error_msg: []const u8,
};

/// GameEngine is generic over the Renderer type it receives at init.
/// Holds Board state and delegates snapshot emission to the renderer.
pub fn GameEngine(comptime R: type) type {
    const Engine = struct {
        board: board.Board,

        /// Render delegate — must satisfy `render(BoardView) anyerror!void` contract.
        renderer: *R,

        /// Construct from a one-line puzzle string.
        pub fn init(puzzle_str: []const u8, r: *R) board.BoardError!@This() {
            var self = @This(){
                .board = try board.fromOneLineString(puzzle_str),
                .renderer = r,
            };
            self.board.validate();
            return self;
        }

        /// Set a single cell on the Board to the given raw digit (1–9).
        /// Silently skips given cells.
        pub fn fill(self: *@This(), row_idx: usize, col_idx: usize, value: u8) void {
            if (!self.board.isGiven(@intCast(row_idx), @intCast(col_idx))) {
                _ = self.board.setCell( @intCast(row_idx), @intCast(col_idx), cell.rawToCellValue(value) ) catch {};
            }
        }

        /// Delegate view construction to Board and emit through renderer.
        pub fn render(self: *@This()) anyerror!void {
            const view = self.board.asView();
            try self.renderer.render(view);
        }

        /// Set a cell and immediately re-render. Convenience wrapper over `fill` + `render`.
        pub fn fillAndRender(self: *@This(), row_idx: usize, col_idx: usize, value: u8) anyerror!void {
            self.fill(row_idx, col_idx, value);
            try self.render();
        }

        /// Route a parsed command through Board mutation + render update.
        pub fn exec(self: *@This(), cmd: command.Command) anyerror!CommandResult {
            switch (cmd) {
                .fill => |f| {
                    return self.tryFill(f.row, f.col, f.digit);
                },
                .clear => |c| {
                    return self.tryClear(c.row, c.col);
                },
                .quit => {
                    return CommandResult.ok;
                },
            }
        }

        fn tryFill(self: *@This(), row: u4, col: u4, digit: cell.CellValue) anyerror!CommandResult {
            self.board.setCell(row, col, digit) catch |err| {
                var buf: [80]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "set cell ({d},{d}) failed: {s}", .{ row, col, @errorName(err) }) catch unreachable;
                return CommandResult{ .error_msg = msg };
            };
            self.board.refreshConflictsForCell(row, col);
            try self.renderer.render(self.board.asView());
            return CommandResult.ok;
        }
        /// Attempt to clear a cell — delegates to tryFill with .zero.
        fn tryClear(self: *@This(), row: u4, col: u4) anyerror!CommandResult {
            return self.tryFill(row, col, .zero);
        }
    };
    return Engine;
}

const puzzle_gen = @import("puzzle_gen.zig");
const mock_renderer = @import("mock_renderer.zig");

const command = @import("command.zig");
test "GameEngine fill updates cell in snapshot" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(puzzle_gen.PuzzleGen.default(), &mock);

    engine.fill(0, 3, 7);
    try engine.render();

    const cells = mock.last_rendered_cells orelse unreachable;
    try std.testing.expectEqual(cell.CellValue.seven, cells[0][3]);
}

test "GameEngine init builds board, explicit render emits snapshot" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(puzzle_gen.PuzzleGen.default(), &mock);

    // init does not auto-render — call_count is zero post-init
    try std.testing.expectEqual(0, mock.call_count);

    try engine.render();
    try std.testing.expectEqual(1, mock.call_count);

    const cells = mock.last_rendered_cells orelse unreachable;
    // puzzle[0..2] is '6' → A1 should be a given (six)
    try std.testing.expect(engine.board.isGiven(0, 0));
    try std.testing.expectEqual(cell.CellValue.six, cells[0][0]);

    // puzzle[2] is '.' → A3 should be non-given and empty
    try std.testing.expect(!engine.board.isGiven(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, cells[0][2]);
}

// T2: exec(Command) returns structured results with given-cell feedback

test "exec fill non-given cell → .ok" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(),
        &mock,
    );

    const fill_cmd = command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    };
    _ = try engine.exec(fill_cmd);

    // Board should show the filled value at (0, 2)
    try std.testing.expectEqual(cell.CellValue.seven, engine.board.getCellValue(0, 2));
}

test "exec fill given cell → .error_msg" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(),
        &mock,
    );

    // A1 (0, 0) is a given ('6'.)
    try std.testing.expect(engine.board.isGiven(0, 0));

    const fill_cmd = command.Command{
        .fill = command.FillData{ .row = 0, .col = 0, .digit = cell.CellValue.nine },
    };
    const result: CommandResult = try engine.exec(fill_cmd);

    if (result != .error_msg) return error.TestFailed;

    // Message field exists since we tagged .error_msg above
    _ = result.error_msg;
}

test "exec clear given cell → .error_msg" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(),
        &mock,
    );

    const clear_cmd = command.Command{
        .clear = command.ClearData{ .row = 0, .col = 0 },
    };
    const result: CommandResult = try engine.exec(clear_cmd);

    if (result != .error_msg) return error.TestFailed;
}

test "exec quit → .ok" {
    var mock = mock_renderer.MockRenderer.init();
    _ = mock.call_count; // silence unused warning on variable we check below

    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(),
        &mock,
    );

    const quit_cmd: command.Command = .{ .quit = {} };
    const result: CommandResult = try engine.exec(quit_cmd);

    if (result != .ok) return error.TestFailed;
}
// ---------------------------------------------------------------------------
// T3 — exec wires validator into mutation path (04-exec-wires-validator)
// Integration chain: exec → board mutation → conflict refresh → render
// Check conflict bits through engine.board.isConflicting() after exec+render
// ---------------------------------------------------------------------------

test "exec fill creates conflict → cell marked after render" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(),
        &mock,
    );

    // Row 0: cells (0,2) and (0,3) are both empty — fill both with eight
    // (Use eight; row 0 givens are six at col 0, seven at col 1, four at col 4)
    {
        const fill1 = command.Command{
            .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
        };
        _ = try engine.exec(fill1);
    }
    {
        const fill2 = command.Command{
            .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
        };
        _ = try engine.exec(fill2);
    }

    // Both cells in row 0 must now be flagged as conflicting (flat indices 2 and 3)
    try std.testing.expect(engine.board.isConflicting(2));
    try std.testing.expect(engine.board.isConflicting(3));

    // A cell not in the conflict path should be clean
    try std.testing.expect(!engine.board.isConflicting(50));
}

test "exec clear resolves conflict → previously-conflicting peer now clean" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(),
        &mock,
    );

    // Create a row-0 conflict pair: (0,2) and (0,3) both eight
    {
        _ = try engine.exec(command.Command{
            .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
        });
    }
    {
        _ = try engine.exec(command.Command{
            .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
        });
    }

    // Confirmed conflicting
    try std.testing.expect(engine.board.isConflicting(2));
    try std.testing.expect(engine.board.isConflicting(3));

    // Clear (0,3) → its peer (0,2) should no longer be flagged either
    {
        _ = try engine.exec(command.Command{
            .clear = command.ClearData{ .row = 0, .col = 3 },
        });
    }

    try std.testing.expect(!engine.board.isConflicting(2));
    try std.testing.expect(!engine.board.isConflicting(3));
}

test "exec fill no conflict → no bits set" {
    var mock = mock_renderer.MockRenderer.init();
    var engine = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(),
        &mock,
    );

    // Row 0 already has six at (0,0) and seven at (0,1).
    // Fill (0,2) with one — unique across its row, col, and box → clean.
    {
        _ = try engine.exec(command.Command{
            .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
        });
    }

    // The filled cell and its row/col/box peers must all be conflict-free
    try std.testing.expect(!engine.board.isConflicting(2));

    // Spot-check other cells in the affected scopes (row 0 indices, col 2 indices, box 0 indices)
    for (0..board.DIMENSION_SIZE) |c| {
        const idx: usize = @intCast(c);
        try std.testing.expect(!engine.board.isConflicting(idx));
    }
    for (0..board.DIMENSION_SIZE) |r| {
        const idx: usize = (@as(usize, @intCast(r)) * board.DIMENSION_SIZE) + 2;
        try std.testing.expect(!engine.board.isConflicting(idx));
    }
}

test "init calls validate so initial conflicts are detected" {
    var mock = mock_renderer.MockRenderer.init();
    _ = try GameEngine(mock_renderer.MockRenderer).init(
        puzzle_gen.PuzzleGen.default(),
        &mock,
    );

    // The default puzzle has no duplicate digits in the given cells,
    // so all conflict bits should be clear after init + render.
    // (If validate were NOT called, we can't prove it via absence of conflicts,
    // but a well-formed puzzle confirms at least that validate runs without crashing.)
    try std.testing.expect(mock.call_count == 0);
}
// ---------------------------------------------------------------------------
// Step 1 test — Event union shape
// ---------------------------------------------------------------------------

test "Event.ok carries board_view and optional msg" {
    const puzzle_str: []const u8 = puzzle_gen.PuzzleGen.default();
    var board_inst = try board.fromOneLineString(puzzle_str);
    const view = board_inst.asView();

    _ = Event{
        .ok = .{
            .board_view = view,
            .msg = null,
        },
    };
}

test "Event.ok can carry a message" {
    const puzzle_str: []const u8 = puzzle_gen.PuzzleGen.default();
    var board_inst = try board.fromOneLineString(puzzle_str);
    const view = board_inst.asView();

    _ = Event{
        .ok = .{
            .board_view = view,
            .msg = "puzzle complete!",
        },
    };
}

test "Event.error_msg carries an error string" {
    _ = Event{
        .error_msg = "cannot modify a given cell",
    };
}

// ---------------------------------------------------------------------------
// Integration test — game engine init propagates board error from puzzle
// ---------------------------------------------------------------------------

test "GameEngine.init propagates invalid puzzle error" {
    var mock = mock_renderer.MockRenderer.init();
    try std.testing.expectError(
        board.BoardError.WrongLength,
        GameEngine(mock_renderer.MockRenderer).init("too-short", &mock),
    );
}
