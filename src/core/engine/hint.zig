// hint.zig — solver-backed hint: one solve, the hint as a sentence on `.ok.msg`, display-only.

const std = @import("std");
const game_engine = @import("game_engine.zig");
const command = @import("../command.zig");
const board = @import("../board/board.zig");
const cell = @import("../board/cell.zig");
const solver = @import("../solver.zig");

pub const no_solution_msg = "There is no solution from here. Try Undo.";
pub const load_no_solution_msg = "This puzzle has no solution.";
pub const puzzle_complete_msg = "The puzzle is complete.";
/// Targeted hint when the board has no solution; `{s}` is the cell.
pub const NO_SOLUTION_AT_FMT = "{s} has no solution from here. Try Undo.";
/// Hint for a cell whose digit matches the solution; `{c}` is the digit, `{s}` the cell.
pub const CONSISTENT_FMT = "The {c} in {s} is right.";
/// Hint for a cell whose digit is wrong: cell, solution digit, played digit.
pub const BLOCKER_FMT = "{s} should be {c}, not {c}.";
/// Hint for an empty cell: cell, solution digit.
pub const PLACEMENT_FMT = "{s} takes {c}.";

/// Append play-loop dead-end copy after a move that leaves no completion (`.ok.msg` fragment).
pub fn appendNoSolutionMsg(engine: *game_engine.GameEngine) void {
    engine.appendEventMsg(no_solution_msg);
}

/// The no-solution sentence, naming the cell when the hint targeted one.
fn appendNoSolutionFor(engine: *game_engine.GameEngine, hint: command.HintData) void {
    if (hint.row != null and hint.col != null) {
        var label: [2]u8 = undefined;
        engine.appendEventMsgFmt(NO_SOLUTION_AT_FMT, .{board.formatCellLabel(&label, hint.row.?, hint.col.?)});
    } else {
        appendNoSolutionMsg(engine);
    }
}

/// Append load/import dead-puzzle copy when the opened grid has no solution (`.ok.msg` fragment).
pub fn appendLoadNoSolutionMsg(engine: *game_engine.GameEngine) void {
    engine.appendEventMsg(load_no_solution_msg);
}

/// One above the maximum candidate count (9); empty cells never exceed 9 options.
const candidate_count_sentinel: u8 = board.DIMENSION_SIZE + 1;

fn solutionDigitAt(solution: [81]u8, row: u4, col: u4) u8 {
    const idx = @as(usize, @intCast(row)) * board.DIMENSION_SIZE + @as(usize, @intCast(col));
    return solution[idx];
}

/// Flat solver digit (1–9) → ASCII `'1'`–`'9'` (not `{c}` on raw value — 8 is backspace).
fn flatDigitDisplay(digit: u8) u8 {
    return '0' + digit;
}

fn playerDigitChar(view: board.Board.BoardView, row: u4, col: u4) ?u8 {
    const v = view.get(row, col);
    if (v == .zero) return null;
    return cell.displayChar(v);
}

fn appendTargetedMsg(
    engine: *game_engine.GameEngine,
    row: u4,
    col: u4,
    solution: [81]u8,
    view: board.Board.BoardView,
) void {
    var label: [2]u8 = undefined;
    const coord = board.formatCellLabel(&label, row, col);
    const sol_digit = flatDigitDisplay(solutionDigitAt(solution, row, col));
    if (playerDigitChar(view, row, col)) |played| {
        if (played == sol_digit) {
            engine.appendEventMsgFmt(CONSISTENT_FMT, .{ sol_digit, coord });
        } else {
            engine.appendEventMsgFmt(BLOCKER_FMT, .{ coord, sol_digit, played });
        }
    } else {
        engine.appendEventMsgFmt(PLACEMENT_FMT, .{ coord, sol_digit });
    }
}

