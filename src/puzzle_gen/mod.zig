//! Live puzzle generation, difficulty fixtures, and progress callbacks (`live` / `bench` are adjunct tools).
const board = @import("../board/board.zig");
const builtin = @import("builtin");
const cell = @import("../board/cell.zig");
const serial = @import("../board/serial.zig");
const solver = @import("../solver.zig");
const std = @import("std");

/// Canonical puzzle difficulty levels. `.default` is the legacy dot-blanked fixture.
pub const Difficulty = enum { default, easy, medium, hard };

const base_solution = "483921657967345821251876493548132976729564138136798245372689514814253769695417382";

threadlocal var seed_salt: u64 = 0x9E3779B97F4A7C15;

fn runtimeSeed() u64 {
    seed_salt +%= 0xD1B54A32D192ED03;
    return seed_salt;
}

fn mix64(x: u64) u64 {
    var z = x;
    z ^= z >> 30;
    z *%= 0xBF58476D1CE4E5B9;
    z ^= z >> 27;
    z *%= 0x94D049BB133111EB;
    z ^= z >> 31;
    return z;
}

/// Test binary only — native play and wasm play both call `generateInto` via `generate`.
fn useGenerateFixtures() bool {
    return builtin.is_test;
}

const easy_str = "003020600900305001001806400008102900700000008006708200002609500800203009005010300";
const medium_str = "850002400720000009004000000000040070060000300003000009000000050000800093004070006";
const hard_str = "000000000000003085001020000000507000004000100090000000500009300060040210000701000";
const default_str = "67..4..524....1....53.87.91....12.85.2...46..7.5...21..47.3.52.5.62.8.499.....378";

fn fixtureLine(diff: Difficulty) []const u8 {
    return switch (diff) {
        .default => default_str,
        .easy => easy_str,
        .medium => medium_str,
        .hard => hard_str,
    };
}

