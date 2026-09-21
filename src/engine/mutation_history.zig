// Undo/redo history: mutation entries with a forward pointer over them.
const std = @import("std");
const cell = @import("../board/cell.zig");

/// One player fill or clear.
pub const CellMutation = struct {
    row: u4,
    col: u4,
    old_value: cell.CellValue,
    new_value: cell.CellValue,
};

/// Board before a solve. Redo re-runs the solver from this snapshot.
pub const BoardSnapshot = struct {
    given_bits: u128,
    flat: [81]u8,
};

/// A history step is either one cell edit or one solve.
pub const MutationEntry = union(enum) {
    cell: CellMutation,
    solve_batch: BoardSnapshot,
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

    /// Append a cell mutation, advancing pointer past it.
    pub fn push(self: *@This(), row: u4, col: u4, old_value: cell.CellValue, new_value: cell.CellValue) !void {
        try self.entries.append(self.gpa, .{ .cell = .{
            .row = row,
            .col = col,
            .old_value = old_value,
            .new_value = new_value,
        } });
        self.pointer = self.entries.items.len;
    }

    /// Append one solve step. Only the before-snapshot is stored.
    pub fn pushSolve(self: *@This(), before: BoardSnapshot) !void {
        try self.entries.append(self.gpa, .{ .solve_batch = before });
        self.pointer = self.entries.items.len;
    }

    /// Return the entry just before pointer (last committed mutation). Returns null if none.
    pub fn peekPast(self: *const @This()) ?MutationEntry {
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

// ────────────────────── co-located tests ──────────────────────

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

test "MutationHistory: peekPast returns last committed" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    _ = h.push(0, 3, .zero, .eight) catch unreachable;
    _ = h.push(1, 2, .five, .nine) catch unreachable;

    const item = h.peekPast() orelse return error.TestFailed;
    const c = item.cell;
    try std.testing.expectEqual(@as(u4, 1), c.row);
    try std.testing.expectEqual(@as(u4, 2), c.col);
    try std.testing.expectEqual(cell.CellValue.five, c.old_value);
    try std.testing.expectEqual(cell.CellValue.nine, c.new_value);
}

test "MutationHistory: peekPast returns null when empty" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    try std.testing.expect(h.peekPast() == null);
}

test "MutationHistory: push stores a cell and pushSolve stores one before snapshot" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    try h.push(0, 2, .zero, .seven);
    var flat: [81]u8 = @splat(0);
    flat[0] = 4;
    try h.pushSolve(.{ .given_bits = 1, .flat = flat });

    switch (h.entries.items[0]) {
        .cell => |c| {
            try std.testing.expectEqual(@as(u4, 0), c.row);
            try std.testing.expectEqual(@as(u4, 2), c.col);
            try std.testing.expectEqual(cell.CellValue.zero, c.old_value);
            try std.testing.expectEqual(cell.CellValue.seven, c.new_value);
        },
        .solve_batch => return error.TestFailed,
    }
    switch (h.entries.items[1]) {
        .solve_batch => |snap| {
            try std.testing.expectEqual(@as(u128, 1), snap.given_bits);
            try std.testing.expectEqual(@as(u8, 4), snap.flat[0]);
        },
        .cell => return error.TestFailed,
    }
    try std.testing.expectEqual(@as(usize, 2), h.count());
}
