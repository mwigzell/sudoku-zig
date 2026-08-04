//! Prefix disambiguation module.
//! Computes the minimum unique prefix length for each command in a set,
//! so that typing just the parenthesized legend portion uniquely identifies intent.

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const parse = @import("parse.zig");


/// Maximum number of capital letters in any command string.
const MAX_HUMPS: usize = 32;

/// One entry in the disambiguation result: original command and its minimum prefix length.
pub const DisambigEntry = struct {
    /// The canonical command name (properly-capitalized).
    command: []const u8,
    /// Number of characters needed to uniquely identify this command.
    prefix_len: usize,
};

/// Compute the minimum unique prefix for each command in `commands`.
/// Uses pairwise first-differ logic with hump-seed fallback for proper-prefix collisions.
pub fn getMinimumPrefixes(
    allocator: mem.Allocator,
    commands: []const []const u8,
) AllocatorError![]DisambigEntry {
    const count = commands.len;
    var result: []DisambigEntry = try allocator.alloc(DisambigEntry, count);

    // Start every command at prefix_len 1; bump up as clashes are found.
    var prefix_lens: [64]usize = undefined;
    for (0..count) |i| {
        prefix_lens[i] = 1;
    }

    // Pairwise comparison
    for (0..count) |i| {
        for (0..count) |j| {
            if (i == j) continue;
            const clash_pos = pairCollision(commands[i], commands[j]);
            if (clash_pos > prefix_lens[i]) {
                prefix_lens[i] = clash_pos;
            }
        }
    }

    // Build result entries
    for (0..count) |i| {
        result[i] = .{
            .command = commands[i],
            .prefix_len = prefix_lens[i],
        };
    }

    return result;
}

/// Collision depth between two commands.
/// Uses hump-seed (proper subset) or normal pairwise first-differ.
fn pairCollision(a: []const u8, b: []const u8) usize {
    var a_humps: [MAX_HUMPS]u8 = undefined;
    var b_humps: [MAX_HUMPS]u8 = undefined;
    const a_count = collectHumps(a, &a_humps);
    const b_count = collectHumps(b, &b_humps);
    const a_subset_b = isSubsetChars(a_humps[0..a_count], b_humps[0..b_count]);
    const b_subset_a = isSubsetChars(b_humps[0..b_count], a_humps[0..a_count]);

    // Hump-seed: only apply when both strings have capitals (avoids empty-set
    // trivial match) and one form's capitals are a proper subset of the other — meaning
    // they collide as a proper-prefix pair.  Return the form being evaluated (a) so we never
    // bump it above its own capital count.
    if (a_count > 0 and b_count > 0 and a_subset_b and a_count < b_count) {
        return a_count;
    }
    // Reverse direction: a has more capitals, b is the shorter form — hump-seed 'a' too.
    if (a_count > 0 and b_count > 0 and b_subset_a and a_count > b_count) {
        return a_count;
    }

    // Normal pairwise first-differ on lowercase.
    return lowerCaseFirstDiffer(a, b);
}

/// Collect capital-letter characters from `s` into `out`. Returns count.
fn collectHumps(s: []const u8, out: *[MAX_HUMPS]u8) usize {
    var count: usize = 0;
    for (s) |c| {
        if (ascii.isUpper(c)) {
            out[count] = c;
            count += 1;
        }
    }
    return count;
}

/// Returns true if every char in `a` appears somewhere in `b`.
fn isSubsetChars(a: []u8, b: []u8) bool {
    for (a) |ch| {
        var found = false;
        for (b) |other| {
            if (other == ch) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Position at which `a` and `b` first differ (case-insensitive).
/// If one is a proper prefix of the other, returns len(shorter) + 1.
fn lowerCaseFirstDiffer(a: []const u8, b: []const u8) usize {
    const len = @min(a.len, b.len);
    for (0..len) |k| {
        if (ascii.toLower(a[k]) != ascii.toLower(b[k])) {
            return k;
        }
    }
    return len + 1;
}

/// Possible allocation failures.
pub const AllocatorError = mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "getMinimumPrefixes: five non-colliding commands each get length 1" {
    const allocator = std.testing.allocator;

    const cmds = &[_][]const u8{ parse.CommandNames.fill, parse.CommandNames.clear, parse.CommandNames.undo, parse.CommandNames.redo, parse.CommandNames.quit };
    const result = try getMinimumPrefixes(allocator, cmds);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    for (result) |entry| {
        try std.testing.expectEqual(@as(usize, 1), entry.prefix_len);
    }
}

test "getMinimumPrefixes: hump-seed collision Save vs SaveAs" {
    const allocator = std.testing.allocator;

    const cmds = &[_][]const u8{ parse.CommandNames.save, "SaveAs" };
    const result = try getMinimumPrefixes(allocator, cmds);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    // Save → (S)ave  → prefix_len 1 (one capital 'S')
    try std.testing.expectEqualStrings(parse.CommandNames.save, result[0].command);
    // SaveAs → (SA)veAs  → prefix_len 2 (two capitals 'SA')
    try std.testing.expectEqualStrings("SaveAs", result[1].command);
    try std.testing.expectEqual(@as(usize, 2), result[1].prefix_len);
}

test "getMinimumPrefixes: single-command list returns length-1 prefix" {
    const allocator = std.testing.allocator;

    const cmds = &[_][]const u8{ parse.CommandNames.quit };
    const result = try getMinimumPrefixes(allocator, cmds);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings(parse.CommandNames.quit, result[0].command);
}

test "getMinimumPrefixes: case-insensitive inputs" {
    const allocator = std.testing.allocator;

    const cmds = &[_][]const u8{ "fill", "CLEAR", "uNdO" };
    const result = try getMinimumPrefixes(allocator, cmds);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    for (result) |entry| {
        try std.testing.expectEqual(@as(usize, 1), entry.prefix_len);
    }
}

test "getMinimumPrefixes: empty list returns empty result" {
    const allocator = std.testing.allocator;

    const cmds = &[_][]const u8{};
    const result = try getMinimumPrefixes(allocator, cmds);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}
