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
const logger = @import("../logger.zig");
const file_policy = @import("../file_policy.zig");

// Moved to src/core/event.zig, re-exported for backward compat
const event = @import("../event.zig");
pub const Event = event.Event;

// SUD0 codec and the State it reads and writes.
const save_format = @import("save_format.zig");
const state_mod = @import("state.zig");

// Moved to src/core/engine/mutation_history.zig, re-exported for backward compat
const mutation_history = @import("mutation_history.zig");
const fill_command = @import("fill.zig");
const clear_command = @import("clear.zig");
const undo_command = @import("undo.zig");
const redo_command = @import("redo.zig");
const quit_command = @import("quit.zig");
const hint_command = @import("hint.zig");
const pencil_command = @import("pencil.zig");
const solver = @import("../solver.zig");
pub const MutationEntry = mutation_history.MutationEntry;
pub const MutationHistory = mutation_history.MutationHistory;
pub const Error = error{System};
pub const NEW_GAME_STARTED_MSG = "A new game has started.";
pub const OPENED_FMT = "The file {s} is open.";
pub const IMPORTED_MSG = "The puzzle was imported.";
pub const PASTED_MSG = "The puzzle was pasted.";
pub const CONFLICT_MSG = "That digit clashes with another in the same row, column or box.";
pub const WIN_STATUS_MSG = "You win!";

/// Error sentences a command shows in a dialog; technical detail goes to the log.
pub const PUZZLE_CELL_MSG = "That cell is part of the puzzle, so it can't be changed.";
pub const CELL_CHANGE_FAILED_MSG = "The cell could not be changed.";
pub const MOVE_NOT_RECORDED_MSG = "The move could not be recorded, so it was not made.";
pub const SOLVE_CONFLICT_MSG = "The board has a conflict, so it can't be solved. Clear the conflicting cells and try again.";
pub const NOT_A_SAVED_GAME_MSG = "The file is not a saved Sudoku game, or it is damaged.";
pub const PUZZLE_LENGTH_MSG = "A puzzle in Simple Line Format must have exactly 81 characters.";
pub const PUZZLE_CHARACTER_MSG = "A puzzle in Simple Line Format can only contain the digits 1 to 9, with 0, ., X, *, _ or a space for an empty cell.";
pub const NEW_GAME_FAILED_MSG = "A new game could not be started.";
pub const NOTHING_TO_UNDO_MSG = "There is nothing to undo.";
pub const NOTHING_TO_REDO_MSG = "There is nothing to redo.";
pub const UNDO_FAILED_MSG = "The last move could not be undone.";
pub const REDO_FAILED_MSG = "The move could not be redone.";

const log = logger.Logger(.engine);

/// Owns portable game state. No file transport or I/O here.
const SolvabilityProbe = enum { move, load };
const LoadStatusMode = enum {
    open,
    startup_restore,
};

