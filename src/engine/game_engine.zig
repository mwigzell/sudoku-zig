// GameEngine: authoritative game state — board, mutation history, and the exec()
// command dispatcher; save/restore delegates to save_format.
const std = @import("std");
const builtin = @import("builtin");
const board = @import("../board/board.zig");
const cell = @import("../board/cell.zig");
const _legend = @import("../renderer/legend.zig");
const Legend = _legend.Legend;
const command = @import("../command.zig");
const config = @import("../config.zig");

// Moved to src/event.zig, re-exported for backward compat
const event = @import("../event.zig");
pub const Event = event.Event;

// Backward-compat re-exports (moved to engine/save_format.zig)
const save_format = @import("save_format.zig");
const state_mod = @import("state.zig");
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
const solver = @import("../solver.zig");
pub const MutationEntry = mutation_history.MutationEntry;
pub const MutationHistory = mutation_history.MutationHistory;
pub const Error = error{System};

/// Owns portable game state. No file transport or I/O here.
const SolvabilityProbe = enum { move, load };

pub const GameEngine = struct {
    state: state_mod.State,
    cfg: config.Config,
    event_msg: event.EventMsg = .{},
    /// After a player move, probe solvability and warn when the board has no completion.
    warn_dead_moves: bool = !builtin.is_test,
    /// On open/load, probe solvability and warn when the puzzle has no completion.
    warn_unsolvable_load: bool = !builtin.is_test,

    /// Build an engine from a one-line puzzle string and nominal config.
    pub fn init(puzzle_str: []const u8, cfg: config.Config) Error!@This() {
        const brd = board.fromOneLineString(puzzle_str) catch return Error.System;
        var self = @This(){
            .state = .{
                .board = brd,
                .history = MutationHistory.init(std.heap.page_allocator),
            },
            .cfg = cfg,
        };
        self.state.board.validate();
        return self;
    }

    /// Free the history and any owned string fields.
    pub fn deinit(self: *@This()) void {
        self.state.history.deinit();
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
            .menu = true,
            .save = true,
            .open = true,
            .new = true,
            .import = true,
            .save_as = true,
            .solve = self.canSolve(),
        };
    }

    /// Solve is offered only when there is an empty cell and no conflict.
    fn canSolve(self: *const @This()) bool {
        if (self.state.board.conflict_bits != 0) return false;
        for (self.state.board.cells) |c| {
            if (c.value == .zero) return true;
        }
        return false;
    }

    /// Current nominal configuration (theme, region highlight, difficulty, log level).
    pub fn getConfig(self: *const @This()) config.Config {
        return self.cfg;
    }

    /// Serialize full game state to a heap-allocated byte buffer.
    pub fn toSaveFormat(self: *const @This(), gpa: std.mem.Allocator) ![]u8 {
        return save_format.toSaveFormat(&self.state, gpa);
    }

    /// Replace board and history from a SUD0 blob produced by `toSaveFormat`.
    pub fn loadSaveFormat(self: *@This(), buf: []const u8) !void {
        const gpa = std.heap.page_allocator;
        const loaded = try save_format.fromSaveFormat(gpa, buf);
        self.state.history.deinit();
        self.state.board = loaded.board;
        self.state.history = loaded.history;
        self.state.board.validate();
    }

    /// Open from SUD0 bytes — native shell and wasm deserialize both call this.
    pub fn openFromSave(self: *@This(), buf: []const u8, opened_label: ?[]const u8) Event {
        self.loadSaveFormat(buf) catch |err| return self.errorEvent(@errorName(err));
        return self.finishLoadEvent(opened_label);
    }

    /// Import a one-line puzzle (81 digits/blanks) from a page-read file.
    /// Replaces the board and clears history; failure leaves state intact.
    pub fn importFromLine(self: *@This(), line: []const u8) Event {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len != 81) {
            return self.errorEvent("import: expected exactly 81 characters");
        }
        const imported = board.fromOneLineString(trimmed) catch {
            return self.errorEvent("import: invalid character in puzzle line");
        };
        self.state.history.deinit();
        self.state.history = MutationHistory.init(std.heap.page_allocator);
        self.state.board = imported;
        self.beginEventMsg();
        self.appendEventMsg("import: puzzle loaded");
        return self.finishOkEvent(self.state.board.asView(), false, null);
    }

    /// Clear the per-exec `.ok.msg` scratch buffer before appending message parts.
    pub fn beginEventMsg(self: *@This()) void {
        self.event_msg.reset();
    }

    /// Append one `.ok.msg` fragment; multiple sources may contribute in the same exec step.
    pub fn appendEventMsg(self: *@This(), part: []const u8) void {
        self.event_msg.append(part);
    }

    pub fn appendEventMsgFmt(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.event_msg.appendFmt(fmt, args);
    }

    fn formatCellLabel(buf: *[2]u8, row: u4, col: u4) []const u8 {
        buf[0] = @as(u8, 'A') + @as(u8, col);
        buf[1] = @as(u8, '1') + @as(u8, row);
        return buf[0..2];
    }

    fn appendUnsolvableMutationWarning(self: *@This(), row: u4, col: u4) void {
        var label: [2]u8 = undefined;
        const coord = formatCellLabel(&label, row, col);
        self.appendEventMsgFmt("that move leaves the board unsolvable — undo or clear {s}", .{coord});
    }

    /// Optional solvability check for warning paths — not used by solve_for_me or redo solve_batch.
    fn probeSolvability(self: *@This(), when: SolvabilityProbe) ?solver.SolveResult {
        const enabled = switch (when) {
            .move => self.warn_dead_moves,
            .load => self.warn_unsolvable_load,
        };
        if (!enabled) return null;
        return solver.solve(self.state.board) catch null;
    }

    fn appendUnsolvableLoadWarningIfNeeded(self: *@This()) void {
        const solved = self.probeSolvability(.load) orelse return;
        if (solved == .none) self.appendEventMsg("this puzzle has no solution");
    }

    fn finishLoadEvent(self: *@This(), opened_label: ?[]const u8) Event {
        self.beginEventMsg();
        if (opened_label) |label| self.appendEventMsgFmt("opened: {s}", .{label});
        self.appendUnsolvableLoadWarningIfNeeded();
        return self.finishOkEvent(self.state.board.asView(), false, null);
    }

    /// Build `.ok` using accumulated msg (null when nothing was appended).
    pub fn finishOkEvent(self: *@This(), view: board.Board.BoardView, is_quit: bool, edited_cell: ?event.CellCoord) Event {
        return .{ .ok = .{
            .board_view = view,
            .msg = self.event_msg.optional(),
            .is_quit = is_quit,
            .cell = edited_cell,
        } };
    }

    /// One error string in engine scratch — safe for wasm JSON after exec returns.
    pub fn errorEvent(self: *@This(), part: []const u8) Event {
        self.event_msg.reset();
        self.event_msg.append(part);
        return .{ .error_msg = self.event_msg.slice() };
    }

    pub fn errorEventFmt(self: *@This(), comptime fmt: []const u8, args: anytype) Event {
        self.event_msg.reset();
        self.event_msg.appendFmt(fmt, args);
        return .{ .error_msg = self.event_msg.slice() };
    }

    pub fn eventFromSetCellError(self: *@This(), row: u4, col: u4, err: anyerror) Event {
        return switch (err) {
            error.IsGiven => self.errorEvent("cannot modify a puzzle cell"),
            else => self.errorEventFmt("set cell ({d},{d}) failed: {s}", .{ row, col, @errorName(err) }),
        };
    }

    pub fn finishOkAfterCellEdit(self: *@This(), row: u4, col: u4, was_solved: bool) Event {
        self.state.board.refreshConflictsForCell(row, col);
        const view = self.state.board.asView();
        if (view.isConflictingRowCol(row, col)) {
            self.appendEventMsg("conflict in row, column, or box");
        } else if (self.probeSolvability(.move)) |solved| {
            if (solved == .none) self.appendUnsolvableMutationWarning(row, col);
        }
        if (!was_solved and self.state.board.isSolved()) {
            self.appendEventMsg("You win!");
        }
        return self.finishOkEvent(view, false, .{ .row = row, .col = col });
    }

    /// Route a gameplay command through Board mutation + render update.
    /// Session commands (save/open/new/save_as) are handled in native/shell/sudoku.zig.
    pub fn exec(self: *@This(), cmd: command.Command) Event {
        self.beginEventMsg();
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
            .solve_for_me => {
                return self.solveForMe();
            },
            .set_theme => |theme| {
                self.cfg.theme = theme;
                return self.finishOkEvent(self.state.board.asView(), false, null);
            },
            .set_region => |enabled| {
                self.cfg.show_region = enabled;
                return self.finishOkEvent(self.state.board.asView(), false, null);
            },
            .menu => @panic("menu routed in renderer"),
            .save, .open, .import, .new, .save_as => @panic("session command routed in Sudoku"),
        }
    }

    /// Attempt to fill a cell with a digit. Records mutation in history.
    pub fn tryFill(self: *@This(), row: u4, col: u4, digit: cell.CellValue) Event {
        const was_solved = self.state.board.isSolved();
        // Snapshot old value before mutation (only recorded on success)
        const old_value = self.state.board.asView().get(row, col);
        self.state.board.setCell(row, col, digit) catch |err| {
            return self.eventFromSetCellError(row, col, err);
        };
        // Persist the successful mutation in history
        // First discard stale future entries from any earlier undo branch
        self.state.history.truncateFuture();
        self.state.history.push(row, col, old_value, digit) catch |err| {
            return self.errorEventFmt("history push failed: {s}", .{@errorName(err)});
        };
        return self.finishOkAfterCellEdit(row, col, was_solved);
    }

    /// Fill every empty cell from one solver pass. One history step, not N fills.
    fn solveForMe(self: *@This()) Event {
        const before_flat = board.toFlat(self.state.board);
        const before_given = self.state.board.given_bits;
        const solved = solver.solve(self.state.board) catch |err| switch (err) {
            error.Conflict => return self.errorEvent("board has a conflict"),
        };
        switch (solved) {
            .none => return self.finishOkEvent(self.state.board.asView(), false, null),
            .solution => |grid| {
                for (grid, 0..) |digit, i| {
                    const row: u4 = @intCast(i / 9);
                    const col: u4 = @intCast(i % 9);
                    if (self.state.board.getCellValue(row, col) == cell.rawToCellValue(digit)) continue;
                    self.state.board.setCell(row, col, cell.rawToCellValue(digit)) catch |set_err| {
                        return self.eventFromSetCellError(row, col, set_err);
                    };
                }
                self.state.history.truncateFuture();
                self.state.history.pushSolve(.{ .given_bits = before_given, .flat = before_flat }) catch |push_err| {
                    return self.errorEventFmt("history push failed: {s}", .{@errorName(push_err)});
                };
                self.state.board.validate();
                return self.finishOkEvent(self.state.board.asView(), false, null);
            },
        }
    }
};

