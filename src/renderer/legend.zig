//! Legend printer — formats disambiguation entries into a single-line legend string.
//!
//! Example: "(F)ill (C)lear (U)ndo (R)edo (Q)uit"

const std = @import("std");
const mem = std.mem;
const disambiguate = @import("ascii/disambiguate.zig");

const command = @import("../command.zig");

/// Legend entity — which commands are displayable in the current game state.
pub const Legend = struct {
    fill: bool,
    clear: bool,
    quit: bool,
    undo: bool,
    redo: bool,
    save: bool,
    open: bool,
    new: bool,
    save_as: bool,

    /// Fill `names` with the active command labels and return the count.
    /// Caller owns the buffer; the strings point at comptime literals.
    pub fn getNames(self: Legend, names: *[9][]const u8) usize {
        var count: usize = 0;
        if (self.fill) {
            names[count] = command.getName(.fill);
            count += 1;
        }
        if (self.clear) {
            names[count] = command.getName(.clear);
            count += 1;
        }
        if (self.quit) {
            names[count] = command.getName(.quit);
            count += 1;
        }
        if (self.undo) {
            names[count] = command.getName(.undo);
            count += 1;
        }
        if (self.redo) {
            names[count] = command.getName(.redo);
            count += 1;
        }
        if (self.save) {
            names[count] = command.getName(.save);
            count += 1;
        }
        if (self.open) {
            names[count] = command.getName(.open);
            count += 1;
        }
        if (self.new) {
            names[count] = command.getName(.new);
            count += 1;
        }
        if (self.save_as) {
            names[count] = command.getName(.save_as);
            count += 1;
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Public API

/// Format a list of disambiguation entries into a single-line legend string.
/// Each entry becomes "(PREFIX)rest_of_name" joined by spaces.
/// Caller must free the returned string.
pub fn formatLegend(allocator: mem.Allocator, entries: []const disambiguate.DisambigEntry) mem.Allocator.Error![]u8 {
    if (entries.len == 0) return allocator.dupe(u8, "");

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    for (0..entries.len) |i| {
        const entry = entries[i];
        const cmd = entry.command;
        const plen = @min(entry.prefix_len, cmd.len);

        try list.append(allocator, '(');
        try list.appendSlice(allocator, cmd[0..plen]);
        try list.append(allocator, ')');
        if (plen < cmd.len) {
            try list.appendSlice(allocator, cmd[plen..]);
        }

        if (i + 1 < entries.len) {
            try list.append(allocator, ' ');
        }
    }

    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests (co-located)
// ---------------------------------------------------------------------------

test "formatLegend: five non-colliding commands → each prefix is 1 char" {
    const allocator = std.testing.allocator;

    const entries: []const disambiguate.DisambigEntry = &[_]disambiguate.DisambigEntry{
        .{ .command = command.getName(.fill), .prefix_len = 1 },
        .{ .command = command.getName(.clear), .prefix_len = 1 },
        .{ .command = command.getName(.undo), .prefix_len = 1 },
        .{ .command = command.getName(.redo), .prefix_len = 1 },
        .{ .command = command.getName(.quit), .prefix_len = 1 },
    };

    const result = try formatLegend(allocator, entries);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "(F)ill (C)lear (U)ndo (R)edo (Q)uit",
        result,
    );
}

test "formatLegend: hump-seed collision Save vs SaveAs" {
    const allocator = std.testing.allocator;

    const entries: []const disambiguate.DisambigEntry = &[_]disambiguate.DisambigEntry{
        .{ .command = command.getName(.save), .prefix_len = 1 },
        .{ .command = "SaveAs", .prefix_len = 2 },
    };

    const result = try formatLegend(allocator, entries);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("(S)ave (Sa)veAs", result);
}

test "formatLegend: empty list returns empty string" {
    const allocator = std.testing.allocator;

    const entries: []const disambiguate.DisambigEntry = &[_]disambiguate.DisambigEntry{};

    const result = try formatLegend(allocator, entries);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "formatLegend: single command returns parenthesized name" {
    const allocator = std.testing.allocator;

    const entries: []const disambiguate.DisambigEntry = &[_]disambiguate.DisambigEntry{
        .{ .command = command.getName(.quit), .prefix_len = 1 },
    };

    const result = try formatLegend(allocator, entries);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("(Q)uit", result);
}

test "formatLegend: prefix_len equals command length → whole word in parens" {
    const allocator = std.testing.allocator;

    // When a collision pushes prefix_len to the full command length
    const entries: []const disambiguate.DisambigEntry = &[_]disambiguate.DisambigEntry{
        .{ .command = command.getName(.fill), .prefix_len = 4 },
    };

    const result = try formatLegend(allocator, entries);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("(Fill)", result);
}

test "formatLegend: redo alone on R vs competing → dynamic prefix shift" {
    const allocator = std.testing.allocator;

    // When Redo is alone on 'R': prefix_len=1 → (R)edo
    const solo_entries: []const disambiguate.DisambigEntry = &[_]disambiguate.DisambigEntry{
        .{ .command = command.getName(.fill), .prefix_len = 1 },
        .{ .command = command.getName(.clear), .prefix_len = 1 },
        .{ .command = command.getName(.undo), .prefix_len = 1 },
        .{ .command = command.getName(.redo), .prefix_len = 1 },
        .{ .command = command.getName(.quit), .prefix_len = 1 },
    };

    {
        const result = try formatLegend(allocator, solo_entries);
        defer allocator.free(result);

        // Should contain "(R)edo" when prefix_len is 1
        try std.testing.expect(std.mem.indexOf(u8, result, "(R)edo") != null);
    }

    // When Recents joins: Redo needs prefix_len=2 → (RE)do
    const competing_entries: []const disambiguate.DisambigEntry = &[_]disambiguate.DisambigEntry{
        .{ .command = command.getName(.fill), .prefix_len = 1 },
        .{ .command = command.getName(.clear), .prefix_len = 1 },
        .{ .command = command.getName(.undo), .prefix_len = 1 },
        .{ .command = command.getName(.redo), .prefix_len = 2 }, // needs RE now
        .{ .command = command.getName(.quit), .prefix_len = 1 },
    };

    {
        const result = try formatLegend(allocator, competing_entries);
        defer allocator.free(result);

        // Redo should show (Re)do when prefix_len is 2
        try std.testing.expect(std.mem.indexOf(u8, result, "(Re)do") != null);
    }
}