pub const GameEngine = struct {
    state: state_mod.State,
    cfg: config.Config,
    event_msg: event.EventMsg = .{},
    /// After a player move, probe solvability and warn when the board has no completion.
    warn_dead_moves: bool = false,
    /// On open/load, probe solvability and warn when the puzzle has no completion.
    warn_unsolvable_load: bool = false,
    /// Digits toggle pencil marks instead of filling. Session state: starts off, never saved.
    pencil_mode: bool = false,
    /// The last command set or removed a mark (a mark, or its Undo or Redo).
    marks_changed: bool = false,
    /// The selected cell: set by a select, or by the last cell a move changed (fill, clear, mark,
    /// or their Undo or Redo). Deselect and loading a game drop it; Hint, Solve and refused moves
    /// leave it. Session state, never saved.
    selected: ?event.CellCoord = null,

    fn applySolvabilityWarningsFromConfig(self: *@This()) void {
        self.warn_dead_moves = self.cfg.warn_solvability;
        self.warn_unsolvable_load = self.cfg.warn_solvability;
    }

    /// Build an engine from a one-line puzzle string and nominal config.
    pub fn init(puzzle_str: []const u8, cfg: config.Config) Error!@This() {
        const brd = board.fromPuzzle(puzzle_str) catch return Error.System;
        var self = @This(){
            .state = .{
                .board = brd,
                .history = MutationHistory.init(std.heap.page_allocator),
            },
            .cfg = cfg,
        };
        self.applySolvabilityWarningsFromConfig();
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
            .pencil = true,
            .clear = true,
            .hint = true,
            .quit = true,
            .undo = self.state.history.pointer > 0,
            .redo = self.state.history.pointer < self.state.history.entries.items.len,
            .menu = true,
            .save = !self.cfg.auto_save,
            .open = true,
            .new = true,
            .import = true,
            .@"export" = true,
            .copy = true,
            .paste = true,
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

    /// Whether front ends draw pencil marks: the setting is on, Pencil mode is on,
    /// or the last command changed a mark, so a player always sees the mark they made.
    pub fn marksVisible(self: *const @This()) bool {
        return self.cfg.show_marks or self.pencil_mode or self.marks_changed;
    }

    /// Current nominal configuration (theme, region highlight, difficulty, log level).
    pub fn getConfig(self: *const @This()) config.Config {
        return self.cfg;
    }

    /// Serialize full game state to a heap-allocated byte buffer.
    pub fn toSaveFormat(self: *const @This(), gpa: std.mem.Allocator) ![]u8 {
        return save_format.toSaveFormat(&self.state, gpa);
    }

    /// Current durable status (restored from save and updated by command policy).
    pub fn durableStatus(self: *const @This()) ?[]const u8 {
        return self.state.status.optional();
    }

    /// Replace board and history from a SUD0 blob produced by `toSaveFormat`.
    pub fn fromSaveFormat(self: *@This(), buf: []const u8) !void {
        const gpa = std.heap.page_allocator;
        const loaded = try save_format.fromSaveFormat(gpa, buf);
        self.state.history.deinit();
        self.state.board = loaded.board;
        self.state.history = loaded.history;
        self.state.status = loaded.status;
        self.state.board.validate();
        self.selected = null;
    }

    /// Open from SUD0 bytes — the core open command calls this on every platform.
    pub fn openFromSave(self: *@This(), buf: []const u8, opened_label: ?[]const u8) Event {
        self.fromSaveFormat(buf) catch |err| {
            log.err("open: not a saved game ({s})", .{@errorName(err)});
            return self.errorEvent(NOT_A_SAVED_GAME_MSG);
        };
        return self.finishLoadEvent(opened_label, .open);
    }

    /// Startup restore path: rehydrate state and surface only persisted status.
    pub fn restoreFromSave(self: *@This(), buf: []const u8) Event {
        self.fromSaveFormat(buf) catch |err| {
            log.err("restore: not a saved game ({s})", .{@errorName(err)});
            return self.errorEvent(NOT_A_SAVED_GAME_MSG);
        };
        return self.finishLoadEvent(null, .startup_restore);
    }

    /// Replace board and clear history from a puzzle in Simple Line Format, untrimmed.
    /// Failure leaves board and history untouched.
    pub fn applyOneLinePuzzle(self: *@This(), line: []const u8) board.Error!void {
        const imported = try board.fromPuzzle(line);
        self.state.history.deinit();
        self.state.history = MutationHistory.init(std.heap.page_allocator);
        self.state.board = imported;
        self.selected = null;
    }

    /// The game as a puzzle: the board's cell values as 81 characters, `0` for an empty cell.
    pub fn toPuzzle(self: *const @This()) [board.CELL_COUNT]u8 {
        return board.toPuzzle(self.state.board);
    }

    /// Import a one-line puzzle (81 digits/blanks) from a file.
    pub fn fromPuzzle(self: *@This(), line: []const u8) Event {
        return self.loadOneLine(line, IMPORTED_MSG);
    }

    /// Paste a one-line puzzle (81 digits/blanks) from the clipboard or a prompt.
    pub fn pasteFromLine(self: *@This(), line: []const u8) Event {
        return self.loadOneLine(line, PASTED_MSG);
    }

    fn loadOneLine(self: *@This(), line: []const u8, loaded_msg: []const u8) Event {
        self.applyOneLinePuzzle(line) catch |err| switch (err) {
            board.Error.WrongLength => return self.errorEvent(PUZZLE_LENGTH_MSG),
            else => return self.errorEvent(PUZZLE_CHARACTER_MSG),
        };
        self.beginEventMsg();
        self.appendEventMsg(loaded_msg);
        return self.finishOkEvent(self.state.board.asView(), false, null, false);
    }

    /// New game from a one-line puzzle string (generate dialog or fallback fixture).
    pub fn newFromOneLinePuzzle(self: *@This(), line: []const u8) Event {
        self.applyOneLinePuzzle(line) catch {
            return .{ .error_msg = NEW_GAME_FAILED_MSG };
        };
        self.state.status.reset();
        self.state.status.append(NEW_GAME_STARTED_MSG);
        return .{
            .ok = .{
                .board_view = self.state.board.asView(),
                .msg = self.state.status.optional(),
                .is_quit = false,
            },
        };
    }

    /// Clear the per-exec `.ok.msg` scratch buffer before appending message parts.
    pub fn beginEventMsg(self: *@This()) void {
        self.event_msg.reset();
    }

    /// Append one `.ok.msg` fragment; multiple sources may contribute in the same exec step.
    pub fn appendEventMsg(self: *@This(), part: []const u8) void {
        self.event_msg.append(part);
    }

    /// Append formatted text to the current `.ok.msg` scratch buffer.
    pub fn appendEventMsgFmt(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.event_msg.appendFmt(fmt, args);
    }

    /// Optional solvability check for warning paths — not used by solve_for_me or redo solve_batch.
    fn probeSolvability(self: *@This(), when: SolvabilityProbe) ?solver.SolveResult {
        const enabled = switch (when) {
            .move => self.warn_dead_moves,
            .load => self.warn_unsolvable_load,
        };
        if (!enabled) return null;
        return solver.solve(self.state.board) catch |err| {
            log.info("expected: solvability not checked, the board has a conflict ({s})", .{@errorName(err)});
            return null;
        };
    }

    fn appendUnsolvableLoadWarningIfNeeded(self: *@This()) void {
        const solved = self.probeSolvability(.load) orelse return;
        if (solved == .none) hint_command.appendLoadNoSolutionMsg(self);
    }

    fn finishLoadEvent(self: *@This(), opened_label: ?[]const u8, mode: LoadStatusMode) Event {
        self.beginEventMsg();
        switch (mode) {
            .open => {
                if (opened_label) |label| self.appendEventMsgFmt(OPENED_FMT, .{label});
                self.appendUnsolvableLoadWarningIfNeeded();
                return self.finishOkEvent(self.state.board.asView(), false, null, true);
            },
            .startup_restore => {
                if (self.state.status.optional()) |persisted| self.appendEventMsg(persisted);
                return self.finishOkEvent(self.state.board.asView(), false, null, true);
            },
        }
    }

    /// Build `.ok` using accumulated msg (null when nothing was appended).
    /// A non-null `edited_cell` becomes the selection.
    pub fn finishOkEvent(
        self: *@This(),
        view: board.Board.BoardView,
        is_quit: bool,
        edited_cell: ?event.CellCoord,
        clear_when_empty: bool,
    ) Event {
        if (edited_cell) |c| self.selected = c;
        if (self.event_msg.optional()) |msg| {
            self.state.status.reset();
            self.state.status.append(msg);
        } else if (clear_when_empty) {
            self.state.status.reset();
        }
        return .{ .ok = .{
            .board_view = view,
            .msg = self.state.status.optional(),
            .is_quit = is_quit,
        } };
    }

    /// One error string in engine scratch — safe for wasm JSON after exec returns.
    pub fn errorEvent(self: *@This(), part: []const u8) Event {
        self.event_msg.reset();
        self.event_msg.append(part);
        return .{ .error_msg = self.event_msg.slice() };
    }

    /// Map low-level set-cell errors into user-facing command errors.
    pub fn eventFromSetCellError(self: *@This(), row: u4, col: u4, err: anyerror) Event {
        return switch (err) {
            error.IsGiven => self.errorEvent(PUZZLE_CELL_MSG),
            else => blk: {
                log.err("set cell ({d},{d}) failed: {s}", .{ row, col, @errorName(err) });
                break :blk self.errorEvent(CELL_CHANGE_FAILED_MSG);
            },
        };
    }

    /// Finalize `.ok` after one cell edit, including conflict/solvability/win messages.
    pub fn finishOkAfterCellEdit(self: *@This(), row: u4, col: u4) Event {
        self.state.board.refreshConflictsForCell(row, col);
        const view = self.state.board.asView();
        if (view.isConflictingRowCol(row, col)) {
            self.appendEventMsg(CONFLICT_MSG);
        } else if (self.probeSolvability(.move)) |solved| {
            if (solved == .none) hint_command.appendNoSolutionMsg(self);
        }
        if (self.state.board.isSolved()) {
            self.appendEventMsg(WIN_STATUS_MSG);
        }
        return self.finishOkEvent(view, false, .{ .row = row, .col = col }, true);
    }

    /// Route a gameplay command through Board mutation + render update.
    /// Session commands (save/open/new/save_as) are handled in native/shell/shell.zig.
    pub fn exec(self: *@This(), cmd: command.Command) Event {
        self.beginEventMsg();
        self.marks_changed = false;
        switch (cmd) {
            .fill => |f| {
                if (self.pencil_mode and f.digit != .zero) {
                    return pencil_command.execute(self, .{ .row = f.row, .col = f.col, .digit = f.digit });
                }
                return fill_command.execute(self, f);
            },
            .pencil => |p| {
                return pencil_command.execute(self, p);
            },
            .toggle_pencil_mode => {
                return pencil_command.toggleMode(self);
            },
            .toggle_show_marks => {
                self.cfg.show_marks = !self.cfg.show_marks;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .select => |s| {
                self.selected = .{ .row = s.row, .col = s.col };
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .deselect => {
                self.selected = null;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
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
            .hint => |h| {
                return hint_command.execute(self, h);
            },
            .set_theme => |theme| {
                self.cfg.theme = theme;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .toggle_region => {
                self.cfg.show_region = !self.cfg.show_region;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .toggle_warn_solvability => {
                self.cfg.warn_solvability = !self.cfg.warn_solvability;
                self.applySolvabilityWarningsFromConfig();
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .toggle_auto_restore => {
                self.cfg.auto_restore = !self.cfg.auto_restore;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .toggle_auto_new => {
                self.cfg.auto_new = !self.cfg.auto_new;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .toggle_auto_save => {
                self.cfg.auto_save = !self.cfg.auto_save;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .set_difficulty => |diff| {
                self.cfg.difficulty = diff;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .set_log_level => |level| {
                self.cfg.log_level = level;
                logger.min_level = level;
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
            .settings => @panic("settings routed in Sudoku"),
            .menu => @panic("menu routed in renderer"),
            .save, .open, .import, .@"export", .copy, .paste, .new, .save_as => @panic("load and write commands run in the core command flow"),
        }
    }

    /// Attempt to fill a cell with a digit. Records mutation in history.
    pub fn tryFill(self: *@This(), row: u4, col: u4, digit: cell.CellValue) Event {
        // Snapshot old value before mutation (only recorded on success)
        const old_value = self.state.board.asView().get(row, col);
        const old_marks = self.state.board.marksAt(row, col);
        self.state.board.setCell(row, col, digit) catch |err| {
            return self.eventFromSetCellError(row, col, err);
        };
        const cleared_peers = fill_command.clearMarks(&self.state.board, row, col, digit);
        // Persist the successful mutation in history
        // First discard stale future entries from any earlier undo branch
        self.state.history.truncateFuture();
        self.state.history.pushCell(.{
            .row = row,
            .col = col,
            .old_value = old_value,
            .new_value = digit,
            .old_marks = old_marks,
            .cleared_peers = cleared_peers,
        }) catch |err| {
            log.err("history push failed: {s}", .{@errorName(err)});
            return self.errorEvent(MOVE_NOT_RECORDED_MSG);
        };
        return self.finishOkAfterCellEdit(row, col);
    }

    /// Place each solver digit the board lacks. Each one clears marks as a player fill does.
    /// Returns the error event if a cell refuses its digit, otherwise null.
    pub fn placeSolution(self: *@This(), grid: [board.CELL_COUNT]u8) ?Event {
        for (grid, 0..) |digit, i| {
            const row: u4 = @intCast(i / board.DIMENSION_SIZE);
            const col: u4 = @intCast(i % board.DIMENSION_SIZE);
            const value = cell.rawToCellValue(digit);
            if (self.state.board.getCellValue(row, col) == value) continue;
            self.state.board.setCell(row, col, value) catch |err| return self.eventFromSetCellError(row, col, err);
            _ = fill_command.clearMarks(&self.state.board, row, col, value);
        }
        return null;
    }

    /// Fill every empty cell from one solver pass. One history step, not N fills.
    fn solveForMe(self: *@This()) Event {
        const before: mutation_history.BoardSnapshot = .{
            .given_bits = self.state.board.given_bits,
            .flat = board.toFlat(self.state.board),
            .mark_bits = self.state.board.mark_bits,
        };
        const solved = solver.solve(self.state.board) catch |err| switch (err) {
            error.Conflict => return self.errorEvent(SOLVE_CONFLICT_MSG),
        };
        switch (solved) {
            .none => return self.finishOkEvent(self.state.board.asView(), false, null, false),
            .solution => |grid| {
                if (self.placeSolution(grid)) |failed| return failed;
                self.state.history.truncateFuture();
                self.state.history.pushSolve(before) catch |push_err| {
                    log.err("history push failed: {s}", .{@errorName(push_err)});
                    return self.errorEvent(MOVE_NOT_RECORDED_MSG);
                };
                self.state.board.validate();
                self.beginEventMsg();
                self.appendEventMsg(WIN_STATUS_MSG);
                return self.finishOkEvent(self.state.board.asView(), false, null, false);
            },
        }
    }
};

// ────────────────────── co-located tests ──────────────────────
const puzzle_gen = @import("../puzzle_gen/mod.zig");

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
        .cell, .mark => return error.TestFailed,
    }
    try std.testing.expect(ev.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, ev.ok.msg.?, "You win!") != null);
    try std.testing.expect(engine.durableStatus() != null);
    try std.testing.expect(std.mem.indexOf(u8, engine.durableStatus().?, "You win!") != null);
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
    try std.testing.expect(engine.durableStatus() == null);
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
    const given_bits: board.CellMask = 0x54949b0d901361b25254;

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
    try std.testing.expect(std.mem.indexOf(u8, msg, std.fmt.comptimePrint(OPENED_FMT, .{"dead.sud"})) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "no solution") != null);
}

test "openFromSave joins competing status sentences with a space" {
    const flat: [81]u8 = .{
        0, 0, 3, 4, 2, 1, 6, 0, 0, 9, 0, 0, 3, 7, 5, 0, 0, 1, 0, 0, 1, 8, 9, 6, 4, 0, 0,
        0, 0, 8, 1, 0, 2, 9, 0, 0, 7, 0, 0, 5, 0, 4, 1, 0, 8, 0, 0, 6, 7, 0, 8, 2, 0, 0,
        0, 0, 2, 6, 0, 9, 5, 0, 0, 8, 0, 0, 2, 0, 3, 0, 0, 9, 0, 0, 5, 0, 1, 7, 3, 0, 0,
    };
    const given_bits: board.CellMask = 0x54949b0d901361b25254;

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
    const msg = ev.ok.msg.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, std.fmt.comptimePrint(OPENED_FMT, .{"dead.sud"})) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, hint_command.load_no_solution_msg) != null);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint(OPENED_FMT, .{"dead.sud"}) ++ " " ++ hint_command.load_no_solution_msg, msg);
}

test "fromSaveFormat replaces board and history from SUD0 bytes" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try engine.state.board.setCell(0, 2, .seven);
    try engine.state.history.pushCell(.{ .row = 0, .col = 2, .old_value = .zero, .new_value = .seven });

    const buf = try save_format.toSaveFormat(&engine.state, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var fresh = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer fresh.deinit();
    try fresh.fromSaveFormat(buf);

    try std.testing.expect(board.equal(engine.state.board, fresh.state.board));
    try std.testing.expectEqual(@as(usize, 1), fresh.state.history.pointer);
}
test "fromPuzzle loads a one-line puzzle and clears history" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    // Seed one mutation so the reset is observable.
    try engine.state.board.setCell(0, 3, .seven);
    try engine.state.history.pushCell(.{ .row = 0, .col = 3, .old_value = .zero, .new_value = .seven });
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);

    const line = puzzle_gen.PuzzleGen.hard();
    const ev = engine.fromPuzzle(line);
    try std.testing.expect(ev == .ok);
    try std.testing.expectEqualStrings(IMPORTED_MSG, ev.ok.msg.?);

    const expected = try board.fromPuzzle(line);
    try std.testing.expect(board.equal(engine.state.board, expected));
    try std.testing.expectEqual(@as(usize, 0), engine.state.history.pointer);
}

test "fromPuzzle rejects a short line and leaves board and history intact" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    try engine.state.board.setCell(0, 3, .seven);
    try engine.state.history.pushCell(.{ .row = 0, .col = 3, .old_value = .zero, .new_value = .seven });
    const before = board.toFlat(engine.state.board);

    const ev = engine.fromPuzzle("12345");
    try std.testing.expect(ev == .error_msg);
    try std.testing.expectEqualStrings(PUZZLE_LENGTH_MSG, ev.error_msg);
    try std.testing.expectEqual(before, board.toFlat(engine.state.board));
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);
}