pub const PuzzleGen = struct {
    threadlocal var generated_line: [81]u8 = undefined;
    threadlocal var play_progress_fn: ?GenProgressFn = null;
    threadlocal var play_progress_ctx: ?*anyopaque = null;
    threadlocal var play_abort_fn: ?*const fn (?*anyopaque) bool = null;
    threadlocal var play_abort_ctx: ?*anyopaque = null;
    threadlocal var play_aborted: bool = false;

    /// Optional live feedback during `generate()` (wasm status bar, native stderr, etc.).
    pub fn setPlayProgress(callback: ?GenProgressFn, ctx: ?*anyopaque) void {
        play_progress_fn = callback;
        play_progress_ctx = ctx;
    }

    /// Optional cooperative cancel (wasm worker / main gen); polled at progress boundaries.
    pub fn setPlayAbort(callback: ?*const fn (?*anyopaque) bool, ctx: ?*anyopaque) void {
        play_abort_fn = callback;
        play_abort_ctx = ctx;
        play_aborted = false;
    }

    /// Mix host-provided entropy into the generator seed stream.
    pub fn addEntropy(entropy: u64) void {
        seed_salt ^= mix64(entropy +% 0x9E3779B97F4A7C15);
    }

    /// Returns whether the last `generate()` pass was aborted; clears the latch.
    pub fn takePlayAborted() bool {
        const v = play_aborted;
        play_aborted = false;
        return v;
    }

    fn checkPlayAbort() bool {
        if (play_abort_fn) |cb| {
            if (cb(play_abort_ctx)) {
                play_aborted = true;
                return true;
            }
        }
        return false;
    }

    /// Fixed puzzles for deterministic tests (`GameEngine.init`, save-format tests, etc.).
    pub fn default() []const u8 {
        return default_str;
    }

    pub fn easy() []const u8 {
        return easy_str;
    }

    pub fn medium() []const u8 {
        return medium_str;
    }

    pub fn hard() []const u8 {
        return hard_str;
    }

    /// Generate a puzzle line for play (`init`, native New dialog, wasm New).
    pub fn generate(diff: Difficulty) []const u8 {
        if (useGenerateFixtures() and diff != .default) return fixtureLine(diff);
        return switch (diff) {
            .default => default_str,
            else => blk: {
                generateForPlay(diff, &generated_line);
                break :blk generated_line[0..81];
            },
        };
    }

    /// Live play only: keep trying real generators until one succeeds.
    fn generateForPlay(diff: Difficulty, out: *[81]u8) void {
        const progress = playProgressCallback();
        while (true) {
            if (checkPlayAbort()) return;
            reportProgress(progress.callback, progress.ctx, .round) catch return;
            var prng = std.Random.DefaultPrng.init(runtimeSeed());
            generateInto(diff, prng.random(), out, progress.callback, progress.ctx) catch |err| switch (err) {
                error.GenAborted => return,
                else => {
                    reportProgress(progress.callback, progress.ctx, .dig_hole) catch return;
                    generateIntoDigHole(diff, prng.random(), out, progress.callback, progress.ctx) catch |e| switch (e) {
                        error.GenAborted => return,
                        else => continue,
                    };
                    return;
                },
            };
            return;
        }
    }

    fn playProgressCallback() struct { callback: ?GenProgressFn, ctx: ?*anyopaque } {
        return .{ .callback = play_progress_fn, .ctx = play_progress_ctx };
    }

    /// Fill `out` with an 81-char generated puzzle (digits and `0` blanks).
    /// Fast path: full grid, bulk-clear to a random givens target, one uniqueness check.
    pub fn generateInto(
        diff: Difficulty,
        rng: std.Random,
        out: *[81]u8,
        progress: ?GenProgressFn,
        progress_ctx: ?*anyopaque,
    ) !void {
        if (diff == .default) {
            @memcpy(out, default_str);
            return;
        }
        const range = givensRange(diff);
        const target = rng.intRangeAtMost(usize, range.min, range.max);
        var attempt: u16 = 0;
        while (attempt < 256) : (attempt += 1) {
            try reportProgress(progress, progress_ctx, .{ .attempt = .{ .n = attempt + 1, .max = 256 } });
            var solution: [81]u8 = undefined;
            shuffledSolution(rng, &solution);
            var puzzle = try board.fromFlat(solution, .{ .given_bits = allGivensMask() });
            var order: [81]u8 = undefined;
            for (0..81) |i| order[i] = @intCast(i);
            rng.shuffle(u8, order[0..]);
            const to_clear = order[target..];
            var step: u8 = 0;
            for (to_clear) |idx_usize| {
                const row: u4 = @intCast(@divTrunc(idx_usize, 9));
                const col: u4 = @intCast(@mod(idx_usize, 9));
                puzzle.given_bits &= ~(@as(u128, 1) << @intCast(idx_usize));
                puzzle.setCell(row, col, cell.CellValue.zero) catch unreachable;
                puzzle.refreshConflictsForCell(row, col);
                step +%= 1;
                const g_now = countGivensBoard(&puzzle);
                if (step == 1 or step % 8 == 0 or step == to_clear.len) {
                    try reportProgress(progress, progress_ctx, .{ .carve = .{
                        .givens = g_now,
                        .target = target,
                        .step = step,
                    } });
                }
            }
            if (countGivensBoard(&puzzle) != target) continue;
            const givens = countGivensBoard(&puzzle);
            try reportProgress(progress, progress_ctx, .{ .strip = .{ .givens = givens, .target = target } });
            try reportProgress(progress, progress_ctx, .{ .uniqueness_check = .{ .givens = givens } });
            if (try solver.countSolutions(puzzle, 2) != 1) continue;
            const line = serial.toOneLineString(puzzle);
            @memcpy(out, &line);
            return;
        }
        return error.GenerationFailed;
    }

    /// Uniqueness-preserving carve (slow — for offline batch / bench, not hot path).
    /// Starts at 81 givens and tries removing cells until givens ≤ target, reverting removals that break uniqueness.
    pub fn generateIntoDigHole(
        diff: Difficulty,
        rng: std.Random,
        out: *[81]u8,
        progress: ?GenProgressFn,
        progress_ctx: ?*anyopaque,
    ) !void {
        if (diff == .default) {
            @memcpy(out, default_str);
            return;
        }
        const range = givensRange(diff);
        const target = rng.intRangeAtMost(usize, range.min, range.max);
        var attempt: u8 = 0;
        while (attempt < 16) : (attempt += 1) {
            try reportProgress(progress, progress_ctx, .{ .attempt = .{ .n = @intCast(attempt + 1), .max = 16 } });
            var solution: [81]u8 = undefined;
            shuffledSolution(rng, &solution);
            var puzzle = try board.fromFlat(solution, .{ .given_bits = allGivensMask() });
            var order: [81]u8 = undefined;
            for (0..81) |i| order[i] = @intCast(i);
            rng.shuffle(u8, order[0..]);
            var step: u8 = 0;
            for (order) |idx_usize| {
                if (countGivensBoard(&puzzle) <= target) break;
                const row: u4 = @intCast(@divTrunc(idx_usize, 9));
                const col: u4 = @intCast(@mod(idx_usize, 9));
                const saved_val = puzzle.getCellValue(row, col);
                puzzle.given_bits &= ~(@as(u128, 1) << @intCast(idx_usize));
                puzzle.setCell(row, col, cell.CellValue.zero) catch unreachable;
                puzzle.refreshConflictsForCell(row, col);
                step +%= 1;
                const givens_now = countGivensBoard(&puzzle);
                try reportProgress(progress, progress_ctx, .{ .carve = .{
                    .givens = givens_now,
                    .target = target,
                    .step = step,
                } });
                try reportProgress(progress, progress_ctx, .{ .uniqueness_check = .{ .givens = givens_now } });
                const solutions = try solver.countSolutions(puzzle, 2);
                if (solutions != 1) {
                    puzzle.setCell(row, col, saved_val) catch unreachable;
                    puzzle.given_bits |= @as(u128, 1) << @intCast(idx_usize);
                    puzzle.refreshConflictsForCell(row, col);
                }
            }
            const givens = countGivensBoard(&puzzle);
            if (givens < range.min or givens > range.max) continue;
            try reportProgress(progress, progress_ctx, .{ .uniqueness_check = .{ .givens = givens } });
            if (try solver.countSolutions(puzzle, 2) != 1) continue;
            const line = serial.toOneLineString(puzzle);
            @memcpy(out, &line);
            return;
        }
        return error.GenerationFailed;
    }
};

