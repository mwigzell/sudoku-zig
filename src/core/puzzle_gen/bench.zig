// Ad-hoc generator bench — not in main.zig graph. Run: scripts/bench-puzzle-gen.sh
const std = @import("std");
const puzzle_gen = @import("mod.zig");
const board = @import("../board/board.zig");
const solver = @import("../solver.zig");

fn benchProgress(event: puzzle_gen.GenProgressEvent, ctx: ?*anyopaque) void {
    _ = ctx;
    switch (event) {
        .round => std.debug.print("[gen] new outer attempt\n", .{}),
        .dig_hole => std.debug.print("[gen] fast path failed — dig-hole\n", .{}),
        .strip => |s| std.debug.print("[gen] stripped to {d} givens (≤{d})\n", .{ s.givens, s.target }),
        .attempt => |a| std.debug.print("[gen] attempt {d}/{d}\n", .{ a.n, a.max }),
        .carve => |c| {
            if (c.step == 1 or c.step % 10 == 0 or c.givens <= c.target + 2) {
                std.debug.print("[gen] carve step={d} givens={d} (stop at ≤{d})\n", .{
                    c.step, c.givens, c.target,
                });
            }
        },
        .uniqueness_check => |u| std.debug.print("[gen] uniqueness check @ givens={d} …\n", .{u.givens}),
    }
}

test "bench: one dig-hole easy generation" {
    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    var line: [81]u8 = undefined;
    try puzzle_gen.PuzzleGen.generateIntoDigHole(.easy, prng.random(), &line, benchProgress, null);
    const b = try board.fromOneLineString(&line);
    try std.testing.expectEqual(@as(usize, 1), try solver.countSolutions(b, 2));
    const g = puzzle_gen.countGivens(&line);
    try std.testing.expect(g >= 36 and g <= 45);
}

test "bench: first successful dig-hole easy and attempt count" {
    var line: [81]u8 = undefined;
    var seed: u64 = 1;
    while (seed < 200) : (seed += 1) {
        std.debug.print("[gen] trying seed {d}\n", .{seed});
        var prng = std.Random.DefaultPrng.init(seed);
        puzzle_gen.PuzzleGen.generateIntoDigHole(.easy, prng.random(), &line, benchProgress, null) catch continue;
        const b = board.fromOneLineString(&line) catch continue;
        if ((try solver.countSolutions(b, 2)) != 1) continue;
        const g = puzzle_gen.countGivens(&line);
        if (g < 36 or g > 45) continue;
        std.debug.print("dig-hole easy: success at seed {d}\n", .{seed});
        return;
    }
    return error.TestFailed;
}

test "bench: dig-hole success rate over seeds" {
    const trials: u16 = 10;
    var ok: u16 = 0;
    var seed: u64 = 0xC0FFEE;
    var t: u16 = 0;
    while (t < trials) : (t += 1) {
        seed +%= 0x9E3779B97F4A7C15;
        std.debug.print("[gen] trial {d}/{d} seed={d}\n", .{ t + 1, trials, seed });
        var prng = std.Random.DefaultPrng.init(seed);
        var line: [81]u8 = undefined;
        puzzle_gen.PuzzleGen.generateIntoDigHole(.easy, prng.random(), &line, benchProgress, null) catch continue;
        const b = board.fromOneLineString(&line) catch continue;
        const n = solver.countSolutions(b, 2) catch continue;
        if (n != 1) continue;
        const g = puzzle_gen.countGivens(&line);
        if (g < 36 or g > 45) continue;
        ok += 1;
    }
    std.debug.print("puzzle_gen dig-hole easy: {d}/{d} ok\n", .{ ok, trials });
    try std.testing.expect(ok >= 1);
}

test "bench: one fast generateInto easy with progress" {
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    var line: [81]u8 = undefined;
    try puzzle_gen.PuzzleGen.generateInto(.easy, prng.random(), &line, benchProgress, null);
    const b = try board.fromOneLineString(&line);
    try std.testing.expectEqual(@as(usize, 1), try solver.countSolutions(b, 2));
}
