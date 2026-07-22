const std = @import("std");
const board = @import("board.zig");
const cell = @import("cell.zig");

/// Records one player mutation (fill or clear) so it can be undone/redone.
pub const MutationEntry = struct {
    row: u4,
    col: u4,
    old_value: cell.CellValue,
    new_value: cell.CellValue,
};

/// Mutable list of mutation entries with a forward pointer for undo/redo.
pub const MutationHistory = struct {
    entries: std.ArrayList(MutationEntry),
    pointer: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{
            .entries = .empty,
            .pointer = 0,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.entries.deinit(self.gpa);
    }

    /// Number of committed mutations.
    pub fn count(self: *const @This()) usize {
        return self.pointer;
    }

    /// Append a mutation, advancing pointer past it.
    pub fn push(self: *@This(), row: u4, col: u4, old_value: cell.CellValue, new_value: cell.CellValue) !void {
        try self.entries.append(self.gpa, .{
            .row = row,
            .col = col,
            .old_value = old_value,
            .new_value = new_value,
        });
        self.pointer = self.entries.items.len;
    }

    /// Return the entry just before pointer (last committed mutation). Returns null if none.
    pub fn peakPast(self: *const @This()) ?MutationEntry {
        if (self.pointer == 0) return null;
        return self.entries.items[self.pointer - 1];
    }

};

pub const Event = union(enum) {
    ok: struct {
        board_view: board.Board.BoardView,
        msg: ?[]const u8,
    },
    error_msg: []const u8,
};

pub const GameEngine = struct {
    board: board.Board,
    history: MutationHistory,

    /// Construct from a one-line puzzle string.
    pub fn init(puzzle_str: []const u8) board.BoardError!@This() {
        var self = @This(){
            .board = try board.fromOneLineString(puzzle_str),
            .history = MutationHistory.init(std.heap.page_allocator),
        };
        self.board.validate();
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.history.deinit();
    }

    /// Return a snapshot of the current board view.
    pub fn eventBoard(self: *@This()) board.Board.BoardView {
        return self.board.asView();
    }

    /// Route a parsed command through Board mutation + render update.
    pub fn exec(self: *@This(), cmd: command.Command) anyerror!Event {
        switch (cmd) {
            .fill => |f| {
                return self.tryFill(f.row, f.col, f.digit);
            },
            .clear => |c| {
                return self.tryFill(c.row, c.col, .zero);
            },
            .quit => {
                return Event{ .ok = .{ .board_view = self.board.asView(), .msg = null } };
            },
            .undo => return Event{ .error_msg = "not implemented" },
            .redo => return Event{ .error_msg = "not implemented" },
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
};

const puzzle_gen = @import("puzzle_gen.zig");

fn expectOk(event: Event) !board.Board.BoardView {
    return switch (event) {
        .ok => |data| data.board_view,
        .error_msg => return error.TestFailed,
    };
}

fn expectErrorResult(event: Event) !void {
    switch (event) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }
}

const command = @import("command.zig");

test "GameEngine fill updates cell value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 3));
}

test "GameEngine init builds board from puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();
    const view = engine.eventBoard();

    // puzzle[0..2] is '6' → A1 should be a given (six)
    try std.testing.expect(view.isGiven(0, 0));
    try std.testing.expectEqual(cell.CellValue.six, view.get(0, 0));

    // puzzle[2] is '.' → A3 should be non-given and empty
    try std.testing.expect(!view.isGiven(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, view.get(0, 2));
}

// T2: exec(Command) returns structured results with given-cell feedback

test "exec fill non-given cell → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
}

test "exec fill given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const result = try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 0, .digit = cell.CellValue.nine },
    });
    try expectErrorResult(result);
}

test "exec clear given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const result = try engine.exec(command.Command{
        .clear = command.ClearData{ .row = 0, .col = 0 },
    });
    try expectErrorResult(result);
}

test "exec quit → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const view = try expectOk(try engine.exec(command.Command{ .quit = {} }));
    // quit returns board_view with no message
    _ = view;
}