pub const GenerationFailed = error{GenerationFailed};
pub const GenAborted = error{GenAborted};

/// Optional progress for bench, verify-slow, and live play (`setPlayProgress`).
pub const GenProgressEvent = union(enum) {
    /// New outer seed in `generateForPlay` (counts restart here).
    round,
    /// Fast batch failed; carving with uniqueness checks this round.
    dig_hole,
    attempt: struct { n: u16, max: u16 },
    /// Fast path: bulk-removed down to `givens` (target band uses `target`).
    strip: struct { givens: usize, target: usize },
    /// Dig-hole: givens while carving down toward `target`.
    carve: struct { givens: usize, target: usize, step: u8 },
    /// Imminent `countSolutions` — usually the slow stretch.
    uniqueness_check: struct { givens: usize },
};

pub const GenProgressFn = *const fn (event: GenProgressEvent, ctx: ?*anyopaque) void;

fn reportProgress(progress: ?GenProgressFn, ctx: ?*anyopaque, event: GenProgressEvent) GenAborted!void {
    if (PuzzleGen.checkPlayAbort()) return error.GenAborted;
    if (progress) |cb| cb(event, ctx);
    if (PuzzleGen.checkPlayAbort()) return error.GenAborted;
}

/// Compact `(phase, a, b)` for wasm host import — keep in sync with `formatGenProgress` in gen_progress_format.js.
pub fn encodeProgressWire(event: GenProgressEvent) struct { phase: u32, a: u32, b: u32 } {
    return switch (event) {
        .round => .{ .phase = 0, .a = 0, .b = 0 },
        .dig_hole => .{ .phase = 1, .a = 0, .b = 0 },
        .attempt => |x| .{ .phase = 2, .a = x.n, .b = x.max },
        .strip => |s| .{ .phase = 3, .a = @intCast(s.givens), .b = @intCast(s.target) },
        .carve => |c| .{ .phase = 4, .a = @intCast(c.givens), .b = @intCast(c.target) },
        .uniqueness_check => |u| .{ .phase = 5, .a = @intCast(u.givens), .b = 0 },
    };
}