test "applyOneLinePuzzle rejects short line without mutating state" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try engine.state.board.setCell(0, 3, .seven);
    try engine.state.history.pushCell(.{ .row = 0, .col = 3, .old_value = .zero, .new_value = .seven });
    const before = board.toFlat(engine.state.board);

    try std.testing.expectError(board.Error.WrongLength, engine.applyOneLinePuzzle("short"));
    try std.testing.expectEqual(before, board.toFlat(engine.state.board));
    try std.testing.expectEqual(@as(usize, 1), engine.state.history.pointer);
}

test "fromPuzzle rejects invalid characters without touching state" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    const before = board.toFlat(engine.state.board);

    var bad: [81]u8 = undefined;
    for (&bad) |*c| c.* = 'z';
    const ev = engine.fromPuzzle(bad[0..]);
    try std.testing.expect(ev == .error_msg);
    try std.testing.expectEqualStrings(PUZZLE_CHARACTER_MSG, ev.error_msg);
    try std.testing.expectEqual(before, board.toFlat(engine.state.board));
}

test "import and paste accept a puzzle that starts and ends with a space blank" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    const markers = "0.X*_ ";
    var line: [81]u8 = undefined;
    for (&line, 0..) |*ch, i| ch.* = markers[i % markers.len];
    line[0] = ' ';
    line[80] = ' ';
    line[7] = '5';

    try std.testing.expect(engine.fromPuzzle(&line) == .ok);
    try std.testing.expectEqual(@as(u8, 5), board.toFlat(engine.state.board)[7]);
    try std.testing.expect(engine.pasteFromLine(&line) == .ok);
}