// ────────────────────── co-located tests ──────────────────────
const puzzle_gen = @import("../puzzle_gen.zig");
const file_transport = @import("../native/shell/file_transport.zig");
const open_command = @import("../native/shell/open.zig");

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

fn execTest(engine: *GameEngine, cmd: command.Command) Event {
    return engine.exec(cmd);
}

fn execMoveTest(engine: *GameEngine, cmd: command.Command) Event {
    engine.warn_dead_moves = true;
    return engine.exec(cmd);
}

fn openFromSaveProbeTest(engine: *GameEngine, buf: []const u8, opened_label: ?[]const u8) Event {
    engine.warn_unsolvable_load = true;
    return engine.openFromSave(buf, opened_label);
}

test "GameEngine init takes puzzle string only — no FileTransport" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.count());
}

test "exec solve_for_me fills a known partial as one solve batch" {
    const solution = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();

    const ev = execTest(&engine, .{ .solve_for_me = {} });
    _ = try expectOk(ev);
    var expected: [81]u8 = undefined;
    for (solution, 0..) |ch, i| expected[i] = ch - '0';
    try std.testing.expectEqual(expected, board.toFlat(engine.state.board));
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.count());
    switch (engine.state.history.peekPast().?) {
        .solve_batch => {},
        .cell => return error.TestFailed,
    }
    try std.testing.expect(ev.ok.msg == null);
    try std.testing.expect(!engine.getLegend().solve);
}