pub fn formatProgressEvent(event: GenProgressEvent, buf: []u8) ?[]const u8 {
    return switch (event) {
        .round => std.fmt.bufPrint(buf, "Generating: new attempt…", .{}) catch null,
        .dig_hole => std.fmt.bufPrint(buf, "Generating: carving clues…", .{}) catch null,
        .attempt => |x| std.fmt.bufPrint(buf, "Generating: try {d}/{d}", .{ x.n, x.max }) catch null,
        .strip => |s| std.fmt.bufPrint(buf, "Generating: {d} givens (target ≤{d})", .{ s.givens, s.target }) catch null,
        .carve => |c| std.fmt.bufPrint(buf, "Generating: {d} givens → ≤{d}", .{ c.givens, c.target }) catch null,
        .uniqueness_check => |u| std.fmt.bufPrint(buf, "Generating: checking uniqueness ({d} givens)…", .{u.givens}) catch null,
    };
}

fn givensRange(diff: Difficulty) struct { min: usize, max: usize } {
    return switch (diff) {
        .easy => .{ .min = 36, .max = 45 },
        .medium => .{ .min = 28, .max = 35 },
        .hard => .{ .min = 20, .max = 27 },
        .default => unreachable,
    };
}

fn allGivensMask() u128 {
    return (@as(u128, 1) << board.CELL_COUNT) - 1;
}

fn countGivensBoard(b: *const board.Board) usize {
    return @popCount(b.given_bits & allGivensMask());
}

fn shuffledSolution(rng: std.Random, out: *[81]u8) void {
    var digits: [9]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    rng.shuffle(u8, digits[0..]);
    var grid: [81]u8 = undefined;
    for (base_solution, 0..) |ch, i| grid[i] = digits[@intCast(ch - '1')];

    var band_order: [3]u8 = .{ 0, 1, 2 };
    rng.shuffle(u8, band_order[0..]);
    var row_in_band: [3][3]u8 = .{ .{ 0, 1, 2 }, .{ 0, 1, 2 }, .{ 0, 1, 2 } };
    for (&row_in_band) |*band| rng.shuffle(u8, band[0..]);
    var row_perm: [81]u8 = undefined;
    for (0..3) |new_band| {
        const old_band = band_order[new_band];
        for (0..3) |new_lr| {
            const old_lr = row_in_band[old_band][new_lr];
            const old_row = old_band * 3 + old_lr;
            const new_row = new_band * 3 + new_lr;
            for (0..9) |c| row_perm[new_row * 9 + c] = grid[old_row * 9 + c];
        }
    }

    var stack_order: [3]u8 = .{ 0, 1, 2 };
    rng.shuffle(u8, stack_order[0..]);
    var col_in_stack: [3][3]u8 = .{ .{ 0, 1, 2 }, .{ 0, 1, 2 }, .{ 0, 1, 2 } };
    for (&col_in_stack) |*stack| rng.shuffle(u8, stack[0..]);
    for (0..9) |r| {
        for (0..3) |new_stack| {
            const old_stack = stack_order[new_stack];
            for (0..3) |new_lc| {
                const old_lc = col_in_stack[old_stack][new_lc];
                const old_col = old_stack * 3 + old_lc;
                const new_col = new_stack * 3 + new_lc;
                out[r * 9 + new_col] = row_perm[r * 9 + old_col];
            }
        }
    }
}

