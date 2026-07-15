const board = @import("board.zig");
const std = @import("std");

// Canned puzzle pool — one per difficulty tier. 81-char strings, digits or dots.

const easy   = "003020600900305001001806400008102900700000008006708200002609500800203009005010300";
const medium = "850002400720000009004000000000040070060000300003000009000000050000800093004070006";
const hard   = "000000000000003085001020000000507000004000100090000000500009300060040210000701000";

pub const Difficulty = enum { easy, medium, hard };

/// Returns the canned puzzle for a given difficulty as an 81-char one-line string.
pub fn generate(diff: Difficulty) []const u8 {
    return switch (diff) {
        .easy => easy,
        .medium => medium,
        .hard => hard,
    };
}

/// Count the number of given cells in a one-line string.
pub fn countGivens(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch != '.' and ch != '0') n += 1;
    }
    return n;
}

test "puzzle_gen: each string is exactly 81 chars" {
    try std.testing.expectEqual(@as(usize, 81), easy.len);
    try std.testing.expectEqual(@as(usize, 81), medium.len);
    try std.testing.expectEqual(@as(usize, 81), hard.len);
}

test "puzzle_gen: all puzzles load into Board" {
    _ = try board.fromOneLineString(generate(.easy));
    _ = try board.fromOneLineString(generate(.medium));
    _ = try board.fromOneLineString(generate(.hard));
}
