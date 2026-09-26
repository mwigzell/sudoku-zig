// Backtracking solver over empty cells on a Board copy. Placed digits stay.
// Candidate pruning uses setCell + refreshConflictsForCell — same path as play.
const std = @import("std");
const board = @import("board/board.zig");
const cell = @import("board/cell.zig");

pub const SolveResult = union(enum) {
    solution: [81]u8,
    none,
};

pub const SolveError = error{Conflict};

pub fn solve(b: board.Board) SolveError!SolveResult {
    var work = b;
    work.validate();
    if (work.conflict_bits != 0) return error.Conflict;
    if (search(&work, 0)) return .{ .solution = board.toFlat(work) };
    return .none;
}

/// Count completions up to `limit` (use 2 to test unique-solution puzzles).
pub fn countSolutions(b: board.Board, limit: usize) SolveError!usize {
    var work = b;
    work.validate();
    if (work.conflict_bits != 0) return error.Conflict;
    var count: usize = 0;
    countSearch(&work, 0, limit, &count);
    return count;
}

fn countSearch(work: *board.Board, start: usize, limit: usize, count: *usize) void {
    _ = start;
    if (count.* >= limit) return;
    const slot = nextEmptyMRV(work) orelse {
        count.* += 1;
        return;
    };
    var digit: u8 = 1;
    while (digit <= 9) : (digit += 1) {
        const val = cell.rawToCellValue(digit);
        work.setCell(slot.row, slot.col, val) catch unreachable;
        work.refreshConflictsForCell(slot.row, slot.col);
        if (work.isConflicting(slot.idx)) {
            work.setCell(slot.row, slot.col, .zero) catch unreachable;
            work.refreshConflictsForCell(slot.row, slot.col);
            continue;
        }
        countSearch(work, 0, limit, count);
        work.setCell(slot.row, slot.col, .zero) catch unreachable;
        work.refreshConflictsForCell(slot.row, slot.col);
        if (count.* >= limit) return;
    }
}

fn search(work: *board.Board, start: usize) bool {
    const slot = nextEmpty(work, start) orelse return true;
    var digit: u8 = 1;
    while (digit <= 9) : (digit += 1) {
        const val = cell.rawToCellValue(digit);
        work.setCell(slot.row, slot.col, val) catch unreachable;
        work.refreshConflictsForCell(slot.row, slot.col);
        if (work.isConflicting(slot.idx)) {
            work.setCell(slot.row, slot.col, .zero) catch unreachable;
            work.refreshConflictsForCell(slot.row, slot.col);
            continue;
        }
        if (search(work, slot.idx + 1)) return true;
        work.setCell(slot.row, slot.col, .zero) catch unreachable;
        work.refreshConflictsForCell(slot.row, slot.col);
    }
    return false;
}

fn candidateCount(work: *board.Board, row: u4, col: u4) u8 {
    var n: u8 = 0;
    var digit: u8 = 1;
    while (digit <= 9) : (digit += 1) {
        const val = cell.rawToCellValue(digit);
        work.setCell(row, col, val) catch unreachable;
        work.refreshConflictsForCell(row, col);
        const idx: usize = @as(usize, @intCast(row)) * board.DIMENSION_SIZE + @as(usize, @intCast(col));
        if (!work.isConflicting(idx)) {
            n += 1;
        }
        work.setCell(row, col, .zero) catch unreachable;
        work.refreshConflictsForCell(row, col);
    }
    return n;
}

const SearchSlot = struct { row: u4, col: u4, idx: usize };

fn nextEmptyMRV(work: *board.Board) ?SearchSlot {
    var best: ?SearchSlot = null;
    var best_n: u8 = 10;
    var i: usize = 0;
    while (i < board.CELL_COUNT) : (i += 1) {
        const row: u4 = @intCast(@divTrunc(i, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(i, board.DIMENSION_SIZE));
        if (work.isGiven(row, col)) continue;
        if (work.getCellValue(row, col) != .zero) continue;
        const n = candidateCount(work, row, col);
        if (n < best_n) {
            best_n = n;
            best = .{ .row = row, .col = col, .idx = i };
            if (n <= 1) break;
        }
    }
    return best;
}

fn nextEmpty(work: *const board.Board, start: usize) ?struct { row: u4, col: u4, idx: usize } {
    var i = start;
    while (i < board.CELL_COUNT) : (i += 1) {
        const row: u4 = @intCast(@divTrunc(i, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(i, board.DIMENSION_SIZE));
        if (work.isGiven(row, col)) continue;
        if (work.getCellValue(row, col) == .zero) return .{ .row = row, .col = col, .idx = i };
    }
    return null;
}

const easy = "003020600900305001001806400008102900700000008006708200002609500800203009005010300";
const solution = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";

test "solve fills a known partial to the hardcoded solution" {
    const b = try board.fromOneLineString(easy);
    const result = try solve(b);
    switch (result) {
        .none => return error.TestFailed,
        .solution => |grid| {
            var expected: [81]u8 = undefined;
            for (solution, 0..) |ch, i| expected[i] = ch - '0';
            try std.testing.expectEqual(expected, grid);
        },
    }
}

test "solve returns none when a conflict-free partial has no completion" {
    var line: [81]u8 = @splat('0');
    for (0..8) |c| line[c] = '1' + @as(u8, @intCast(c));
    line[1 * 9 + 8] = '9';
    const b = try board.fromOneLineString(&line);
    const before = board.toFlat(b);
    const result = try solve(b);
    try std.testing.expect(result == .none);
    try std.testing.expectEqual(before, board.toFlat(b));
}

test "solve errors when the board already has a conflict" {
    var line: [81]u8 = @splat('0');
    line[0] = '5';
    line[1] = '5';
    const b = try board.fromOneLineString(&line);
    const before = board.toFlat(b);
    const result = solve(b) catch |err| {
        try std.testing.expectEqual(error.Conflict, err);
        try std.testing.expectEqual(before, board.toFlat(b));
        return;
    };
    _ = result;
    return error.TestFailed;
}

test "countSolutions reports one completion for a well-posed puzzle" {
    const b = try board.fromOneLineString(easy);
    try std.testing.expectEqual(@as(usize, 1), try countSolutions(b, 2));
}

test "countSolutions stops at limit for ambiguous partials" {
    var line: [81]u8 = @splat('0');
    line[0] = '1';
    const b = try board.fromOneLineString(&line);
    const n = try countSolutions(b, 2);
    try std.testing.expect(n >= 2);
}

test "solve completes the single empty cell of a known grid" {
    const full = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";
    var line: [81]u8 = undefined;
    @memcpy(&line, full);
    line[40] = '0';
    const b = try board.fromOneLineString(&line);
    const result = try solve(b);
    switch (result) {
        .none => return error.TestFailed,
        .solution => |grid| {
            var expected: [81]u8 = undefined;
            for (full, 0..) |ch, i| expected[i] = ch - '0';
            try std.testing.expectEqual(expected, grid);
        },
    }
}
