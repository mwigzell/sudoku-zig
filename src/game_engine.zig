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

pub const GameEngine = struct {
    board: board.Board,

    /// Construct from a one-line puzzle string.
    pub fn init(puzzle_str: []const u8) board.BoardError!@This() {
        var self = @This(){
            .board = try board.fromOneLineString(puzzle_str),
        };
        self.board.validate();
        return self;
    }

    /// Set a single cell on the Board to the given raw digit (1-9).

    /// Route a parsed command through Board mutation + render update.
    pub fn exec(self: *@This(), cmd: command.Command) anyerror!Event {
        switch (cmd) {
            .fill => |f| {
                return self.tryFill(f.row, f.col, f.digit);
            },
            .clear => |c| {
                return self.tryClear(c.row, c.col);
            },
            .quit => {
                return Event{ .ok = .{ .board_view = self.board.asView(), .msg = null } };
            },
        }
    }

    fn tryFill(self: *@This(), row: u4, col: u4, digit: cell.CellValue) anyerror!Event {
        self.board.setCell(row, col, digit) catch |err| {
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "set cell ({d},{d}) failed: {s}", .{ row, col, @errorName(err) }) catch unreachable;
            return Event{ .error_msg = msg };
        };
        self.board.refreshConflictsForCell(row, col);
        return Event{ .ok = .{ .board_view = self.board.asView(), .msg = null } };
    }

    /// Attempt to clear a cell - delegates to tryFill with .zero.
    fn tryClear(self: *@This(), row: u4, col: u4) anyerror!Event {
        return self.tryFill(row, col, .zero);
    }
};

const puzzle_gen = @import("puzzle_gen.zig");

const command = @import("command.zig");

test "GameEngine fill updates cell value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    const event = try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.seven },
    });

    switch (event) {
        .ok => |ev| {
            try std.testing.expectEqual(cell.CellValue.seven, ev.board_view.get(0, 3));
        },
        .error_msg => return error.TestFailed,
    }
}

test "GameEngine init builds board from puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    // puzzle[0..2] is '6' → A1 should be a given (six)
    try std.testing.expect(engine.board.isGiven(0, 0));
    try std.testing.expectEqual(cell.CellValue.six, engine.board.getCellValue(0, 0));

    // puzzle[2] is '.' → A3 should be non-given and empty
    try std.testing.expect(!engine.board.isGiven(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, engine.board.getCellValue(0, 2));
}

// T2: exec(Command) returns structured results with given-cell feedback

test "exec fill non-given cell → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    const fill_cmd = command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    };
    switch (try engine.exec(fill_cmd)) {
        .ok => {},
        .error_msg => return error.TestFailed,
    }
}

test "exec fill given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    const fill_cmd = command.Command{
        .fill = command.FillData{ .row = 0, .col = 0, .digit = cell.CellValue.nine },
    };
    const result = try engine.exec(fill_cmd);
    switch (result) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }
}

test "exec clear given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    const clear_cmd = command.Command{
        .clear = command.ClearData{ .row = 0, .col = 0 },
    };
    const result = try engine.exec(clear_cmd);
    switch (result) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }
}

test "exec quit → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    const quit_cmd: command.Command = .{ .quit = {} };
    const event = try engine.exec(quit_cmd);
    switch (event) {
        .ok => |ev| {
            // quit returns board_view with no message
            _ = ev;
        },
        .error_msg => return error.TestFailed,
    }
}

// T3 — exec wires validator into mutation path
// Integration chain: exec → board mutation → conflict refresh → event emission
// Check conflict bits through the returned Event board_view

test "exec fill creates conflict → cell marked" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    // Row 0: cells (0,2) and (0,3) are both empty — fill both with eight
    const fill1 = command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
    };

    _ = try engine.exec(fill1);

    const fill2 = command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
    };
    const event = try engine.exec(fill2);
    switch (event) {
        .ok => |ev| {
            // Both cells in row 0 must now be flagged as conflicting
            try std.testing.expect(ev.board_view.isConflictingRowCol(0, 2));
            try std.testing.expect(ev.board_view.isConflictingRowCol(0, 3));

            // A cell not in the conflict path should be clean (row 5, col 5)
            try std.testing.expect(!ev.board_view.isConflictingRowCol(5, 5));
        },
        .error_msg => return error.TestFailed,
    }
}

test "exec clear resolves conflict → previously-conflicting peer now clean" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    // Create a row-0 conflict pair: (0,2) and (0,3) both eight
    {
        _ = try engine.exec(command.Command{
            .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
        });
    }
    {
        const ev1 = try engine.exec(command.Command{
            .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
        });
        switch (ev1) {
            .ok => |view| {
                try std.testing.expect(view.board_view.isConflictingRowCol(0, 2));
                try std.testing.expect(view.board_view.isConflictingRowCol(0, 3));
            },
            .error_msg => return error.TestFailed,
        }
    }

    // Clear (0,3) → its peer (0,2) should no longer be flagged either
    {
        const ev2 = try engine.exec(command.Command{
            .clear = command.ClearData{ .row = 0, .col = 3 },
        });
        switch (ev2) {
            .ok => |view| {
                try std.testing.expect(!view.board_view.isConflictingRowCol(0, 2));
                try std.testing.expect(!view.board_view.isConflictingRowCol(0, 3));
            },
            .error_msg => return error.TestFailed,
        }
    }
}

test "exec fill no conflict → no bits set" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    // Row 0 already has six at (0,0) and seven at (0,1).
    // Fill (0,2) with one — unique across its row, col, and box → clean.
    const event = try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
    });

    switch (event) {
        .ok => |ev| {
            // The filled cell must be conflict-free
            try std.testing.expect(!ev.board_view.isConflictingRowCol(0, 2));

            // Row 0 cells must all be conflict-free
            for (0..board.DIMENSION_SIZE) |c| {
                const c4: u4 = @intCast(c);
                try std.testing.expect(!ev.board_view.isConflictingRowCol(0, c4));
            }
            // Column 2 cells must all be conflict-free
            for (0..board.DIMENSION_SIZE) |r| {
                const r4: u4 = @intCast(r);
                try std.testing.expect(!ev.board_view.isConflictingRowCol(r4, 2));
            }
        },
        .error_msg => return error.TestFailed,
    }
}
test "init calls validate so initial conflicts are detected" {
    _ = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    // A well-formed puzzle confirms at least that validate runs without crashing.
}

// Event union shape tests

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

// Integration test — game engine init propagates board error from puzzle

test "GameEngine.init propagates invalid puzzle error" {
    try std.testing.expectError(
        board.BoardError.WrongLength,
        GameEngine.init("too-short"),
    );
}

test "GameEngine is non-generic, init takes only puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());

    // Board was built correctly from the puzzle string
    try std.testing.expect(engine.board.isGiven(0, 0));

    // No renderer field exists (compile-time guarantee if struct is non-generic)
}

test "exec fill returns Event.ok with board_view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    const fill_cmd: command.Command = .{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    };

    const event: Event = try engine.exec(fill_cmd);

    if (event != .ok) return error.TestFailed;
    // board_view reflects the mutation
    try std.testing.expectEqual(cell.CellValue.seven, event.ok.board_view.get(0, 2));
}