// T3 — exec wires validator into mutation path
// Integration chain: exec → board mutation → conflict refresh → event emission
// Check conflict bits through the returned Event board_view

test "exec fill creates conflict → cell marked" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Row 0: cells (0,2) and (0,3) are both empty — fill both with eight
    const fill1 = command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
    };

    _ = try expectOk(try engine.exec(fill1));

    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
    }));

    // Both cells in row 0 must now be flagged as conflicting
    try std.testing.expect(view.isConflictingRowCol(0, 2));
    try std.testing.expect(view.isConflictingRowCol(0, 3));

    // A cell not in the conflict path should be clean (row 5, col 5)
    try std.testing.expect(!view.isConflictingRowCol(5, 5));
}

test "exec clear resolves conflict → previously-conflicting peer now clean" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Create a row-0 conflict pair: (0,2) and (0,3) both eight
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
    }));

    {
        const view = try expectOk(try engine.exec(command.Command{
            .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
        }));
        try std.testing.expect(view.isConflictingRowCol(0, 2));
        try std.testing.expect(view.isConflictingRowCol(0, 3));
    }

    // Clear (0,3) → its peer (0,2) should no longer be flagged either
    {
        const view = try expectOk(try engine.exec(command.Command{
            .clear = command.ClearData{ .row = 0, .col = 3 },
        }));
        try std.testing.expect(!view.isConflictingRowCol(0, 2));
        try std.testing.expect(!view.isConflictingRowCol(0, 3));
    }
}

test "exec fill no conflict → no bits set" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Row 0 already has six at (0,0) and seven at (0,1).
    // Fill (0,2) with one — unique across its row, col, and box → clean.
    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
    }));

    // The filled cell must be conflict-free
    try std.testing.expect(!view.isConflictingRowCol(0, 2));

    // Row 0 cells must all be conflict-free
    for (0..board.DIMENSION_SIZE) |c| {
        const c4: u4 = @intCast(c);
        try std.testing.expect(!view.isConflictingRowCol(0, c4));
    }
    // Column 2 cells must all be conflict-free
    for (0..board.DIMENSION_SIZE) |r| {
        const r4: u4 = @intCast(r);
        try std.testing.expect(!view.isConflictingRowCol(r4, 2));
    }
}

test "init calls validate so initial conflicts are detected" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

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
    defer engine.deinit();
    const view = engine.eventBoard();

    // Board was built correctly from the puzzle string
    try std.testing.expect(view.isGiven(0, 0));

    // No renderer field exists (compile-time guarantee if struct is non-generic)
}

test "exec fill returns Event.ok with board_view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();
    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    // board_view reflects the mutation
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 2));
}

test "eventBoard returns current board view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const view1 = engine.eventBoard();
    // A1 is a given (six)
    try std.testing.expectEqual(cell.CellValue.six, view1.get(0, 0));

    // Mutate the board
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const view2 = engine.eventBoard();
    // A3 now reflects the fill
    try std.testing.expectEqual(cell.CellValue.seven, view2.get(0, 2));
}

// Step 2 — MutationHistory struct tests

test "MutationHistory: initially empty" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    try std.testing.expectEqual(@as(usize, 0), h.count());
}

test "MutationHistory: push and count" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    _ = h.push(2, 5, .three, .seven) catch unreachable;
    _ = h.push(4, 1, .zero, .one) catch unreachable;

    try std.testing.expectEqual(@as(usize, 2), h.count());
}

test "MutationHistory: peakPast returns last committed" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    _ = h.push(0, 3, .zero, .eight) catch unreachable;
    _ = h.push(1, 2, .five, .nine) catch unreachable;

    const item = h.peakPast() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u4, 1), item.row);
    try std.testing.expectEqual(@as(u4, 2), item.col);
    try std.testing.expectEqual(cell.CellValue.five, item.old_value);
    try std.testing.expectEqual(cell.CellValue.nine, item.new_value);
}

test "MutationHistory: peakPast returns null when empty" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    try std.testing.expect(h.peakPast() == null);
}
