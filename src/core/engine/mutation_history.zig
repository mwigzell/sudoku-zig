// Undo/redo history: mutation entries with a forward pointer over them.
const std = @import("std");
const cell = @import("../board/cell.zig");
const board = @import("../board/board.zig");

/// One player fill or clear, with the marks it removed so Undo can put them back.
pub const CellMutation = struct {
    row: u4,
    col: u4,
    old_value: cell.CellValue,
    new_value: cell.CellValue,
    old_marks: board.MarkSet = 0, // the cell's own marks before the edit
    cleared_peers: board.CellMask = 0, // cells that lost their mark for new_value
};

/// Board before a solve. Redo re-runs the solver from this snapshot.
pub const BoardSnapshot = struct {
    given_bits: board.CellMask,
    flat: [81]u8,
};

/// One pencil-mark toggle. `old_value` is the player digit the mark replaced, or zero.
pub const MarkToggle = struct {
    row: u4,
    col: u4,
    digit: cell.CellValue,
    old_value: cell.CellValue,
};

/// A history step: one cell edit, one solve, or one mark toggle.
pub const MutationEntry = union(enum) {
    cell: CellMutation,
    solve_batch: BoardSnapshot,
    mark: MarkToggle,
};

/// Mutable list of mutation entries with a forward pointer for undo/redo.
pub const MutationHistory = struct {
    entries: std.ArrayList(MutationEntry),
    pointer: usize,
    gpa: std.mem.Allocator,

    /// Create an empty history with pointer at 0.
    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{
            .entries = .empty,
            .pointer = 0,
            .gpa = gpa,
        };
    }

    /// Free history entry storage.
    pub fn deinit(self: *@This()) void {
        self.entries.deinit(self.gpa);
    }

    /// Number of committed mutations.
    pub fn count(self: *const @This()) usize {
        return self.pointer;
    }

    /// Append a cell mutation, advancing pointer past it.
    pub fn pushCell(self: *@This(), m: CellMutation) !void {
        try self.entries.append(self.gpa, .{ .cell = m });
        self.pointer = self.entries.items.len;
    }

    /// Append one solve step. Only the before-snapshot is stored.
    pub fn pushSolve(self: *@This(), before: BoardSnapshot) !void {
        try self.entries.append(self.gpa, .{ .solve_batch = before });
        self.pointer = self.entries.items.len;
    }

    /// Append one mark toggle, advancing pointer past it.
    pub fn pushMark(self: *@This(), m: MarkToggle) !void {
        try self.entries.append(self.gpa, .{ .mark = m });
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

    _ = h.pushCell(.{ .row = 2, .col = 5, .old_value = .three, .new_value = .seven }) catch unreachable;
    _ = h.pushCell(.{ .row = 4, .col = 1, .old_value = .zero, .new_value = .one }) catch unreachable;

    try std.testing.expectEqual(@as(usize, 2), h.count());
}

test "MutationHistory: peekPast returns last committed" {
    var h = MutationHistory.init(std.testing.allocator);
    defer h.deinit();

    _ = h.pushCell(.{ .row = 0, .col = 3, .old_value = .zero, .new_value = .eight }) catch unreachable;
    _ = h.pushCell(.{ .row = 1, .col = 2, .old_value = .five, .new_value = .nine }) catch unreachable;

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

    try h.pushCell(.{ .row = 0, .col = 2, .old_value = .zero, .new_value = .seven });
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
        .solve_batch, .mark => return error.TestFailed,
    }
    switch (h.entries.items[1]) {
        .solve_batch => |snap| {
            try std.testing.expectEqual(@as(board.CellMask, 1), snap.given_bits);
            try std.testing.expectEqual(@as(u8, 4), snap.flat[0]);
        },
        .cell, .mark => return error.TestFailed,
    }
    try std.testing.expectEqual(@as(usize, 2), h.count());
}