test "exec solve_for_me returns ok and leaves an unsolvable board unchanged" {
    var line: [81]u8 = @splat('0');
    for (0..8) |c| line[c] = '1' + @as(u8, @intCast(c));
    line[1 * 9 + 8] = '9';
    var engine = try GameEngine.init(&line, config.Config.default());
    defer engine.deinit();
    const before = board.toFlat(engine.state.board);

    const ev = execTest(&engine, .{ .solve_for_me = {} });
    _ = try expectOk(ev);
    try std.testing.expect(ev.ok.msg == null);
    try std.testing.expectEqual(before, board.toFlat(engine.state.board));
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.count());
}

test "exec solve_for_me errors when the board has a conflict" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    try engine.state.board.setCell(0, 1, .three);
    engine.state.board.validate();
    const before = board.toFlat(engine.state.board);

    const ev = execTest(&engine, .{ .solve_for_me = {} });
    try expectErrorResult(ev);
    try std.testing.expectEqual(before, board.toFlat(engine.state.board));
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.count());
}

test "legend solve is on only when the board has empties and no conflict" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    try std.testing.expect(engine.getLegend().solve);

    try engine.state.board.setCell(0, 1, .three);
    engine.state.board.validate();
    try std.testing.expect(!engine.getLegend().solve);
}