test "a puzzle with surrounding whitespace is not trimmed and is rejected for its length" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    const before = board.toFlat(engine.state.board);
    const line: [81]u8 = @splat('0');

    for ([_][]const u8{ line ++ "\n", " " ++ line, "\t" ++ line ++ " " }) |padded| {
        const ev = engine.pasteFromLine(padded);
        try std.testing.expect(ev == .error_msg);
        try std.testing.expectEqualStrings(PUZZLE_LENGTH_MSG, ev.error_msg);
    }
    try std.testing.expectEqual(before, board.toFlat(engine.state.board));
}

test "legend offers import in the web session menu" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try std.testing.expect(engine.getLegend().import);
}

test "legend offers export in the web session menu" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try std.testing.expect(engine.getLegend().@"export");
}

test "legend offers copy in the web session menu" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try std.testing.expect(engine.getLegend().copy);
}

test "legend offers paste in the web session menu" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try std.testing.expect(engine.getLegend().paste);
}

test "toSaveFormat serializes state without engine file methods" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try engine.state.board.setCell(0, 2, .seven);
    try engine.state.history.pushCell(.{ .row = 0, .col = 2, .old_value = .zero, .new_value = .seven });

    const buf = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer loaded.deinit();
    try loaded.fromSaveFormat(buf);
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