/// Return the number of given cells in a one-line string.
pub fn countGivens(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch != '.' and ch != '0') n += 1;
    }
    return n;
}

test "puzzle_gen: fixture strings are exactly 81 chars" {
    try std.testing.expectEqual(81, PuzzleGen.default().len);
    try std.testing.expectEqual(81, PuzzleGen.easy().len);
    try std.testing.expectEqual(81, PuzzleGen.medium().len);
    try std.testing.expectEqual(81, PuzzleGen.hard().len);
}

test "puzzle_gen: fixture puzzles load into Board" {
    _ = try board.fromOneLineString(PuzzleGen.default());
    _ = try board.fromOneLineString(PuzzleGen.easy());
    _ = try board.fromOneLineString(PuzzleGen.medium());
    _ = try board.fromOneLineString(PuzzleGen.hard());
}

test "puzzle_gen: default generate stays on legacy fixture" {
    try std.testing.expectEqualStrings(PuzzleGen.default(), PuzzleGen.generate(.default));
}

test "puzzle_gen: formatProgressEvent covers carve" {
    var buf: [64]u8 = undefined;
    const msg = formatProgressEvent(.{ .carve = .{ .givens = 42, .target = 36, .step = 3 } }, &buf).?;
    try std.testing.expectEqualStrings("Generating: 42 givens → ≤36", msg);
}

test "puzzle_gen: generate uses fixtures in test binary" {
    try std.testing.expectEqualStrings(PuzzleGen.easy(), PuzzleGen.generate(.easy));
    try std.testing.expectEqualStrings(PuzzleGen.medium(), PuzzleGen.generate(.medium));
    try std.testing.expectEqualStrings(PuzzleGen.hard(), PuzzleGen.generate(.hard));
}

test "puzzle_gen: encodeProgressWire covers all phases" {
    const events = [_]GenProgressEvent{
        .round,
        .dig_hole,
        .{ .attempt = .{ .n = 2, .max = 16 } },
        .{ .strip = .{ .givens = 40, .target = 36 } },
        .{ .carve = .{ .givens = 35, .target = 30, .step = 7 } },
        .{ .uniqueness_check = .{ .givens = 28 } },
    };
    const expected = [_]struct { phase: u32, a: u32, b: u32 }{
        .{ .phase = 0, .a = 0, .b = 0 },
        .{ .phase = 1, .a = 0, .b = 0 },
        .{ .phase = 2, .a = 2, .b = 16 },
        .{ .phase = 3, .a = 40, .b = 36 },
        .{ .phase = 4, .a = 35, .b = 30 },
        .{ .phase = 5, .a = 28, .b = 0 },
    };
    for (events, expected) |ev, want| {
        const got = encodeProgressWire(ev);
        try std.testing.expectEqual(want.phase, got.phase);
        try std.testing.expectEqual(want.a, got.a);
        try std.testing.expectEqual(want.b, got.b);
    }
}

test "puzzle_gen: formatProgressEvent covers all variants" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Generating: new attempt…", formatProgressEvent(.round, &buf).?);
    try std.testing.expectEqualStrings("Generating: carving clues…", formatProgressEvent(.dig_hole, &buf).?);
    try std.testing.expectEqualStrings("Generating: try 4/16", formatProgressEvent(.{ .attempt = .{ .n = 4, .max = 16 } }, &buf).?);
    try std.testing.expectEqualStrings("Generating: 41 givens (target ≤36)", formatProgressEvent(.{ .strip = .{ .givens = 41, .target = 36 } }, &buf).?);
    try std.testing.expectEqualStrings("Generating: 33 givens → ≤28", formatProgressEvent(.{ .carve = .{ .givens = 33, .target = 28, .step = 9 } }, &buf).?);
    try std.testing.expectEqualStrings(
        "Generating: checking uniqueness (27 givens)…",
        formatProgressEvent(.{ .uniqueness_check = .{ .givens = 27 } }, &buf).?,
    );
}

