// JSON wire types for the wasm export boundary — bootstrap config and board snapshot.
const std = @import("std");
const board = @import("../board/board.zig");
const puzzle_gen = @import("../puzzle_gen.zig");
const logger = @import("../logger.zig");

/// Player-facing difficulty on the wasm boundary — explicit u8 wire values, no `.default`.
pub const PlayerDifficulty = enum(u8) {
    easy = 1,
    medium = 2,
    hard = 3,

    pub fn fromWire(n: u8) ?PlayerDifficulty {
        return switch (n) {
            1 => .easy,
            2 => .medium,
            3 => .hard,
            else => null,
        };
    }

    pub fn toPuzzleDifficulty(self: PlayerDifficulty) puzzle_gen.Difficulty {
        return switch (self) {
            .easy => .easy,
            .medium => .medium,
            .hard => .hard,
        };
    }
};

/// Bootstrap payload for wasm `init` — subset of native Config crossing the boundary.
pub const BootstrapConfig = struct {
    difficulty: PlayerDifficulty,
    log_level: logger.Severity = .info,

    pub fn fromWire(difficulty: u8, log_level: u8) ?BootstrapConfig {
        const pd = PlayerDifficulty.fromWire(difficulty) orelse return null;
        const ll: logger.Severity = switch (log_level) {
            0 => .debug,
            1 => .info,
            2 => .warn,
            3 => .err,
            4 => .fatal,
            else => return null,
        };
        return .{ .difficulty = pd, .log_level = ll };
    }
};

/// Serializable display twin of one board cell.
pub const CellSnapshot = struct {
    value: u8,
    given: bool,
    conflict: bool,
};

/// Serializable display twin of `BoardView` — value, given, and conflict per cell.
pub const GameSnapshot = struct {
    cells: [board.CELL_COUNT]CellSnapshot,

    pub fn fromView(view: board.Board.BoardView) GameSnapshot {
        var snap: GameSnapshot = undefined;
        for (0..board.DIMENSION_SIZE) |r_u| {
            const row: u4 = @intCast(r_u);
            for (0..board.DIMENSION_SIZE) |c_u| {
                const col: u4 = @intCast(c_u);
                const idx = @as(usize, @intCast(row)) * board.DIMENSION_SIZE + @as(usize, @intCast(col));
                snap.cells[idx] = .{
                    .value = @backingInt(view.get(row, col)),
                    .given = view.isGiven(row, col),
                    .conflict = view.isConflictingRowCol(row, col),
                };
            }
        }
        return snap;
    }

    pub fn eql(self: GameSnapshot, other: GameSnapshot) bool {
        return std.mem.eql(u8, std.mem.asBytes(&self.cells), std.mem.asBytes(&other.cells));
    }
};

const JsonCell = struct {
    value: u8,
    given: bool,
    conflict: bool,
};

const JsonSnapshot = struct {
    cells: [board.CELL_COUNT]JsonCell,
};

/// Serialize a snapshot to a heap-owned JSON string.
pub fn serializeSnapshot(allocator: std.mem.Allocator, snap: GameSnapshot) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try aw.writer.print("{{\"cells\":[", .{});
    for (snap.cells, 0..) |cell, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print(
            "{{\"value\":{d},\"given\":{any},\"conflict\":{any}}}",
            .{ cell.value, cell.given, cell.conflict },
        );
    }
    try aw.writer.writeAll("]}");
    var list = aw.toArrayList();
    return list.toOwnedSlice(allocator);
}

/// Parse a JSON snapshot produced by `serializeSnapshot`.
pub fn deserializeSnapshot(allocator: std.mem.Allocator, json_text: []const u8) !GameSnapshot {
    const parsed = try std.json.parseFromSlice(JsonSnapshot, allocator, json_text, .{});
    defer parsed.deinit();
    var snap: GameSnapshot = undefined;
    for (parsed.value.cells, 0..) |cell, i| {
        snap.cells[i] = .{
            .value = cell.value,
            .given = cell.given,
            .conflict = cell.conflict,
        };
    }
    return snap;
}

test "PlayerDifficulty wire values are 1 2 3" {
    try std.testing.expectEqual(@as(u8, 1), @backingInt(PlayerDifficulty.easy));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(PlayerDifficulty.medium));
    try std.testing.expectEqual(@as(u8, 3), @backingInt(PlayerDifficulty.hard));
}

test "PlayerDifficulty has no default variant on boundary" {
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(PlayerDifficulty).@"enum".field_names.len);
    try std.testing.expect(PlayerDifficulty.fromWire(0) == null);
}

test "PlayerDifficulty.fromWire rejects invalid wire values" {
    try std.testing.expect(PlayerDifficulty.fromWire(4) == null);
    try std.testing.expect(PlayerDifficulty.fromWire(255) == null);
}

test "BootstrapConfig.fromWire maps difficulty and log level" {
    const cfg = BootstrapConfig.fromWire(2, @backingInt(logger.Severity.warn)).?;
    try std.testing.expectEqual(PlayerDifficulty.medium, cfg.difficulty);
    try std.testing.expectEqual(logger.Severity.warn, cfg.log_level);
}

test "GameSnapshot captures value given conflict from BoardView" {
    var b = try board.fromOneLineString(puzzle_gen.PuzzleGen.default());
    try b.setCell(0, 2, .seven);
    b.refreshConflictsForCell(0, 2);
    try b.setCell(0, 3, .seven);
    b.refreshConflictsForCell(0, 3);

    const snap = GameSnapshot.fromView(b.asView());
    const idx = @as(usize, 0) * board.DIMENSION_SIZE + @as(usize, 2);
    try std.testing.expectEqual(@as(u8, 7), snap.cells[idx].value);
    try std.testing.expect(!snap.cells[idx].given);
    try std.testing.expect(snap.cells[idx].conflict);

    const given_idx = @as(usize, 0) * board.DIMENSION_SIZE + @as(usize, 0);
    try std.testing.expectEqual(@as(u8, 6), snap.cells[given_idx].value);
    try std.testing.expect(snap.cells[given_idx].given);
    try std.testing.expect(!snap.cells[given_idx].conflict);
}

test "GameSnapshot JSON round-trip preserves all cells" {
    var b = try board.fromOneLineString(puzzle_gen.PuzzleGen.medium());
    try b.setCell(1, 2, .five);
    b.refreshConflictsForCell(1, 2);

    const original = GameSnapshot.fromView(b.asView());
    const json = try serializeSnapshot(std.testing.allocator, original);
    defer std.testing.allocator.free(json);

    const restored = try deserializeSnapshot(std.testing.allocator, json);
    try std.testing.expect(original.eql(restored));
}