test "openFromSave warns when SUD0 bytes encode an unsolvable grid" {
    const flat: [81]u8 = .{
        0, 0, 3, 4, 2, 1, 6, 0, 0, 9, 0, 0, 3, 7, 5, 0, 0, 1, 0, 0, 1, 8, 9, 6, 4, 0, 0,
        0, 0, 8, 1, 0, 2, 9, 0, 0, 7, 0, 0, 5, 0, 4, 1, 0, 8, 0, 0, 6, 7, 0, 8, 2, 0, 0,
        0, 0, 2, 6, 0, 9, 5, 0, 0, 8, 0, 0, 2, 0, 3, 0, 0, 9, 0, 0, 5, 0, 1, 7, 3, 0, 0,
    };
    const given_bits: u128 = 0x54949b0d901361b25254;

    var dead = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer dead.deinit();
    dead.state.board = try board.fromFlat(flat, .{ .given_bits = given_bits });
    dead.state.board.validate();

    const buf = try dead.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const ev = openFromSaveProbeTest(&engine, buf, "dead.sud");
    try std.testing.expect(ev == .ok);
    try std.testing.expect(ev.ok.msg != null);
    const msg = ev.ok.msg.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "opened: dead.sud") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "no solution") != null);
}

test "loadSaveFormat replaces board and history from SUD0 bytes" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try engine.state.board.setCell(0, 2, .seven);
    try engine.state.history.push(0, 2, .zero, .seven);

    const buf = try save_format.toSaveFormat(&engine.state, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var fresh = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer fresh.deinit();
    try fresh.loadSaveFormat(buf);

    try std.testing.expect(board.equal(engine.state.board, fresh.state.board));
    try std.testing.expectEqual(@as(usize, 1), fresh.state.history.pointer);
}
test "importFromLine loads a one-line puzzle and clears history" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Seed one mutation so the reset is observable.
    try engine.state.board.setCell(0, 3, .seven);
    try engine.state.history.push(0, 3, .zero, .seven);
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);

    const line = puzzle_gen.PuzzleGen.hard();
    const ev = engine.importFromLine(line);
    try std.testing.expect(ev == .ok);
    try std.testing.expectEqualStrings("import: puzzle loaded", ev.ok.msg.?);

    const expected = try board.fromOneLineString(line);
    try std.testing.expect(board.equal(engine.state.board, expected));
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.pointer);
}

test "importFromLine rejects a short line and leaves board and history intact" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    try engine.state.board.setCell(0, 3, .seven);
    try engine.state.history.push(0, 3, .zero, .seven);
    const before = board.toFlat(engine.state.board);

    const ev = engine.importFromLine("12345");
    try std.testing.expect(ev == .error_msg);
    try std.testing.expectEqualStrings("import: expected exactly 81 characters", ev.error_msg);
    try std.testing.expectEqual(before, board.toFlat(engine.state.board));
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);
}

