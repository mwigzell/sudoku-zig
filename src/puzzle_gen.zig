const board = @import("board.zig");
const std = @import("std");

/// Canonical puzzle difficulty levels. .default is the legacy dot-blanked fixture.
pub const Difficulty = enum { default, easy, medium, hard };

pub const PuzzleGen = struct {
    const easy_str = "003020600900305001001806400008102900700000008006708200002609500800203009005010300";
    const medium_str = "850002400720000009004000000000040070060000300003000009000000050000800093004070006";
    const hard_str = "000000000000003085001020000000507000004000100090000000500009300060040210000701000";
    /// Legacy default puzzle (dot-blanked) — preserved for backward-compatible test fixtures.
    const default_str = "67..4..524....1....53.87.91....12.85.2...46..7.5...21..47.3.52.5.62.8.499.....378";

    /// Return the canned puzzle for a given difficulty as an 81-char one-line string.
    pub fn generate(diff: Difficulty) []const u8 {
        return switch (diff) {
            .default => default_str,
            .easy => easy_str,
            .medium => medium_str,
            .hard => hard_str,
        };
    }

    /// Convenience wrappers — each delegates through `generate()`.
    pub fn default() []const u8 {
        return generate(.default);
    }

    pub fn easy() []const u8 {
        return generate(.easy);
    }

    pub fn medium() []const u8 {
        return generate(.medium);
    }

    pub fn hard() []const u8 {
        return generate(.hard);
    }
};

/// Return the number of given cells in a one-line string.
pub fn countGivens(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch != '.' and ch != '0') n += 1;
    }
    return n;
}

test "puzzle_gen: each string is exactly 81 chars" {
    try std.testing.expectEqual(81, PuzzleGen.default().len);
    try std.testing.expectEqual(81, PuzzleGen.easy().len);
    try std.testing.expectEqual(81, PuzzleGen.medium().len);
    try std.testing.expectEqual(81, PuzzleGen.hard().len);
}

test "puzzle_gen: all puzzles load into Board" {
    _ = try board.fromOneLineString(PuzzleGen.default());
    _ = try board.fromOneLineString(PuzzleGen.easy());
    _ = try board.fromOneLineString(PuzzleGen.medium());
    _ = try board.fromOneLineString(PuzzleGen.hard());
}