test "puzzle_gen: countGivens counts digits and ignores dot/zero" {
    try std.testing.expectEqual(@as(usize, 4), countGivens("1.2030004"));
    try std.testing.expectEqual(@as(usize, 0), countGivens("...000..."));
}

fn testProgressSink(_: GenProgressEvent, ctx: ?*anyopaque) void {
    if (ctx) |p| {
        const n: *usize = @ptrCast(@alignCast(p));
        n.* += 1;
    }
}

fn testRoundEventCounter(event: GenProgressEvent, ctx: ?*anyopaque) void {
    const n: *usize = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .round => n.* += 1,
        else => {},
    }
}

fn testAbortNow(_: ?*anyopaque) bool {
    return true;
}

fn testAbortAfterOne(ctx: ?*anyopaque) bool {
    const n: *usize = @ptrCast(@alignCast(ctx.?));
    n.* += 1;
    return n.* >= 2;
}

fn testAbortAfterTwo(ctx: ?*anyopaque) bool {
    const n: *usize = @ptrCast(@alignCast(ctx.?));
    n.* += 1;
    return n.* >= 3;
}

test "puzzle_gen: generateInto default returns legacy fixture line" {
    var out: [81]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(12345);
    try PuzzleGen.generateInto(.default, prng.random(), &out, null, null);
    try std.testing.expectEqualStrings(default_str, &out);
}

test "puzzle_gen: generateInto and dig-hole honor cooperative abort quickly" {
    var out_fast: [81]u8 = undefined;
    var out_dig: [81]u8 = undefined;
    var prng_fast = std.Random.DefaultPrng.init(42);
    var prng_dig = std.Random.DefaultPrng.init(1337);

    PuzzleGen.setPlayAbort(testAbortNow, null);
    const fast = PuzzleGen.generateInto(.hard, prng_fast.random(), &out_fast, null, null);
    try std.testing.expectError(error.GenAborted, fast);

    const dig = PuzzleGen.generateIntoDigHole(.hard, prng_dig.random(), &out_dig, null, null);
    try std.testing.expectError(error.GenAborted, dig);
    try std.testing.expect(PuzzleGen.takePlayAborted());
    PuzzleGen.setPlayAbort(null, null);
}

test "puzzle_gen: reportProgress and play abort paths latch aborted state" {
    var calls: usize = 0;
    PuzzleGen.setPlayAbort(testAbortNow, null);
    try std.testing.expectError(error.GenAborted, reportProgress(testProgressSink, @ptrCast(&calls), .round));
    try std.testing.expect(PuzzleGen.takePlayAborted());

    calls = 0;
    var abort_polls: usize = 0;
    PuzzleGen.setPlayAbort(testAbortAfterOne, @ptrCast(&abort_polls));
    try std.testing.expectError(
        error.GenAborted,
        reportProgress(testProgressSink, @ptrCast(&calls), .{ .attempt = .{ .n = 1, .max = 2 } }),
    );
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(PuzzleGen.takePlayAborted());
    try std.testing.expect(!PuzzleGen.takePlayAborted());
    PuzzleGen.setPlayAbort(null, null);
}

test "puzzle_gen: reportProgress without callback returns when abort is disabled" {
    PuzzleGen.setPlayAbort(null, null);
    try reportProgress(null, null, .dig_hole);
}

test "puzzle_gen: generateForPlay reports round and exits on cooperative abort" {
    var out: [81]u8 = undefined;
    var rounds: usize = 0;
    var abort_polls: usize = 0;
    PuzzleGen.setPlayProgress(testRoundEventCounter, @ptrCast(&rounds));
    PuzzleGen.setPlayAbort(testAbortAfterTwo, @ptrCast(&abort_polls));
    PuzzleGen.generateForPlay(.hard, &out);
    try std.testing.expect(rounds >= 1);
    try std.testing.expect(PuzzleGen.takePlayAborted());
    PuzzleGen.setPlayProgress(null, null);
    PuzzleGen.setPlayAbort(null, null);
}