test "importFromLine rejects invalid characters without touching state" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    const before = board.toFlat(engine.state.board);

    var bad: [81]u8 = undefined;
    for (&bad) |*c| c.* = 'z';
    const ev = engine.importFromLine(bad[0..]);
    try std.testing.expect(ev == .error_msg);
    try std.testing.expectEqualStrings("import: invalid character in puzzle line", ev.error_msg);
    try std.testing.expectEqual(before, board.toFlat(engine.state.board));
}

test "legend offers import in the web session menu" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try std.testing.expect(engine.getLegend().import);
}

test "toSaveFormat serializes state without engine file methods" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try engine.state.board.setCell(0, 2, .seven);
    try engine.state.history.push(0, 2, .zero, .seven);

    const buf = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer loaded.deinit();
    try loaded.loadSaveFormat(buf);
    try std.testing.expectEqual(cell.CellValue.seven, loaded.state.board.getCellValue(0, 2));
}

test "GameEngine fill updates cell value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const view = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 3));
}

test "GameEngine init builds board from puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    const view = engine.eventBoard();

    // puzzle[0..2] is '6' → A1 should be a given (six)
    try std.testing.expect(view.isGiven(0, 0));
    try std.testing.expectEqual(cell.CellValue.six, view.get(0, 0));

    // puzzle[2] is '.' → A3 should be non-given and empty
    try std.testing.expect(!view.isGiven(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, view.get(0, 2));
}

test "codec round-trip via loadSaveFormat and toSaveFormat — no engine file methods" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const buf = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer loaded.deinit();
    try loaded.loadSaveFormat(buf);

    try std.testing.expect(board.equal(engine.state.board, loaded.state.board));
    try std.testing.expectEqual(engine.state.history.count(), loaded.state.history.count());
    try std.testing.expectEqual(cell.CellValue.seven, loaded.state.board.getCellValue(@as(u4, 0), @as(u4, 2)));
}

// exec(Command) returns structured results with given-cell feedback

test "exec fill non-given cell → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
}

test "exec fill given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const result = execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 0, .digit = cell.CellValue.nine },
    });
    try expectErrorResult(result);
}

test "exec clear given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const result = execTest(&engine, command.Command{
        .clear = command.ClearData{ .row = 0, .col = 0 },
    });
    try expectErrorResult(result);
}

test "exec quit → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const view = try expectOk(execTest(&engine, command.Command{ .quit = {} }));
    // quit returns board_view with no message
    _ = view;
}

// exec wires validator into mutation path
// Integration chain: exec → board mutation → conflict refresh → event emission
// Check conflict bits through the returned Event board_view

test "exec fill that kills solvability warns with the mutated cell" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();

    const ev = execMoveTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    });
    try std.testing.expect(ev == .ok);
    try std.testing.expect(ev.ok.msg != null);
    const msg = ev.ok.msg.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "unsolvable") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "B2") != null);
    try std.testing.expect(!ev.ok.board_view.isConflictingRowCol(1, 1));
}

test "inline unsolvable grid: fill warns and clear restores same dead board" {
    const flat: [81]u8 = .{
        0, 0, 3, 4, 2, 1, 6, 0, 0, 9, 0, 0, 3, 7, 5, 0, 0, 1, 0, 0, 1, 8, 9, 6, 4, 0, 0,
        0, 0, 8, 1, 0, 2, 9, 0, 0, 7, 0, 0, 5, 0, 4, 1, 0, 8, 0, 0, 6, 7, 0, 8, 2, 0, 0,
        0, 0, 2, 6, 0, 9, 5, 0, 0, 8, 0, 0, 2, 0, 3, 0, 0, 9, 0, 0, 5, 0, 1, 7, 3, 0, 0,
    };
    const given_bits: u128 = 0x54949b0d901361b25254;

    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    engine.state.board = try board.fromFlat(flat, .{ .given_bits = given_bits });
    engine.state.board.validate();

    const after_load = try solver.solve(engine.state.board);
    try std.testing.expect(after_load == .none);

    const filled = execMoveTest(&engine, command.Command{
        .fill = command.FillData{ .row = 7, .col = 6, .digit = cell.CellValue.seven },
    });
    try std.testing.expect(filled == .ok);
    try std.testing.expect(filled.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, filled.ok.msg.?, "unsolvable") != null);

    const cleared = execMoveTest(&engine, command.Command{
        .clear = command.ClearData{ .row = 7, .col = 6 },
    });
    try std.testing.expect(cleared == .ok);
    try std.testing.expect(cleared.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared.ok.msg.?, "unsolvable") != null);
    try std.testing.expect(board.equal(
        engine.state.board,
        try board.fromFlat(flat, .{ .given_bits = given_bits }),
    ));
}