fn appendEnginePickMsg(engine: *game_engine.GameEngine, solution: [81]u8) void {
    const view = engine.state.board.asView();
    var i: usize = 0;
    while (i < board.CELL_COUNT) : (i += 1) {
        const row: u4 = @intCast(@divTrunc(i, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(i, board.DIMENSION_SIZE));
        if (engine.state.board.isGiven(row, col)) continue;
        if (view.get(row, col) == .zero) continue;
        const sol_digit = flatDigitDisplay(solutionDigitAt(solution, row, col));
        if (playerDigitChar(view, row, col)) |played| {
            if (played != sol_digit) {
                appendTargetedMsg(engine, row, col, solution, view);
                return;
            }
        }
    }

    var best_row: ?u4 = null;
    var best_col: ?u4 = null;
    var best_count: u8 = candidate_count_sentinel;
    i = 0;
    while (i < board.CELL_COUNT) : (i += 1) {
        const row: u4 = @intCast(@divTrunc(i, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(i, board.DIMENSION_SIZE));
        if (engine.state.board.isGiven(row, col)) continue;
        if (view.get(row, col) != .zero) continue;
        const n = solver.candidateCountForEmptyCell(&engine.state.board, row, col);
        if (n < best_count) {
            best_count = n;
            best_row = row;
            best_col = col;
        }
    }

    if (best_row == null) {
        engine.appendEventMsg(puzzle_complete_msg);
        return;
    }
    const row = best_row.?;
    const col = best_col.?;
    appendTargetedMsg(engine, row, col, solution, view);
}

/// The hint's target, dropped when it is a given: a given is always right, so core picks the cell instead.
fn effectiveTarget(engine: *const game_engine.GameEngine, hint: command.HintData) command.HintData {
    const row = hint.row orelse return .{};
    const col = hint.col orelse return .{};
    if (engine.state.board.isGiven(row, col)) return .{};
    return hint;
}

/// Display-only hint; uses one `solver.solve` pass. `requested` names the selected cell, if any:
/// a player cell gets a hint about itself, a given or no cell gets core's pick. Returns `.ok` with the sentence on `msg`.
pub fn execute(engine: *game_engine.GameEngine, requested: command.HintData) game_engine.Event {
    const hint = effectiveTarget(engine, requested);
    const solved = solver.solve(engine.state.board) catch |err| switch (err) {
        error.Conflict => {
            appendNoSolutionFor(engine, hint);
            return engine.finishOkEvent(engine.state.board.asView(), false, null, false);
        },
    };
    switch (solved) {
        .none => {
            appendNoSolutionFor(engine, hint);
            return engine.finishOkEvent(engine.state.board.asView(), false, null, false);
        },
        .solution => |solution| {
            if (hint.row != null and hint.col != null) {
                appendTargetedMsg(engine, hint.row.?, hint.col.?, solution, engine.state.board.asView());
            } else {
                appendEnginePickMsg(engine, solution);
            }
            if (engine.event_msg.optional() == null) appendNoSolutionMsg(engine);
            return engine.finishOkEvent(engine.state.board.asView(), false, null, false);
        },
    }
}

test "hint: unsolvable board returns the no-solution sentence" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    engine.warn_dead_moves = true;
    const fill_ev = engine.exec(command.Command{
        .fill = .{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    });
    if (fill_ev != .ok) return error.TestFailed;

    const ev = engine.exec(command.Command{ .hint = .{} });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, "no solution") != null);
}

const TestCell = struct { row: u4, col: u4, idx: usize };

/// The first cell, in reading order, that `match` accepts.
fn firstCellWhere(engine: *game_engine.GameEngine, comptime match: fn (*game_engine.GameEngine, u4, u4) bool) ?TestCell {
    var idx: usize = 0;
    while (idx < board.CELL_COUNT) : (idx += 1) {
        const row: u4 = @intCast(@divTrunc(idx, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(idx, board.DIMENSION_SIZE));
        if (match(engine, row, col)) return .{ .row = row, .col = col, .idx = idx };
    }
    return null;
}

fn isEmptyPlayerCell(engine: *game_engine.GameEngine, row: u4, col: u4) bool {
    return !engine.state.board.isGiven(row, col) and engine.state.board.asView().get(row, col) == .zero;
}

fn isGivenCell(engine: *game_engine.GameEngine, row: u4, col: u4) bool {
    return engine.state.board.isGiven(row, col);
}

fn firstEmptyPlayerCell(engine: *game_engine.GameEngine) ?TestCell {
    return firstCellWhere(engine, isEmptyPlayerCell);
}

fn firstGivenCell(engine: *game_engine.GameEngine) ?TestCell {
    return firstCellWhere(engine, isGivenCell);
}

/// Room for any hint sentence a test copies out.
const HINT_MSG_CAP = 128;

/// The hint sentence for `hint`, copied out of the engine's reused message buffer.
fn hintMsg(engine: *game_engine.GameEngine, hint: command.HintData, buf: *[HINT_MSG_CAP]u8) ![]const u8 {
    const ev = engine.exec(command.Command{ .hint = hint });
    if (ev != .ok) return error.TestFailed;
    const msg = ev.ok.msg orelse return error.TestFailed;
    if (msg.len > buf.len) return error.TestFailed;
    @memcpy(buf[0..msg.len], msg);
    return buf[0..msg.len];
}

test "hint: targeted at a given gives the untargeted hint" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    const given = firstGivenCell(&engine) orelse return error.TestFailed;

    var untargeted_buf: [HINT_MSG_CAP]u8 = undefined;
    var targeted_buf: [HINT_MSG_CAP]u8 = undefined;
    const untargeted = try hintMsg(&engine, .{}, &untargeted_buf);
    const targeted = try hintMsg(&engine, .{ .row = given.row, .col = given.col }, &targeted_buf);
    try std.testing.expectEqualStrings(untargeted, targeted);
}

