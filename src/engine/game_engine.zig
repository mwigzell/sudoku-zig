// GameEngine: authoritative game state — board, mutation history, and the exec()
// command dispatcher; save/restore delegates to save_format.
const std = @import("std");
const board = @import("../board/board.zig");
const cell = @import("../board/cell.zig");
const _legend = @import("../renderer/legend.zig");
const Legend = _legend.Legend;
const command = @import("../command.zig");

// Moved to src/event.zig, re-exported for backward compat
const event = @import("../event.zig");
pub const Event = event.Event;

// Backward-compat re-exports (moved to engine/save_format.zig)
const save_format = @import("save_format.zig");
const state_mod = @import("state.zig");
const file_transport = @import("file_transport.zig");
pub const SaveFileMagic = save_format.SaveFileMagic;
pub const SaveFileVersion = save_format.SaveFileVersion;
pub const SaveFileHeader = save_format.SaveFileHeader;
pub const SaveFileTrailer = save_format.SaveFileTrailer;
pub const SaveEntry = save_format.SaveEntry;
const SAVE_HEADER_SIZE = save_format.SAVE_HEADER_SIZE;
const SAVE_TRAILER_SIZE = save_format.SAVE_TRAILER_SIZE;

// Moved to src/command/mutation_history.zig, re-exported for backward compat
const mutation_history = @import("mutation_history.zig");
const fill_command = @import("fill.zig");
const clear_command = @import("clear.zig");
const undo_command = @import("undo.zig");
const redo_command = @import("redo.zig");
const quit_command = @import("quit.zig");
const save_command = @import("save.zig");
const open_command = @import("open.zig");
const new_command = @import("new.zig");
const save_as_command = @import("save_as.zig");
const mypath = @import("path.zig");
pub const MutationEntry = mutation_history.MutationEntry;
pub const MutationHistory = mutation_history.MutationHistory;
pub const Error = error{System};

/// Owns the portable game state, a byte-transport seam for save/open, and
/// save-dialog state (data dir, feedback text). No I/O handle lives here.
pub const GameEngine = struct {
    state: state_mod.State,
    transport: file_transport.FileTransport,
    data_dir: ?[]u8,
    last_save_msg: ?[]u8,
    /// Build an engine from a one-line puzzle string; the transport is retained for save/open.
    pub fn init(puzzle_str: []const u8, transport: file_transport.FileTransport) Error!@This() {
        const brd = board.fromOneLineString(puzzle_str) catch return Error.System;
        var self = @This(){
            .state = .{
                .board = brd,
                .history = MutationHistory.init(std.heap.page_allocator),
            },
            .transport = transport,
            .data_dir = null,
            .last_save_msg = null,
        };
        self.state.board.validate();
        return self;
    }

    /// Free the history and any owned string fields.
    pub fn deinit(self: *@This()) void {
        self.state.history.deinit();

        // Free optional string fields
        if (self.data_dir) |dir| std.heap.page_allocator.free(dir);
        if (self.last_save_msg) |msg| std.heap.page_allocator.free(msg);
    }

    /// Return a snapshot of the current board view.
    pub fn eventBoard(self: *@This()) board.Board.BoardView {
        return self.state.board.asView();
    }

    /// Which commands are available in the current game state.
    pub fn getLegend(self: *const @This()) Legend {
        return Legend{
            .fill = true,
            .clear = true,
            .quit = true,
            .undo = self.state.history.pointer > 0,
            .redo = self.state.history.pointer < self.state.history.entries.items.len,
            .save = true,
            .open = true,
            .new = true,
            .save_as = true,
        };
    }

    /// Serialize the game state to a save file; bytes move through the transport.
    pub fn saveGame(self: *const @This(), path: []const u8) file_transport.TransportError!void {
        const gpa = std.heap.page_allocator;
        const buf = save_format.toSaveFormat(&self.state, gpa) catch return file_transport.TransportError.OutOfMemory;
        defer gpa.free(buf);
        return self.transport.write(self.transport.context, path, buf);
    }

    /// Serialize full game state to a heap-allocated byte buffer.
    /// Returns allocated []u8 — caller owns and must free with the same allocator.
    pub fn toSaveFormat(self: *const @This(), gpa: std.mem.Allocator) []u8 {
        return save_format.toSaveFormat(&self.state, gpa);
    }

    /// Load a save file through the transport; replaces this engine's state.
    pub fn openGame(self: *@This(), path: []const u8) file_transport.TransportError!void {
        const gpa = std.heap.page_allocator;
        const buf = self.transport.readAll(self.transport.context, path) catch return file_transport.TransportError.System;
        defer self.transport.free(self.transport.context, buf);
        const loaded = save_format.fromSaveFormat(gpa, buf) catch return file_transport.TransportError.System;
        self.state.history.deinit();
        self.state.board = loaded.board;
        self.state.history = loaded.history;
        self.data_dir = null;
        self.last_save_msg = null;
    }

    /// Route a parsed command through Board mutation + render update.
    pub fn exec(self: *@This(), cmd: command.Command) Event {
        switch (cmd) {
            .fill => |f| {
                return fill_command.execute(self, f);
            },
            .clear => |c| {
                return clear_command.execute(self, c);
            },
            .quit => {
                return quit_command.execute(self);
            },
            .undo => {
                return undo_command.execute(self);
            },
            .redo => {
                return redo_command.execute(self);
            },
            .save => |data| {
                const path = data.path orelse save_command.DEFAULT_SAVE_FILE;
                return save_command.execute(self, path);
            },
            .open => |data| {
                return open_command.execute(self, data.path);
            },
            .new => |data| {
                return new_command.execute(self, data);
            },
            .save_as => |data| {
                const path = data.path orelse save_command.DEFAULT_SAVE_FILE;
                return save_as_command.execute(self, path);
            },
        }
    }

    /// Attempt to fill a cell with a digit. Records mutation in history.
    pub fn tryFill(self: *@This(), row: u4, col: u4, digit: cell.CellValue) Event {
        // Snapshot old value before mutation (only recorded on success)
        const old_value = self.state.board.asView().get(row, col);
        self.state.board.setCell(row, col, digit) catch |err| {
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "set cell ({d},{d}) failed: {s}", .{ row, col, @errorName(err) }) catch "cell set error";
            return Event{ .error_msg = msg };
        };
        // Persist the successful mutation in history
        // First discard stale future entries from any earlier undo branch
        self.state.history.truncateFuture();
        self.state.history.push(row, col, old_value, digit) catch |err| {
            var buf: [80]u8 = undefined;
            return Event{ .error_msg = std.fmt.bufPrint(&buf, "history push failed: {s}", .{@errorName(err)}) catch "history error" };
        };
        self.state.board.refreshConflictsForCell(row, col);
        return Event{ .ok = .{ .board_view = self.state.board.asView(), .msg = null, .is_quit = false } };
    }
};

