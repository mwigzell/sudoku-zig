const std = @import("std");
const cell = @import("../board/cell.zig");

/// Records one player mutation (fill or clear) so it can be undone/redone.
pub const MutationEntry = struct {
    row: u4,
    col: u4,
    old_value: cell.CellValue,
    new_value: cell.CellValue,
};

/// Mutable list of mutation entries with a forward pointer for undo/redo.
pub const MutationHistory = struct {
    entries: std.ArrayList(MutationEntry),
    pointer: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{
            .entries = .empty,
            .pointer = 0,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.entries.deinit(self.gpa);
    }

    /// Number of committed mutations.
    pub fn count(self: *const @This()) usize {
        return self.pointer;
    }

    /// Append a mutation, advancing pointer past it.
    pub fn push(self: *@This(), row: u4, col: u4, old_value: cell.CellValue, new_value: cell.CellValue) !void {
        try self.entries.append(self.gpa, .{
            .row = row,
            .col = col,
            .old_value = old_value,
            .new_value = new_value,
        });
        self.pointer = self.entries.items.len;
    }

    /// Return the entry just before pointer (last committed mutation). Returns null if none.
    pub fn peakPast(self: *const @This()) ?MutationEntry {
        if (self.pointer == 0) return null;
        return self.entries.items[self.pointer - 1];
    }

    /// Discard future entries that are stale after an undo followed by a new mutation.
    pub fn truncateFuture(self: *@This()) void {
        if (self.pointer < self.entries.items.len) {
            self.entries.shrinkRetainingCapacity(self.pointer);
        }
    }
};

// ── MutationHistory unit tests (co-located, Step 2) ──────────────

test "MutationHistory: initially empty" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    try std.testing.expectEqual(@as(usize, 0), h.count());
}

test "MutationHistory: push and count" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    _ = h.push(2, 5, .three, .seven) catch unreachable;
    _ = h.push(4, 1, .zero, .one) catch unreachable;

    try std.testing.expectEqual(@as(usize, 2), h.count());
}

test "MutationHistory: peakPast returns last committed" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    _ = h.push(0, 3, .zero, .eight) catch unreachable;
    _ = h.push(1, 2, .five, .nine) catch unreachable;

    const item = h.peakPast() orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u4, 1), item.row);
    try std.testing.expectEqual(@as(u4, 2), item.col);
    try std.testing.expectEqual(cell.CellValue.five, item.old_value);
    try std.testing.expectEqual(cell.CellValue.nine, item.new_value);
}

test "MutationHistory: peakPast returns null when empty" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    try std.testing.expect(h.peakPast() == null);
}
