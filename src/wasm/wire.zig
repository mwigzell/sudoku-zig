// JSON wire types for the wasm export boundary — the board snapshot.
const std = @import("std");
const board = @import("../core/board/board.zig");
const puzzle_gen = @import("../core/puzzle_gen/mod.zig");
const clear_command = @import("../core/engine/clear.zig");
const fill_command = @import("../core/engine/fill.zig");
const event = @import("../core/event.zig");
const frame_mod = @import("../core/frame.zig");

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