// ────────────────────── co-located tests ──────────────────────
const puzzle_gen = @import("../puzzle_gen.zig");

fn expectOk(e: Event) !board.Board.BoardView {
    return switch (e) {
        .ok => |data| data.board_view,
        .error_msg => return error.TestFailed,
    };
}

fn expectErrorResult(e: Event) !void {
    switch (e) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }
}

test "GameEngine fill updates cell value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    const view = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 3));
}

test "GameEngine init builds board from puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();
    const view = engine.eventBoard();

    // puzzle[0..2] is '6' → A1 should be a given (six)
    try std.testing.expect(view.isGiven(0, 0));
    try std.testing.expectEqual(cell.CellValue.six, view.get(0, 0));

    // puzzle[2] is '.' → A3 should be non-given and empty
    try std.testing.expect(!view.isGiven(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, view.get(0, 2));
}

// Slice 3 shape: nested State on the engine; bytes move through FileTransport; no io field.
test "slice 3: GameEngine holds State + FileTransport; save/open io-free" {
    var engine = try GameEngine.init(
        puzzle_gen.PuzzleGen.default(),
        file_transport.NativeTransport.make(std.testing.io),
    );
    defer engine.deinit();

    // Shape assertion: the engine carries a nested State (compile-time).
    const st: *state_mod.State = &engine.state;
    _ = st;

    // Make a mutation so the saved state differs from the default puzzle.
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const tmp_path = "/tmp/sudoku_slice3_transport_roundtrip.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    // save/open take no io — every byte goes through the transport.
    try engine.saveGame(tmp_path);

    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer loaded.deinit();
    try loaded.openGame(tmp_path);

    try std.testing.expect(engine.state.board.equal(loaded.state.board));
    try std.testing.expectEqual(engine.state.history.count(), loaded.state.history.count());
    try std.testing.expectEqual(cell.CellValue.seven, loaded.state.board.getCellValue(@as(u4, 0), @as(u4, 2)));
}

// exec(Command) returns structured results with given-cell feedback

test "exec fill non-given cell → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
}

test "exec fill given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    const result = engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 0, .digit = cell.CellValue.nine },
    });
    try expectErrorResult(result);
}

