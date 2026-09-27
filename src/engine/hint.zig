// hint.zig — solver-backed hint: one solve, reason tags on `.ok.msg`, display-only.

const std = @import("std");
const game_engine = @import("game_engine.zig");
const command = @import("../command.zig");
const board = @import("../board/board.zig");
const cell = @import("../board/cell.zig");
const solver = @import("../solver.zig");

pub const no_solution_msg = "no solution from here — try undo (no-solution)";
pub const load_no_solution_msg = "this puzzle has no solution (no-solution)";
pub const puzzle_complete_msg = "puzzle complete (consistent)";

/// Append play-loop dead-end copy after a move that leaves no completion (`.ok.msg` fragment).
pub fn appendNoSolutionMsg(engine: *game_engine.GameEngine) void {
    engine.appendEventMsg(no_solution_msg);
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
            engine.appendEventMsgFmt("{s}: {c} is consistent (consistent)", .{ coord, sol_digit });
        } else {
            engine.appendEventMsgFmt("{s} should be {c}, not {c} (blocker)", .{ coord, sol_digit, played });
        }
    } else {
        engine.appendEventMsgFmt("{s} takes {c} (placement)", .{ coord, sol_digit });
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

/// Display-only hint; uses one `solver.solve` pass.
pub fn execute(engine: *game_engine.GameEngine, hint: command.HintData) game_engine.Event {
    const solved = solver.solve(engine.state.board) catch |err| switch (err) {
        error.Conflict => {
            if (hint.row != null and hint.col != null) {
                var label: [2]u8 = undefined;
                const coord = board.formatCellLabel(&label, hint.row.?, hint.col.?);
                engine.appendEventMsgFmt("{s}: {s}", .{ coord, no_solution_msg });
            } else {
                appendNoSolutionMsg(engine);
            }
            if (engine.event_msg.optional() == null) appendNoSolutionMsg(engine);
            return engine.finishOkEvent(engine.state.board.asView(), false, null);
        },
    };
    switch (solved) {
        .none => {
            if (hint.row != null and hint.col != null) {
                var label: [2]u8 = undefined;
                const coord = board.formatCellLabel(&label, hint.row.?, hint.col.?);
                engine.appendEventMsgFmt("{s}: {s}", .{ coord, no_solution_msg });
            } else {
                appendNoSolutionMsg(engine);
            }
            if (engine.event_msg.optional() == null) appendNoSolutionMsg(engine);
            return engine.finishOkEvent(engine.state.board.asView(), false, null);
        },
        .solution => |solution| {
            if (hint.row != null and hint.col != null) {
                appendTargetedMsg(engine, hint.row.?, hint.col.?, solution, engine.state.board.asView());
            } else {
                appendEnginePickMsg(engine, solution);
            }
            if (engine.event_msg.optional() == null) appendNoSolutionMsg(engine);
            return engine.finishOkEvent(engine.state.board.asView(), false, null);
        },
    }
}

test "hint: unsolvable board returns no-solution tag" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    engine.warn_dead_moves = true;
    const fill_ev = engine.exec(command.Command{
        .fill = .{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    });
    if (fill_ev != .ok) return error.TestFailed;

    const ev = engine.exec(command.Command{ .hint = .{} });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, "(no-solution)") != null);
}

fn firstEmptyPlayerCell(engine: *game_engine.GameEngine) ?struct { row: u4, col: u4, idx: usize } {
    var idx: usize = 0;
    while (idx < board.CELL_COUNT) : (idx += 1) {
        const row: u4 = @intCast(@divTrunc(idx, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(idx, board.DIMENSION_SIZE));
        if (engine.state.board.isGiven(row, col)) continue;
        if (engine.state.board.asView().get(row, col) != .zero) continue;
        return .{ .row = row, .col = col, .idx = idx };
    }
    return null;
}

test "hint: targeted consistent tag" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
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
    try std.testing.expect(std.mem.indexOf(u8, msg, "(consistent)") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(blocker)") == null);
}

test "hint: targeted blocker tag when completion disagrees with cell" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
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
    try std.testing.expect(std.mem.indexOf(u8, msg, "(blocker)") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "should be") != null);
}

test "hint: engine-pick surfaces blocker before placement" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
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
    try std.testing.expect(std.mem.indexOf(u8, msg, "(blocker)") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(placement)") == null);
}

test "hint: targeted empty cell returns placement tag" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const ev = engine.exec(command.Command{
        .hint = .{ .row = 0, .col = 0 },
    });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, "(placement)") != null);
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
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
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
    try std.testing.expect(std.mem.indexOf(u8, msg, "(no-solution)") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "B2") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(blocker)") == null);
}

test "hint: engine-pick on complete puzzle reports complete" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    const solved = engine.exec(command.Command{ .solve_for_me = {} });
    try std.testing.expect(solved == .ok);

    const ev = engine.exec(command.Command{ .hint = .{} });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.eql(u8, msg, puzzle_complete_msg));
}

test "hint: engine-pick on solvable board returns placement" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();

    const ev = engine.exec(command.Command{ .hint = .{} });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, "(placement)") != null);
}

test "fill on dead board uses no-solution hint copy only" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.easy(), @import("../config.zig").Config.default());
    defer engine.deinit();
    engine.warn_dead_moves = true;

    const ev = engine.exec(command.Command{
        .fill = .{ .row = 1, .col = 1, .digit = cell.CellValue.eight },
    });
    try std.testing.expect(ev == .ok);
    const msg = ev.ok.msg orelse return error.TestFailed;
    try std.testing.expect(std.mem.indexOf(u8, msg, "(no-solution)") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "(blocker)") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "unsolvable") == null);
}
