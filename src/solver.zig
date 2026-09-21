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
    if (search(&work, 0)) return .{ .solution = work.toFlat() };
    return .none;
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
    var b = try board.fromOneLineString(&line);
    const before = b.toFlat();
    const result = try solve(b);
    try std.testing.expect(result == .none);
    try std.testing.expectEqual(before, b.toFlat());
}

test "solve errors when the board already has a conflict" {
    var line: [81]u8 = @splat('0');
    line[0] = '5';
    line[1] = '5';
    var b = try board.fromOneLineString(&line);
    const before = b.toFlat();
    const result = solve(b) catch |err| {
        try std.testing.expectEqual(error.Conflict, err);
        try std.testing.expectEqual(before, b.toFlat());
        return;
    };
    _ = result;
    return error.TestFailed;
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