test "exec clear given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    const result = engine.exec(command.Command{
        .clear = command.ClearData{ .row = 0, .col = 0 },
    });
    try expectErrorResult(result);
}

test "exec quit → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    const view = try expectOk(engine.exec(command.Command{ .quit = {} }));
    // quit returns board_view with no message
    _ = view;
}

// exec wires validator into mutation path
// Integration chain: exec → board mutation → conflict refresh → event emission
// Check conflict bits through the returned Event board_view

test "exec fill creates conflict → cell marked" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Row 0: cells (0,2) and (0,3) are both empty — fill both with eight
    const fill1 = command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
    };

    _ = try expectOk(engine.exec(fill1));

    const view = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
    }));

    // Both cells in row 0 must now be flagged as conflicting
    try std.testing.expect(view.isConflictingRowCol(0, 2));
    try std.testing.expect(view.isConflictingRowCol(0, 3));

    // A cell not in the conflict path should be clean (row 5, col 5)
    try std.testing.expect(!view.isConflictingRowCol(5, 5));
}

test "exec clear resolves conflict → previously-conflicting peer now clean" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Create a row-0 conflict pair: (0,2) and (0,3) both eight
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
    }));

    {
        const view = try expectOk(engine.exec(command.Command{
            .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
        }));
        try std.testing.expect(view.isConflictingRowCol(0, 2));
        try std.testing.expect(view.isConflictingRowCol(0, 3));
    }

    // Clear (0,3) → its peer (0,2) should no longer be flagged either
    {
        const view = try expectOk(engine.exec(command.Command{
            .clear = command.ClearData{ .row = 0, .col = 3 },
        }));
        try std.testing.expect(!view.isConflictingRowCol(0, 2));
        try std.testing.expect(!view.isConflictingRowCol(0, 3));
    }
}

test "exec fill no conflict → no bits set" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Row 0 already has six at (0,0) and seven at (0,1).
    // Fill (0,2) with one — unique across its row, col, and box → clean.
    const view = try expectOk(engine.exec(command.Command{
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
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
            .is_quit = false,
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
            .is_quit = false,
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
        Error.System, // board errors are caught and converted to System
        GameEngine.init("too-short", file_transport.NativeTransport.make(std.testing.io)),
    );
}

test "GameEngine is non-generic, init takes only puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();
    const view = engine.eventBoard();

    // Board was built correctly from the puzzle string
    try std.testing.expect(view.isGiven(0, 0));

    // No renderer field exists (compile-time guarantee if struct is non-generic)
}

test "exec fill returns Event.ok with board_view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();
    const view = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    // board_view reflects the mutation
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 2));
}

test "eventBoard returns current board view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    const view1 = engine.eventBoard();
    // A1 is a given (six)
    try std.testing.expectEqual(cell.CellValue.six, view1.get(0, 0));

    // Mutate the board
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const view2 = engine.eventBoard();
    // A3 now reflects the fill
    try std.testing.expectEqual(cell.CellValue.seven, view2.get(0, 2));
}

// MutationHistory struct tests

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

test "exec undo on empty history returns .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    const result = switch (engine.exec(command.Command{ .undo = {} })) {
        .ok => return error.TestFailed,
        .error_msg => |msg| msg,
    };
    try std.testing.expectEqualStrings(result, "nothing to undo");
}

test "exec then undo reverses a fill back to zero" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Fill A3 (row 0, col 2) with seven
    const fill_view = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, fill_view.get(0, 2));

    // Undo — should revert to zero
    const undo_view = try expectOk(engine.exec(command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.zero, undo_view.get(0, 2));
}

test "exec then undo then redo re-applies the fill" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Fill A3 with seven
    const fill_view = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, fill_view.get(0, 2));

    // Undo — should revert to zero
    const undo_view = try expectOk(engine.exec(command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.zero, undo_view.get(0, 2));

    // Redo — should re-apply seven
    const redo_view = try expectOk(engine.exec(command.Command{ .redo = {} }));
    try std.testing.expectEqual(cell.CellValue.seven, redo_view.get(0, 2));
}

test "new mutation after undo truncates future redo path" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Fill 3 cells A, B, C all on different empty cells
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    // Undo twice — back to after A only (pointer=1)
    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));
    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));

    // Now B and C cells should be empty again
    const view_after_undo = engine.eventBoard();
    try std.testing.expectEqual(cell.CellValue.zero, view_after_undo.get(1, 2));
    try std.testing.expectEqual(cell.CellValue.zero, view_after_undo.get(1, 3));

    // Make new fill D on B's cell — should truncate [B,C] from future
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.four },
    }));

    // Redo should fail (no future to redo — path was truncated)
    const redo_result = engine.exec(command.Command{ .redo = {} });
    try expectErrorResult(redo_result);
}

