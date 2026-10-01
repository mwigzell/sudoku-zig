// Live puzzle generation — run via `zig build verify-slow` (not `verify`).
// Wall-clock bound: scripts/verify-slow-gate.sh (45s suite budget).
const std = @import("std");
const board = @import("../board/board.zig");
const puzzle_gen = @import("mod.zig");
const solver = @import("../solver.zig");

test "puzzle_gen live: generateInto yields unique solvable puzzle in givens range" {
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    var line: [81]u8 = undefined;
    try puzzle_gen.PuzzleGen.generateInto(.easy, prng.random(), &line, null, null);
    const b = try board.fromOneLineString(&line);
    try std.testing.expectEqual(@as(usize, 1), try solver.countSolutions(b, 2));
    const givens = puzzle_gen.countGivens(&line);
    try std.testing.expect(givens >= 36 and givens <= 45);
}

test "puzzle_gen live: play retry policy always yields a puzzle" {
    var line: [81]u8 = undefined;
    var seed: u64 = 0;
    while (seed < 30) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        if (puzzle_gen.PuzzleGen.generateInto(.medium, prng.random(), &line, null, null)) {
            // ok
        } else |_| {
            try puzzle_gen.PuzzleGen.generateIntoDigHole(.medium, prng.random(), &line, null, null);
        }
        const b = try board.fromOneLineString(&line);
        try std.testing.expectEqual(@as(usize, 1), try solver.countSolutions(b, 2));
    }
}

test "puzzle_gen live: consecutive generated puzzles differ at same difficulty" {
    var prng = std.Random.DefaultPrng.init(0xABCD_EF01);
    var a: [81]u8 = undefined;
    var b: [81]u8 = undefined;
    try puzzle_gen.PuzzleGen.generateInto(.easy, prng.random(), &a, null, null);
    try puzzle_gen.PuzzleGen.generateInto(.easy, prng.random(), &b, null, null);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