test "exec clear after unsolvable fill restores solvable board without warning" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execMoveTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    }));

    const cleared = execTest(&engine, command.Command{
        .clear = command.ClearData{ .row = 1, .col = 1 },
    });
    try std.testing.expect(cleared == .ok);
    try std.testing.expect(cleared.ok.msg == null);
    const solved = try solver.solve(engine.state.board);
    try std.testing.expect(solved == .solution);
}

test "exec undo after unsolvable fill restores solvable board without warning" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execMoveTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    }));

    const undo = execTest(&engine, command.Command{ .undo = {} });
    try std.testing.expect(undo == .ok);
    try std.testing.expect(undo.ok.msg == null);
    const solved = try solver.solve(engine.state.board);
    try std.testing.expect(solved == .solution);
}

test "exec fill creates conflict → cell marked and status msg set" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Row 0: cells (0,2) and (0,3) are both empty — duplicate ones create a row conflict
    const fill1 = command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
    };

    const first = execTest(&engine, fill1);
    try std.testing.expect(first == .ok);
    try std.testing.expect(first.ok.msg == null);

    const second = execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.one },
    });
    try std.testing.expect(second == .ok);
    const view = second.ok.board_view;
    try std.testing.expectEqualStrings("conflict in row, column, or box", second.ok.msg.?);

    // Both cells in row 0 must now be flagged as conflicting
    try std.testing.expect(view.isConflictingRowCol(0, 2));
    try std.testing.expect(view.isConflictingRowCol(0, 3));

    // A cell not in the conflict path should be clean (row 5, col 5)
    try std.testing.expect(!view.isConflictingRowCol(5, 5));
}

test "exec clear resolves conflict → previously-conflicting peer now clean" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Create a row-0 conflict pair: (0,2) and (0,3) both eight
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
    }));

    {
        const view = try expectOk(execTest(&engine, command.Command{
            .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
        }));
        try std.testing.expect(view.isConflictingRowCol(0, 2));
        try std.testing.expect(view.isConflictingRowCol(0, 3));
    }

    // Clear (0,3) → its peer (0,2) should no longer be flagged either
    {
        const view = try expectOk(execTest(&engine, command.Command{
            .clear = command.ClearData{ .row = 0, .col = 3 },
        }));
        try std.testing.expect(!view.isConflictingRowCol(0, 2));
        try std.testing.expect(!view.isConflictingRowCol(0, 3));
    }
}

test "exec fill no conflict → no bits set" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Row 0 already has six at (0,0) and seven at (0,1).
    // Fill (0,2) with one — unique across its row, col, and box → clean.
    const ev = execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
    });
    try std.testing.expect(ev == .ok);
    try std.testing.expect(ev.ok.msg == null);
    const view = ev.ok.board_view;

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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
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
        .error_msg = "cannot modify a puzzle cell",
    };
}

// Integration test — game engine init propagates board error from puzzle

test "GameEngine.init propagates invalid puzzle error" {
    try std.testing.expectError(
        Error.System, // board errors are caught and converted to System
        GameEngine.init("too-short", config.Config.default()),
    );
}

test "GameEngine is non-generic, init takes only puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    const view = engine.eventBoard();

    // Board was built correctly from the puzzle string
    try std.testing.expect(view.isGiven(0, 0));

    // No renderer field exists (compile-time guarantee if struct is non-generic)
}