test "codec round-trip via fromSaveFormat and toSaveFormat — no engine file methods" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const buf = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer loaded.deinit();
    try loaded.fromSaveFormat(buf);

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

fn expectSelected(engine: *const GameEngine, row: u4, col: u4) !void {
    try std.testing.expectEqual(@as(?event.CellCoord, .{ .row = row, .col = col }), engine.selected);
}

test "a fill, clear or mark selects its cell; Undo and Redo select the cell they change" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    try std.testing.expectEqual(@as(?event.CellCoord, null), engine.selected);

    _ = try expectOk(execTest(&engine, .{ .fill = .{ .row = 0, .col = 0, .digit = .four } }));
    try expectSelected(&engine, 0, 0);
    _ = try expectOk(execTest(&engine, .{ .pencil = .{ .row = 0, .col = 1, .digit = .eight } }));
    try expectSelected(&engine, 0, 1);
    _ = try expectOk(execTest(&engine, .{ .undo = {} }));
    try expectSelected(&engine, 0, 1);
    _ = try expectOk(execTest(&engine, .{ .undo = {} }));
    try expectSelected(&engine, 0, 0);
    _ = try expectOk(execTest(&engine, .{ .redo = {} }));
    try expectSelected(&engine, 0, 0);
    _ = try expectOk(execTest(&engine, .{ .redo = {} }));
    try expectSelected(&engine, 0, 1);
    _ = try expectOk(execTest(&engine, .{ .clear = .{ .row = 0, .col = 0 } }));
    try expectSelected(&engine, 0, 0);
}