test "hint: targeted at a given on a dead board gives the untargeted no-solution sentence" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    engine.warn_dead_moves = true;
    const fill_ev = engine.exec(command.Command{
        .fill = .{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    });
    if (fill_ev != .ok) return error.TestFailed;
    const given = firstGivenCell(&engine) orelse return error.TestFailed;

    var buf: [HINT_MSG_CAP]u8 = undefined;
    try std.testing.expectEqualStrings(no_solution_msg, try hintMsg(&engine, .{ .row = given.row, .col = given.col }, &buf));
}

test "hint: targeted consistent sentence" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const sr = try solver.solve(engine.state.board);
    const solution = switch (sr) {
        .solution => |s| s,
        else => return error.TestFailed,
    };
    const slot = firstEmptyPlayerCell(&engine) orelse return error.TestFailed;
    const digit = cell.rawToCellValue(solution[slot.idx]);
    const fill_ev = engine.exec(command.Command{
        .fill = .{ .row = slot.row, .col = slot.col, .digit = digit },
    });
    if (fill_ev != .ok) return error.TestFailed;

    const ev = engine.exec(command.Command{
        .hint = .{ .row = slot.row, .col = slot.col },
    });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    var label: [2]u8 = undefined;
    var want_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, CONSISTENT_FMT, .{ flatDigitDisplay(solution[slot.idx]), board.formatCellLabel(&label, slot.row, slot.col) });
    try std.testing.expectEqualStrings(want, msg);
}

test "hint: targeted blocker sentence when completion disagrees with cell" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const sr = try solver.solve(engine.state.board);
    var solution = switch (sr) {
        .solution => |s| s,
        else => return error.TestFailed,
    };
    const slot = firstEmptyPlayerCell(&engine) orelse return error.TestFailed;
    const played_flat = solution[slot.idx];
    const alt_flat: u8 = if (played_flat == 1) 2 else 1;
    const fill_ev = engine.exec(command.Command{
        .fill = .{ .row = slot.row, .col = slot.col, .digit = cell.rawToCellValue(played_flat) },
    });
    if (fill_ev != .ok) return error.TestFailed;

    solution[slot.idx] = alt_flat;
    engine.beginEventMsg();
    appendTargetedMsg(&engine, slot.row, slot.col, solution, engine.state.board.asView());
    const msg = engine.event_msg.optional() orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, " should be ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "should be") != null);
}

test "hint: engine-pick surfaces blocker before placement" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const sr = try solver.solve(engine.state.board);
    var solution = switch (sr) {
        .solution => |s| s,
        else => return error.TestFailed,
    };
    const slot = firstEmptyPlayerCell(&engine) orelse return error.TestFailed;
    const played_flat = solution[slot.idx];
    const alt_flat: u8 = if (played_flat == 1) 2 else 1;
    const fill_ev = engine.exec(command.Command{
        .fill = .{ .row = slot.row, .col = slot.col, .digit = cell.rawToCellValue(played_flat) },
    });
    if (fill_ev != .ok) return error.TestFailed;

    solution[slot.idx] = alt_flat;
    engine.beginEventMsg();
    appendEnginePickMsg(&engine, solution);
    const msg = engine.event_msg.optional() orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, " should be ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, " takes ") == null);
}

test "hint: targeted empty cell returns placement sentence" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const ev = engine.exec(command.Command{
        .hint = .{ .row = 0, .col = 0 },
    });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, " takes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "A1") != null);
    try std.testing.expect(msg.len > 0 and msg[0] != 0x08);
    var has_digit = false;
    for (msg) |ch| {
        if (ch >= '1' and ch <= '9') has_digit = true;
        try std.testing.expect(ch != 0x08);
    }
    try std.testing.expect(has_digit);
}

test "hint: targeted on dead board returns no-solution not blocker" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    engine.warn_dead_moves = true;
    const fill_ev = engine.exec(command.Command{
        .fill = .{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    });
    if (fill_ev != .ok) return error.TestFailed;

    const ev = engine.exec(command.Command{
        .hint = .{ .row = 1, .col = 1 },
    });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, "no solution") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "B2") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, " should be ") == null);
}

test "hint: engine-pick on complete puzzle reports complete" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    const solved = engine.exec(command.Command{ .solve_for_me = {} });
    try std.testing.expect(solved == .ok);

    const ev = engine.exec(command.Command{ .hint = .{} });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.eql(u8, msg, puzzle_complete_msg));
}

test "hint: engine-pick on solvable board returns placement" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const ev = engine.exec(command.Command{ .hint = .{} });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, " takes ") != null);
}

test "fill on dead board uses no-solution hint copy only" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen/mod.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    engine.warn_dead_moves = true;

    const ev = engine.exec(command.Command{
        .fill = .{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, "no solution") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, " should be ") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "unsolvable") == null);
}