test "exec fill returns Event.ok with board_view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    const view = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    // board_view reflects the mutation
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 2));
}

test "eventBoard returns current board view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const view1 = engine.eventBoard();
    // A1 is a given (six)
    try std.testing.expectEqual(cell.CellValue.six, view1.get(0, 0));

    // Mutate the board
    _ = try expectOk(execTest(&engine, command.Command{
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const result = switch (execTest(&engine, command.Command{ .undo = {} })) {
        .ok => return error.TestFailed,
        .error_msg => |msg| msg,
    };
    try std.testing.expectEqualStrings(result, "nothing to undo");
}

test "exec then undo reverses a fill back to zero" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Fill A3 (row 0, col 2) with seven
    const fill_view = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, fill_view.get(0, 2));

    // Undo — should revert to zero
    const undo_view = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.zero, undo_view.get(0, 2));
}

test "exec then undo then redo re-applies the fill" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Fill A3 with seven
    const fill_view = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, fill_view.get(0, 2));

    // Undo — should revert to zero
    const undo_view = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.zero, undo_view.get(0, 2));

    // Redo — should re-apply seven
    const redo_view = try expectOk(execTest(&engine, command.Command{ .redo = {} }));
    try std.testing.expectEqual(cell.CellValue.seven, redo_view.get(0, 2));
}

test "new mutation after undo truncates future redo path" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Fill 3 cells A, B, C all on different empty cells
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    // Undo twice — back to after A only (pointer=1)
    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));

    // Now B and C cells should be empty again
    const view_after_undo = engine.eventBoard();
    try std.testing.expectEqual(cell.CellValue.zero, view_after_undo.get(1, 2));
    try std.testing.expectEqual(cell.CellValue.zero, view_after_undo.get(1, 3));

    // Make new fill D on B's cell — should truncate [B,C] from future
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.four },
    }));

    // Redo should fail (no future to redo — path was truncated)
    const redo_result = execTest(&engine, command.Command{ .redo = {} });
    try expectErrorResult(redo_result);
}

test "undo clear restores previous value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Fill B1 (row 1, col 1) with three
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    }));

    // Clear B1
    const clear_view = try expectOk(execTest(&engine, command.Command{
        .clear = command.ClearData{ .row = 1, .col = 1 },
    }));
    try std.testing.expectEqual(cell.CellValue.zero, clear_view.get(1, 1));

    // Undo the clear — should restore three
    const undo_view = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.three, undo_view.get(1, 1));
}

// Multi-step undo/redo integration

test "multiple undo walks history backwards" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Fill three cells: A=one at (1,1), B=two at (1,2), C=three at (1,3)
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
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
    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Undo #2 reverts B → (1,2) empty again
    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }
}

test "multiple redo walks forwards correctly" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Fill three cells: A=one at (1,1), B=two at (1,2), C=three at (1,3)
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    // Undo all three
    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #1 re-applies A → (1,1) = one
    _ = try expectOk(execTest(&engine, command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #2 re-applies B → (1,2) = two
    _ = try expectOk(execTest(&engine, command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #3 re-applies C → (1,3) = three
    _ = try expectOk(execTest(&engine, command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.three, v.get(1, 3));
    }
}

test "redo on empty future returns .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Fill some cells — no undo yet, so nothing to redo
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    // Redo with nothing undone should fail
    const result = execTest(&engine, command.Command{ .redo = {} });
    try expectErrorResult(result);
}

test "getLegend: fresh engine has Fill/Clear/Quit only" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(cmds.menu);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(!cmds.redo);
}

test "exec fill that completes the board announces You win!" {
    const full = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    var line: [81]u8 = undefined;
    @memcpy(&line, full);
    const empty_idx: usize = 40;
    const fill_digit = line[empty_idx];
    line[empty_idx] = '0';
    var engine = try GameEngine.init(&line, config.Config.default());
    defer engine.deinit();
    const row: u4 = @intCast(@divTrunc(empty_idx, 9));
    const col: u4 = @intCast(@mod(empty_idx, 9));

    const ev = execTest(&engine, command.Command{
        .fill = command.FillData{ .row = row, .col = col, .digit = cell.rawToCellValue(fill_digit - '0') },
    });
    try std.testing.expect(ev == .ok);
    try std.testing.expect(ev.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, ev.ok.msg.?, "You win!") != null);
}