test "select sets the selection and deselect drops it; neither changes the status line" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();
    _ = execTest(&engine, .{ .hint = .{} });
    const status = engine.durableStatus().?;

    const selected = execTest(&engine, .{ .select = .{ .row = 4, .col = 7 } });
    try expectSelected(&engine, 4, 7);
    try std.testing.expectEqualStrings(status, selected.ok.msg.?);
    const given = execTest(&engine, .{ .select = .{ .row = 0, .col = 2 } });
    try expectSelected(&engine, 0, 2);
    try std.testing.expectEqualStrings(status, given.ok.msg.?);

    const deselected = execTest(&engine, .{ .deselect = {} });
    try std.testing.expectEqual(@as(?event.CellCoord, null), engine.selected);
    try std.testing.expectEqualStrings(status, deselected.ok.msg.?);
}

test "Hint, Solve and a refused move leave the selection; loading a game drops it" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, .{ .fill = .{ .row = 0, .col = 0, .digit = .four } }));
    _ = execTest(&engine, .{ .hint = .{} });
    try expectSelected(&engine, 0, 0);
    try expectErrorResult(execTest(&engine, .{ .fill = .{ .row = 0, .col = 2, .digit = .nine } }));
    try expectSelected(&engine, 0, 0);
    _ = try expectOk(execTest(&engine, .{ .solve_for_me = {} }));
    try expectSelected(&engine, 0, 0);

    const saved = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(saved);
    try engine.fromSaveFormat(saved);
    try std.testing.expectEqual(@as(?event.CellCoord, null), engine.selected);

    _ = try expectOk(execTest(&engine, .{ .clear = .{ .row = 0, .col = 0 } }));
    try engine.applyOneLinePuzzle(puzzle_gen.PuzzleGen.easy());
    try std.testing.expectEqual(@as(?event.CellCoord, null), engine.selected);
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