test "undo clear restores previous value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Fill B1 (row 1, col 1) with three
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    }));

    // Clear B1
    const clear_view = try expectOk(engine.exec(command.Command{
        .clear = command.ClearData{ .row = 1, .col = 1 },
    }));
    try std.testing.expectEqual(cell.CellValue.zero, clear_view.get(1, 1));

    // Undo the clear — should restore three
    const undo_view = try expectOk(engine.exec(command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.three, undo_view.get(1, 1));
}

// Multi-step undo/redo integration

test "multiple undo walks history backwards" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Fill three cells: A=one at (1,1), B=two at (1,2), C=three at (1,3)
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    // All three filled
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.three, v.get(1, 3));
    }

    // Undo #1 reverts C → (1,3) empty again
    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Undo #2 reverts B → (1,2) empty again
    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }
}

test "multiple redo walks forwards correctly" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Fill three cells: A=one at (1,1), B=two at (1,2), C=three at (1,3)
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    // Undo all three
    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));
    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));
    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #1 re-applies A → (1,1) = one
    _ = try expectOk(engine.exec(command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #2 re-applies B → (1,2) = two
    _ = try expectOk(engine.exec(command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #3 re-applies C → (1,3) = three
    _ = try expectOk(engine.exec(command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.three, v.get(1, 3));
    }
}

test "redo on empty future returns .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Fill some cells — no undo yet, so nothing to redo
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    // Redo with nothing undone should fail
    const result = engine.exec(command.Command{ .redo = {} });
    try expectErrorResult(result);
}

test "getLegend: fresh engine has Fill/Clear/Quit only" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(!cmds.redo);
}

test "getLegend: after fill Undo appears" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(cmds.undo);
    try std.testing.expect(!cmds.redo);
}

test "getLegend: after undo-one-of-one Redo appears Undo disappears" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(cmds.redo);
}

test "getLegend: after partial undo both Undo and Redo available" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(cmds.undo);
    try std.testing.expect(cmds.redo);
}

test "getLegend: after full undo Undo hidden Redo replays" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));
    _ = try expectOk(engine.exec(command.Command{ .undo = {} }));

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(cmds.redo);
}
test "getLegend: Save and Open always available" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    const cmds = engine.getLegend();
    // Save and Open are always available like Fill/Clear/Quit (not state-contingent)
    try std.testing.expect(cmds.save);
    try std.testing.expect(cmds.open);
}

test "Save fields moved to GameEngine struct" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Fields exist on GameEngine (compile-time proof) and start null
    try std.testing.expectEqual(@as(?[]u8, null), engine.data_dir);
}

test "exec save: delegates to save handler via command/save.zig" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer engine.deinit();

    // Give a known data dir so save handler has path
    const gpa = std.heap.page_allocator;
    engine.data_dir = try mypath.computeDataDir(gpa);
    errdefer gpa.free(engine.data_dir.?);

    // Make a mutation to save meaningful state
    _ = try expectOk(engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    // exec() must NOT panic on .save — it should delegate to command handler
    const result = engine.exec(command.Command{ .save = command.SaveData{ .path = "sudoku_save.sud" } });

    // Should return ok with message and is_quit = false
    switch (result) {
        .ok => |data| {
            try std.testing.expect(!data.is_quit);
            try std.testing.expect(data.msg != null);
        },
        .error_msg => return error.TestFailed,
    }
}

test "exec open: delegates to open handler via command/open.zig" {
    const tmp_path = "/tmp/sudoku_open_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    // Create a known save file
    var original = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer original.deinit();
    _ = try expectOk(original.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    try original.saveGame(tmp_path);

    // Now create a second engine and open through exec()
    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.default(), file_transport.NativeTransport.make(std.testing.io));
    defer loaded.deinit();
    _ = try expectOk(loaded.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
    }));

    // exec open through .open command — must delegate to handler, not panic
    const result = loaded.exec(command.Command{ .open = command.OpenData{ .path = tmp_path } });

    switch (result) {
        .ok => |data| {
            try std.testing.expect(!data.is_quit);
            // Board cell (0,2) should be seven from saved state, not one (overwritten by open)
            try std.testing.expectEqual(cell.CellValue.seven, data.board_view.get(0, 2));
        },
        .error_msg => return error.TestFailed,
    }
}