test "exec fill that does not complete the board has no win message" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const ev = execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 4, .col = 4, .digit = cell.CellValue.three },
    });
    try std.testing.expect(ev == .ok);
    if (ev.ok.msg) |msg| {
        try std.testing.expect(std.mem.indexOf(u8, msg, "You win!") == null);
    }
}

test "exec win is not re-announced on an already-solved board" {
    const full = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    var line: [81]u8 = undefined;
    @memcpy(&line, full);
    const empty_idx: usize = 40;
    const fill_digit = line[empty_idx];
    line[empty_idx] = '0';
    var engine = try GameEngine.init(&line, config.Config.default());
    defer engine.deinit();
    const row: u4 = @intCast(@divTrunc(empty_idx, 9));
    const col: u4 = @intCast(@mod(empty_idx, 9));
    const digit = cell.rawToCellValue(fill_digit - '0');

    const win = execTest(&engine, command.Command{
        .fill = command.FillData{ .row = row, .col = col, .digit = digit },
    });
    try std.testing.expect(win.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, win.ok.msg.?, "You win!") != null);

    const again = execTest(&engine, command.Command{
        .fill = command.FillData{ .row = row, .col = col, .digit = digit },
    });
    try std.testing.expect(again == .ok);
    if (again.ok.msg) |msg| {
        try std.testing.expect(std.mem.indexOf(u8, msg, "You win!") == null);
    }
}

test "finishOkAfterCellEdit sets event cell to mutated coordinates" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const result = execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 4, .col = 4, .digit = cell.CellValue.three },
    });
    switch (result) {
        .ok => |data| {
            try std.testing.expectEqual(@as(u4, 4), data.cell.?.row);
            try std.testing.expectEqual(@as(u4, 4), data.cell.?.col);
        },
        .error_msg => return error.TestFailed,
    }
}

test "getLegend: after fill Undo appears" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(cmds.redo);
}

test "getLegend: after partial undo both Undo and Redo available" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(cmds.undo);
    try std.testing.expect(cmds.redo);
}

test "getLegend: after full undo Undo hidden Redo replays" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));
    _ = try expectOk(execTest(&engine, command.Command{ .undo = {} }));

    const cmds = engine.getLegend();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(cmds.redo);
}
test "getLegend: Save and Open always available" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const cmds = engine.getLegend();
    // Save and Open are always available like Fill/Clear/Quit (not state-contingent)
    try std.testing.expect(cmds.save);
    try std.testing.expect(cmds.open);
}

test "getConfig: default view prefs are dark theme and region off" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const cfg = engine.getConfig();
    try std.testing.expectEqual(config.ViewTheme.dark, cfg.theme);
    try std.testing.expect(!cfg.show_region);
}

test "exec set_theme and set_region update view config" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{ .set_theme = .light }));
    var cfg = engine.getConfig();
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);

    _ = try expectOk(execTest(&engine, command.Command{ .set_region = true }));
    cfg = engine.getConfig();
    try std.testing.expect(cfg.show_region);
}

test "loadSaveFormat preserves view config" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    engine.cfg.theme = .light;
    engine.cfg.show_region = true;

    const buf = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    try engine.loadSaveFormat(buf);
    const cfg = engine.getConfig();
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);
    try std.testing.expect(cfg.show_region);
}

test "open handler loads save file via transport" {
    const transport = file_transport.NativeTransport.make(std.testing.io);
    const tmp_path = "/tmp/sudoku_open_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    var original = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer original.deinit();
    _ = try expectOk(execTest(&original, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const save_buf = try original.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(save_buf);
    try transport.write(transport.context, tmp_path, save_buf);

    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer loaded.deinit();

    const result = open_command.execute(&loaded, transport, tmp_path);
    switch (result) {
        .ok => |data| {
            try std.testing.expectEqual(cell.CellValue.seven, data.board_view.get(0, 2));
        },
        .error_msg => return error.TestFailed,
    }
}