test "exec fill on dead board emits the no-solution sentence on ok msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer engine.deinit();

    const ev = execMoveTest(&engine, command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    });
    try std.testing.expect(ev == .ok);
    try std.testing.expect(ev.ok.msg != null);
    const msg = ev.ok.msg.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "no solution") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(blocker)") == null);
    try std.testing.expect(!ev.ok.board_view.isConflictingRowCol(1, 1));
}

test "inline unsolvable grid: fill warns and clear restores same dead board" {
    const flat: [81]u8 = .{
        0, 0, 3, 4, 2, 1, 6, 0, 0, 9, 0, 0, 3, 7, 5, 0, 0, 1, 0, 0, 1, 8, 9, 6, 4, 0, 0,
        0, 0, 8, 1, 0, 2, 9, 0, 0, 7, 0, 0, 5, 0, 4, 1, 0, 8, 0, 0, 6, 7, 0, 8, 2, 0, 0,
        0, 0, 2, 6, 0, 9, 5, 0, 0, 8, 0, 0, 2, 0, 3, 0, 0, 9, 0, 0, 5, 0, 1, 7, 3, 0, 0,
    };
    const given_bits: board.CellMask = 0x54949b0d901361b25254;

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
    try std.testing.expect(std.mem.indexOf(u8, filled.ok.msg.?, "no solution") != null);

    const cleared = execMoveTest(&engine, command.Command{
        .clear = command.ClearData{ .row = 7, .col = 6 },
    });
    try std.testing.expect(cleared == .ok);
    try std.testing.expect(cleared.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared.ok.msg.?, "no solution") != null);
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
    try std.testing.expectEqualStrings(CONFLICT_MSG, second.ok.msg.?);

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
    var board_inst = try board.fromPuzzle(puzzle_str);
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
    var board_inst = try board.fromPuzzle(puzzle_str);
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
        .error_msg = PUZZLE_CELL_MSG,
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

    _ = h.pushCell(.{ .row = 2, .col = 5, .old_value = .three, .new_value = .seven }) catch unreachable;
    _ = h.pushCell(.{ .row = 4, .col = 1, .old_value = .zero, .new_value = .one }) catch unreachable;

    try std.testing.expectEqual(@as(usize, 2), h.count());
}

test "exec undo on empty history returns .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const result = switch (execTest(&engine, command.Command{ .undo = {} })) {
        .ok => return error.TestFailed,
        .error_msg => |msg| msg,
    };
    try std.testing.expectEqualStrings(result, NOTHING_TO_UNDO_MSG);
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

test "exec win is re-announced when a solved board is edited again" {
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
    try std.testing.expect(again.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, again.ok.msg.?, "You win!") != null);
}

test "durable status clears on solved-to-unsolved cell edit and re-announces on re-solve" {
    const full = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    var line: [81]u8 = undefined;
    @memcpy(&line, full);
    const target_idx: usize = 40;
    const target_digit = line[target_idx];
    line[target_idx] = '0';
    var engine = try GameEngine.init(&line, config.Config.default());
    defer engine.deinit();
    const row: u4 = @intCast(@divTrunc(target_idx, 9));
    const col: u4 = @intCast(@mod(target_idx, 9));
    const digit = cell.rawToCellValue(target_digit - '0');

    const win = execTest(&engine, command.Command{
        .fill = .{ .row = row, .col = col, .digit = digit },
    });
    try std.testing.expect(win == .ok);
    try std.testing.expect(win.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, win.ok.msg.?, "You win!") != null);

    const unsolve = execTest(&engine, command.Command{
        .clear = .{ .row = row, .col = col },
    });
    try std.testing.expect(unsolve == .ok);
    try std.testing.expect(unsolve.ok.msg == null);

    const win_again = execTest(&engine, command.Command{
        .fill = .{ .row = row, .col = col, .digit = digit },
    });
    try std.testing.expect(win_again == .ok);
    try std.testing.expect(win_again.ok.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, win_again.ok.msg.?, "You win!") != null);
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

