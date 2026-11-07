// JSON wire types for the wasm export boundary — WireConfig and board snapshot.
const std = @import("std");
const board = @import("../core/board/board.zig");
const puzzle_gen = @import("../core/puzzle_gen/mod.zig");
const logger = @import("../core/logger.zig");
const config = @import("../core/config.zig");
const clear_command = @import("../core/engine/clear.zig");
const fill_command = @import("../core/engine/fill.zig");
const event = @import("../core/event.zig");
const frame_mod = @import("../core/frame.zig");

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

    /// The player-facing level for a generator difficulty (`default` plays as easy).
    pub fn fromPuzzleDifficulty(d: puzzle_gen.Difficulty) PlayerDifficulty {
        return switch (d) {
            .easy, .default => .easy,
            .medium => .medium,
            .hard => .hard,
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

/// Wasm wire twin of the config fields JS reads/writes (`init` args and `getConfig` JSON).
pub const WireConfig = struct {
    difficulty: PlayerDifficulty,
    log_level: logger.Severity = .info,
    theme: config.ViewTheme = .dark,
    show_region: bool = false,
    warn_solvability: bool = false,
    auto_restore: bool = false,
    auto_new: bool = false,
    auto_save: bool = false,
    show_marks: bool = true,

    pub fn fromWire(difficulty: u8, log_level: u8) ?WireConfig {
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

    pub fn toConfig(self: WireConfig) config.Config {
        var cfg = config.Config.default();
        cfg.difficulty = self.difficulty.toPuzzleDifficulty();
        cfg.log_level = self.log_level;
        cfg.theme = self.theme;
        cfg.show_region = self.show_region;
        cfg.warn_solvability = self.warn_solvability;
        cfg.auto_restore = self.auto_restore;
        cfg.auto_new = self.auto_new;
        cfg.auto_save = self.auto_save;
        cfg.show_marks = self.show_marks;
        return cfg;
    }

    pub fn fromConfig(cfg: config.Config) WireConfig {
        return .{
            .difficulty = PlayerDifficulty.fromPuzzleDifficulty(cfg.difficulty),
            .log_level = cfg.log_level,
            .theme = cfg.theme,
            .show_region = cfg.show_region,
            .warn_solvability = cfg.warn_solvability,
            .auto_restore = cfg.auto_restore,
            .auto_new = cfg.auto_new,
            .auto_save = cfg.auto_save,
            .show_marks = cfg.show_marks,
        };
    }
};

/// Serializable display twin of one board cell.
pub const CellSnapshot = struct {
    value: u8,
    given: bool,
    conflict: bool,
    /// Core's Clear rule for this cell (`clear.canClear`), so front ends enable Clear without deciding it.
    clearable: bool,
    /// Core's fill rule for this cell (`fill.canFill`), so front ends enable the digits without deciding it.
    fillable: bool,
    /// Pencil marks: bit `k` set when digit `k + 1` is marked.
    marks: board.MarkSet,
};

/// Serializable display twin of core's `Frame`: every cell of its board, how marks are drawn,
/// and the selected cell with its shaded region. The status line travels beside it.
pub const GameSnapshot = struct {
    cells: [board.CELL_COUNT]CellSnapshot,
    pencil_mode: bool,
    marks_visible: bool,
    selected: ?event.CellCoord,
    region: ?board.CellMask,

    /// Snapshot what `frame` draws.
    pub fn fromFrame(frame: frame_mod.Frame) GameSnapshot {
        var snap: GameSnapshot = .{
            .cells = undefined,
            .pencil_mode = frame.pencil_mode,
            .marks_visible = frame.marks_visible,
            .selected = frame.selected,
            .region = frame.region,
        };
        const view = frame.board;
        for (0..board.DIMENSION_SIZE) |r_u| {
            const row: u4 = @intCast(r_u);
            for (0..board.DIMENSION_SIZE) |c_u| {
                const col: u4 = @intCast(c_u);
                const idx = @as(usize, @intCast(row)) * board.DIMENSION_SIZE + @as(usize, @intCast(col));
                snap.cells[idx] = .{
                    .value = @backingInt(view.get(row, col)),
                    .given = view.isGiven(row, col),
                    .conflict = view.isConflictingRowCol(row, col),
                    .clearable = clear_command.canClear(view, row, col),
                    .fillable = fill_command.canFill(view, row, col),
                    .marks = view.marks(row, col),
                };
            }
        }
        return snap;
    }

    pub fn eql(self: GameSnapshot, other: GameSnapshot) bool {
        return std.meta.eql(self, other);
    }
};

/// JSON shape of `GameSnapshot`; the region is its cell indices, since JS numbers cannot hold 81 bits.
const JsonSnapshot = struct {
    cells: [board.CELL_COUNT]CellSnapshot,
    pencil_mode: bool,
    marks_visible: bool,
    selected: ?event.CellCoord,
    region: ?[]const u8,
};

pub fn writeCellJson(w: *std.Io.Writer, cell: CellSnapshot) !void {
    try std.Io.Writer.print(
        w,
        "{{\"value\":{d},\"given\":{any},\"conflict\":{any},\"clearable\":{any},\"fillable\":{any},\"marks\":{d}}}",
        .{ cell.value, cell.given, cell.conflict, cell.clearable, cell.fillable, cell.marks },
    );
}

pub fn writeGameSnapshotJson(w: *std.Io.Writer, snap: GameSnapshot) !void {
    try std.Io.Writer.writeAll(w, "{\"cells\":[");
    for (snap.cells, 0..) |cell, i| {
        if (i > 0) try std.Io.Writer.writeAll(w, ",");
        try writeCellJson(w, cell);
    }
    try std.Io.Writer.print(w, "],\"pencil_mode\":{any},\"marks_visible\":{any},\"selected\":", .{
        snap.pencil_mode,
        snap.marks_visible,
    });
    if (snap.selected) |sel| {
        try std.Io.Writer.print(w, "{{\"row\":{d},\"col\":{d}}}", .{ sel.row, sel.col });
    } else try std.Io.Writer.writeAll(w, "null");
    try std.Io.Writer.writeAll(w, ",\"region\":");
    if (snap.region) |mask| try writeRegionJson(w, mask) else try std.Io.Writer.writeAll(w, "null");
    try std.Io.Writer.writeAll(w, "}");
}

/// The region's cell indices (row * 9 + col), ascending.
fn writeRegionJson(w: *std.Io.Writer, mask: board.CellMask) !void {
    try std.Io.Writer.writeAll(w, "[");
    var first = true;
    for (0..board.CELL_COUNT) |i| {
        if (mask & board.indexBit(i) == 0) continue;
        if (!first) try std.Io.Writer.writeAll(w, ",");
        first = false;
        try std.Io.Writer.print(w, "{d}", .{i});
    }
    try std.Io.Writer.writeAll(w, "]");
}

/// Serialize a snapshot to a heap-owned JSON string.
pub fn serializeSnapshot(allocator: std.mem.Allocator, snap: GameSnapshot) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeGameSnapshotJson(&aw.writer, snap);
    var list = aw.toArrayList();
    return list.toOwnedSlice(allocator);
}

/// Parse a JSON snapshot produced by `serializeSnapshot`.
pub fn deserializeSnapshot(allocator: std.mem.Allocator, json_text: []const u8) !GameSnapshot {
    const parsed = try std.json.parseFromSlice(JsonSnapshot, allocator, json_text, .{});
    defer parsed.deinit();
    var region: ?board.CellMask = null;
    if (parsed.value.region) |indices| {
        var mask: board.CellMask = 0;
        for (indices) |i| mask |= board.indexBit(i);
        region = mask;
    }
    return .{
        .cells = parsed.value.cells,
        .pencil_mode = parsed.value.pencil_mode,
        .marks_visible = parsed.value.marks_visible,
        .selected = parsed.value.selected,
        .region = region,
    };
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

test "WireConfig.fromWire maps difficulty and log level" {
    const cfg = WireConfig.fromWire(2, @backingInt(logger.Severity.warn)).?;
    try std.testing.expectEqual(PlayerDifficulty.medium, cfg.difficulty);
    try std.testing.expectEqual(logger.Severity.warn, cfg.log_level);
    try std.testing.expectEqual(config.ViewTheme.dark, cfg.theme);
    try std.testing.expect(!cfg.show_region);
}

test "WireConfig round-trips config fields including view prefs" {
    var domain = config.Config.default();
    domain.difficulty = .hard;
    domain.log_level = .warn;
    domain.theme = .light;
    domain.show_region = true;
    domain.auto_restore = true;
    domain.auto_new = true;
    domain.auto_save = true;
    domain.show_marks = false;

    const wire_cfg = WireConfig.fromConfig(domain);
    try std.testing.expectEqual(PlayerDifficulty.hard, wire_cfg.difficulty);
    try std.testing.expectEqual(logger.Severity.warn, wire_cfg.log_level);
    try std.testing.expectEqual(config.ViewTheme.light, wire_cfg.theme);
    try std.testing.expect(wire_cfg.show_region);
    try std.testing.expect(wire_cfg.auto_restore);
    try std.testing.expect(wire_cfg.auto_new);
    try std.testing.expect(wire_cfg.auto_save);

    const restored = wire_cfg.toConfig();
    try std.testing.expectEqual(domain.difficulty, restored.difficulty);
    try std.testing.expectEqual(domain.log_level, restored.log_level);
    try std.testing.expectEqual(domain.theme, restored.theme);
    try std.testing.expectEqual(domain.show_region, restored.show_region);
    try std.testing.expectEqual(domain.auto_restore, restored.auto_restore);
    try std.testing.expectEqual(domain.auto_new, restored.auto_new);
    try std.testing.expectEqual(domain.auto_save, restored.auto_save);
    try std.testing.expectEqual(domain.show_marks, restored.show_marks);
}

test "GameSnapshot captures value given conflict clearable fillable from the frame's board" {
    var b = try board.fromPuzzle(puzzle_gen.PuzzleGen.default());
    try b.setCell(0, 2, .seven);
    b.refreshConflictsForCell(0, 2);
    try b.setCell(0, 3, .seven);
    b.refreshConflictsForCell(0, 3);

    const snap = GameSnapshot.fromFrame(.{ .board = b.asView(), .pencil_mode = true });
    const idx = @as(usize, 0) * board.DIMENSION_SIZE + @as(usize, 2);
    try std.testing.expectEqual(@as(u8, 7), snap.cells[idx].value);
    try std.testing.expect(!snap.cells[idx].given);
    try std.testing.expect(snap.cells[idx].conflict);
    try std.testing.expect(snap.cells[idx].clearable);
    try std.testing.expect(snap.cells[idx].fillable);

    const given_idx = @as(usize, 0) * board.DIMENSION_SIZE + @as(usize, 0);
    try std.testing.expectEqual(@as(u8, 6), snap.cells[given_idx].value);
    try std.testing.expect(snap.cells[given_idx].given);
    try std.testing.expect(!snap.cells[given_idx].conflict);
    try std.testing.expect(!snap.cells[given_idx].clearable);
    try std.testing.expect(!snap.cells[given_idx].fillable);

    const empty_idx = @as(usize, 0) * board.DIMENSION_SIZE + @as(usize, 5);
    try std.testing.expectEqual(@as(u8, 0), snap.cells[empty_idx].value);
    try std.testing.expect(!snap.cells[empty_idx].clearable);
    try std.testing.expect(snap.cells[empty_idx].fillable);
}

test "GameSnapshot JSON round-trip preserves cells, selection and region" {
    var b = try board.fromPuzzle(puzzle_gen.PuzzleGen.medium());
    try b.setCell(1, 2, .five);
    b.refreshConflictsForCell(1, 2);

    const original = GameSnapshot.fromFrame(.{
        .board = b.asView(),
        .pencil_mode = true,
        .selected = .{ .row = 1, .col = 2 },
        .region = conflict.unitsMask(1, 2),
    });
    const json = try serializeSnapshot(std.testing.allocator, original);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"selected\":{\"row\":1,\"col\":2},\"region\":[0,1,2,") != null);
    const restored = try deserializeSnapshot(std.testing.allocator, json);
    try std.testing.expect(original.eql(restored));
}

test "GameSnapshot JSON writes null selection and region when nothing is selected" {
    const b = try board.fromPuzzle(puzzle_gen.PuzzleGen.medium());
    const json = try serializeSnapshot(std.testing.allocator, GameSnapshot.fromFrame(.{ .board = b.asView() }));
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.endsWith(u8, json, ",\"selected\":null,\"region\":null}"));
}

const conflict = @import("../core/board/conflict.zig");