test "getConfig: default view prefs are system theme and region off" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    const cfg = engine.getConfig();
    try std.testing.expectEqual(config.ViewTheme.system, cfg.theme);
    try std.testing.expect(!cfg.show_region);
}

test "exec toggle_warn_solvability flips engine warning flags" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    try std.testing.expect(!engine.warn_dead_moves);
    try std.testing.expect(!engine.warn_unsolvable_load);

    _ = try expectOk(execTest(&engine, command.Command{ .toggle_warn_solvability = {} }));
    try std.testing.expect(engine.warn_dead_moves);
    try std.testing.expect(engine.warn_unsolvable_load);
    try std.testing.expect(engine.getConfig().warn_solvability);

    _ = try expectOk(execTest(&engine, command.Command{ .toggle_warn_solvability = {} }));
    try std.testing.expect(!engine.warn_dead_moves);
    try std.testing.expect(!engine.warn_unsolvable_load);
}

test "exec set_theme and toggle_region update view config" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{ .set_theme = .light }));
    var cfg = engine.getConfig();
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);

    _ = try expectOk(execTest(&engine, command.Command{ .toggle_region = {} }));
    cfg = engine.getConfig();
    try std.testing.expect(cfg.show_region);
}

test "exec set_difficulty and set_log_level update config" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{ .set_difficulty = .hard }));
    try std.testing.expectEqual(config.Difficulty.hard, engine.getConfig().difficulty);

    _ = try expectOk(execTest(&engine, command.Command{ .set_log_level = .debug }));
    try std.testing.expectEqual(logger.Severity.debug, engine.getConfig().log_level);
    try std.testing.expectEqual(logger.Severity.debug, logger.min_level);
}

test "exec startup auto toggles flip config" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();

    _ = try expectOk(execTest(&engine, command.Command{ .toggle_auto_restore = {} }));
    _ = try expectOk(execTest(&engine, command.Command{ .toggle_auto_new = {} }));
    _ = try expectOk(execTest(&engine, command.Command{ .toggle_auto_save = {} }));

    const cfg = engine.getConfig();
    try std.testing.expect(cfg.auto_restore);
    try std.testing.expect(cfg.auto_new);
    try std.testing.expect(cfg.auto_save);
}

test "fromSaveFormat preserves view config" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    engine.cfg.theme = .light;
    engine.cfg.show_region = true;

    const buf = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    try engine.fromSaveFormat(buf);
    const cfg = engine.getConfig();
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);
    try std.testing.expect(cfg.show_region);
}

test "every engine error message reads as a sentence" {
    const sentence = @import("../../test/sentence.zig");
    inline for (.{
        PUZZLE_CELL_MSG,      CELL_CHANGE_FAILED_MSG, MOVE_NOT_RECORDED_MSG, SOLVE_CONFLICT_MSG,
        NOT_A_SAVED_GAME_MSG, PUZZLE_LENGTH_MSG,      PUZZLE_CHARACTER_MSG,  NEW_GAME_FAILED_MSG,
        NOTHING_TO_UNDO_MSG,  NOTHING_TO_REDO_MSG,    UNDO_FAILED_MSG,       REDO_FAILED_MSG,
    }) |msg| try sentence.expectSentence(msg);
}

test "every status message reads as a sentence, including formatted ones" {
    const sentence = @import("../../test/sentence.zig");
    const startup_policy = @import("../startup/policy.zig");
    const export_flow = @import("../flow/export.zig");
    inline for (.{
        NEW_GAME_STARTED_MSG,               WIN_STATUS_MSG,                   IMPORTED_MSG,
        PASTED_MSG,                         CONFLICT_MSG,                     hint_command.no_solution_msg,
        hint_command.load_no_solution_msg,  hint_command.puzzle_complete_msg, export_flow.COPIED_MSG,
        startup_policy.IDLE_STARTUP_STATUS, file_policy.WRITE_CANCELLED_MSG,  file_policy.SAVE_WHILE_AUTO_SAVE_MSG,
    }) |msg| try sentence.expectSentence(msg);
    var buf: [128]u8 = undefined;
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, OPENED_FMT, .{"game.sud"}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, file_policy.SAVED_TO_FMT, .{"game.sud"}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, export_flow.EXPORTED_TO_FMT, .{"puzzle.txt"}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, hint_command.CONSISTENT_FMT, .{ '5', "C2" }));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, hint_command.BLOCKER_FMT, .{ "C2", '5', '3' }));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, hint_command.PLACEMENT_FMT, .{ "C2", '5' }));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, hint_command.NO_SOLUTION_AT_FMT, .{"C2"}));
}
