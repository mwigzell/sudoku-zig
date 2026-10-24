// Save-file wire format: header/entry/trailer types + pure State blob (de)serialization.
// File I/O lives in native/shell/ session handlers.
const std = @import("std");
const mutation_history = @import("mutation_history.zig");
const state_mod = @import("state.zig");
const board = @import("../board/board.zig");
const cell = @import("../board/cell.zig");
const _puzzle_gen = @import("../puzzle_gen/mod.zig");

test "fromSaveFormat uses mutation_history not game_engine" {
    var board_state = try board.fromOneLineString(_puzzle_gen.PuzzleGen.default());
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    try board_state.setCell(0, 2, .seven);
    try hist.push(0, 2, .zero, .seven);

    const st = state_mod.State{ .board = board_state, .history = hist };
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try fromSaveFormat(std.testing.allocator, buf);
    defer loaded.history.deinit();
    try std.testing.expect(board.equal(st.board, loaded.board));
    try std.testing.expectEqual(@as(usize, 1), loaded.history.pointer);
}

test "save codec round-trip preserves durable status text" {
    const board_state = try board.fromOneLineString(_puzzle_gen.PuzzleGen.default());
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();

    var st = state_mod.State{
        .board = board_state,
        .history = hist,
    };
    st.status.append("You win!");

    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try fromSaveFormat(std.testing.allocator, buf);
    defer loaded.history.deinit();
    try std.testing.expectEqualStrings("You win!", loaded.status.optional().?);
}

// ---------------------------------------------------------------------------
// Save file wire format types
// ---------------------------------------------------------------------------

pub const SaveFileMagic = [_]u8{ 'S', 'U', 'D', '0' };
pub const SaveFileVersion: u8 = 3;
pub const MAX_STATUS_BYTES: usize = 256;

pub const SaveFileHeader = struct {
    magic: [4]u8, // "SUD0"
    version_major: u8,
    version_minor: u8,
    version_patch: u8,
    pointer: u16,
    entry_count: u16,
};

pub const SaveFileTrailer = struct {
    given_bits: u128,
    flat_board: [81]u8,
    status_len: u16,
    status_text: [MAX_STATUS_BYTES]u8,
};

pub const SAVE_HEADER_SIZE: usize = 11; // magic(4) + ver_major(1) + ver_minor(1) + ver_patch(1) + pointer(2) + entry_count(2)
pub const SAVE_TRAILER_SIZE_V2: usize = 97; // given_bits(16) + flat_board(81)
pub const SAVE_TRAILER_SIZE: usize = SAVE_TRAILER_SIZE_V2 + 2 + MAX_STATUS_BYTES; // + status_len(u16) + status bytes

/// Write a SaveFileHeader as exactly 11 bytes into buf.
pub fn writeSaveHeader(buf: []u8, header: *const SaveFileHeader) void {
    @memcpy(buf[0..4], &header.magic);
    buf[4] = header.version_major;
    buf[5] = header.version_minor;
    buf[6] = header.version_patch;
    buf[7] = @truncate(header.pointer);
    buf[8] = @truncate(header.pointer >> 8);
    buf[9] = @truncate(header.entry_count);
    buf[10] = @truncate(header.entry_count >> 8);
}

/// Read a SaveFileHeader from exactly 11 bytes. The file must be in little-endian order.
pub fn readSaveHeader(buf: []const u8) SaveFileHeader {
    return SaveFileHeader{
        .magic = buf[0..4].*,
        .version_major = buf[4],
        .version_minor = buf[5],
        .version_patch = buf[6],
        .pointer = @as(u16, buf[7]) | (@as(u16, buf[8]) << 8),
        .entry_count = @as(u16, buf[9]) | (@as(u16, buf[10]) << 8),
    };
}

/// Write a SaveFileTrailer as exactly SAVE_TRAILER_SIZE bytes into buf.
pub fn writeSaveTrailer(buf: []u8, trailer: *const SaveFileTrailer) void {
    const bytes = std.mem.toBytes(trailer.given_bits);
    @memcpy(buf[0..16], &bytes);
    @memcpy(buf[16..97], &trailer.flat_board);
    buf[97] = @truncate(trailer.status_len);
    buf[98] = @truncate(trailer.status_len >> 8);
    @memcpy(buf[99 .. 99 + MAX_STATUS_BYTES], &trailer.status_text);
}

/// Read a SaveFileTrailer from SAVE_TRAILER_SIZE bytes.
pub fn readSaveTrailer(buf: []const u8) SaveFileTrailer {
    var given_bits: u128 = undefined;
    given_bits = std.mem.bytesToValue(u128, buf[0..16]);
    const status_len_wire: u16 = @as(u16, buf[97]) | (@as(u16, buf[98]) << 8);
    const status_len: u16 = @min(status_len_wire, @as(u16, MAX_STATUS_BYTES));
    var status_text: [MAX_STATUS_BYTES]u8 = @splat(0);
    @memcpy(status_text[0..MAX_STATUS_BYTES], buf[99 .. 99 + MAX_STATUS_BYTES]);
    return SaveFileTrailer{
        .given_bits = given_bits,
        .flat_board = buf[16..97].*,
        .status_len = status_len,
        .status_text = status_text,
    };
}

/// Packed mutation entry for save file (row+col in byte 0, old+new in byte 1).
pub const SaveEntry = struct {
    coords: u8,
    values: u8,
};

// ---------------------------------------------------------------------------
// GameEngine serialization / deserialization
// ---------------------------------------------------------------------------

/// Serialize full game state to a heap-allocated byte buffer.
/// Returns allocated []u8 — caller owns and must free with the same allocator.
pub fn toSaveFormat(self: *const state_mod.State, gpa: std.mem.Allocator) ![]u8 {
    const entry_count = self.history.entries.items.len;
    var entries_size: usize = 0;
    for (self.history.entries.items) |entry| entries_size += entryWireSize(entry);
    const total_size = SAVE_HEADER_SIZE + entries_size + SAVE_TRAILER_SIZE;

    var buf = try gpa.alloc(u8, total_size);

    const header = SaveFileHeader{
        .magic = SaveFileMagic,
        .version_major = 0,
        .version_minor = 0,
        .version_patch = SaveFileVersion,
        .pointer = @as(u16, @intCast(self.history.pointer)),
        .entry_count = @as(u16, @intCast(entry_count)),
    };
    writeSaveHeader(buf[0..SAVE_HEADER_SIZE], &header);

    var offset: usize = SAVE_HEADER_SIZE;
    for (self.history.entries.items) |entry| {
        offset += writeEntry(buf[offset..], entry);
    }
    const status_slice = self.status.slice();
    const status_take = @min(status_slice.len, MAX_STATUS_BYTES);
    var status_text: [MAX_STATUS_BYTES]u8 = @splat(0);
    if (status_take > 0) @memcpy(status_text[0..status_take], status_slice[0..status_take]);
    const trailer = SaveFileTrailer{
        .given_bits = self.board.given_bits,
        .flat_board = board.toFlat(self.board),
        .status_len = @intCast(status_take),
        .status_text = status_text,
    };
    writeSaveTrailer(buf[offset..][0..SAVE_TRAILER_SIZE], &trailer);

    return buf;
}

fn entryWireSize(entry: mutation_history.MutationEntry) usize {
    return switch (entry) {
        .cell => 3,
        .solve_batch => 1 + 16 + 81,
    };
}

fn writeEntry(buf: []u8, entry: mutation_history.MutationEntry) usize {
    switch (entry) {
        .cell => |c| {
            buf[0] = 1;
            buf[1] = (@as(u8, @intCast(c.row)) << 4) | @as(u8, @intCast(c.col));
            buf[2] = (@as(u8, @backingInt(c.old_value)) << 4) | @as(u8, @backingInt(c.new_value));
            return 3;
        },
        .solve_batch => |snap| {
            buf[0] = 2;
            const bits = std.mem.toBytes(snap.given_bits);
            @memcpy(buf[1..17], &bits);
            @memcpy(buf[17..98], &snap.flat);
            return 98;
        },
    }
}

fn pushCellEntry(history: *mutation_history.MutationHistory, coords: u8, values: u8) !void {
    try history.push(
        @as(u4, @intCast(coords >> 4)),
        @as(u4, @intCast(coords & 0x0F)),
        cell.rawToCellValue(@as(u4, @intCast(values >> 4))),
        cell.rawToCellValue(@as(u4, @intCast(values & 0x0F))),
    );
}

/// Deserialize from a toSaveFormat blob into a fresh State.
pub fn fromSaveFormat(gpa: std.mem.Allocator, buf: []const u8) !state_mod.State {
    const header = readSaveHeader(buf[0..SAVE_HEADER_SIZE]);
    if (!std.mem.eql(u8, &header.magic, "SUD0")) {
        return error.InvalidSaveFile;
    }
    if (header.version_patch != 1 and header.version_patch != 2 and header.version_patch != SaveFileVersion) {
        return error.IncompatibleVersion;
    }

    const offset = SAVE_HEADER_SIZE;
    var history = mutation_history.MutationHistory.init(gpa);
    errdefer history.deinit();
    var entries_end: usize = offset;
    if (header.version_patch == 1) {
        for (0..header.entry_count) |i| {
            const idx: usize = offset + (i * @sizeOf(SaveEntry));
            try pushCellEntry(&history, buf[idx], buf[idx + 1]);
        }
        entries_end = offset + (header.entry_count * @sizeOf(SaveEntry));
    } else {
        var cursor: usize = offset;
        for (0..header.entry_count) |_| {
            const tag = buf[cursor];
            cursor += 1;
            switch (tag) {
                1 => {
                    try pushCellEntry(&history, buf[cursor], buf[cursor + 1]);
                    cursor += 2;
                },
                2 => {
                    const given_bits = std.mem.bytesToValue(u128, buf[cursor..][0..16]);
                    var flat: [81]u8 = undefined;
                    @memcpy(&flat, buf[cursor + 16 ..][0..81]);
                    try history.pushSolve(.{ .given_bits = given_bits, .flat = flat });
                    cursor += 16 + 81;
                },
                else => return error.InvalidSaveFile,
            }
        }
        entries_end = cursor;
    }
    const trailer = if (header.version_patch >= SaveFileVersion)
        readSaveTrailer(buf[entries_end..][0..SAVE_TRAILER_SIZE])
    else blk: {
        const legacy_status: [MAX_STATUS_BYTES]u8 = @splat(0);
        break :blk SaveFileTrailer{
            .given_bits = std.mem.bytesToValue(u128, buf[entries_end..][0..16]),
            .flat_board = buf[entries_end + 16 ..][0..81].*,
            .status_len = 0,
            .status_text = legacy_status,
        };
    };
    var state = state_mod.State{
        .board = try board.fromFlat(trailer.flat_board, .{ .given_bits = trailer.given_bits }),
        .history = history,
    };
    state.status.reset();
    if (trailer.status_len > 0) {
        state.status.append(trailer.status_text[0..trailer.status_len]);
    }

    state.history.pointer = header.pointer;

    return state;
}

// ---------------------------------------------------------------------------
// Tests (co-located)
// ---------------------------------------------------------------------------

test "SaveEntry: total size is 2 bytes" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(SaveEntry));
}

test "SaveEntry: pack and unpack coords (row col)" {
    const entry = SaveEntry{ .coords = (@as(u8, @intCast(3 << 4)) | @as(u8, @intCast(7))), .values = 0 };
    try std.testing.expectEqual(@as(u4, 3), @as(u4, @intCast(entry.coords >> 4)));
    try std.testing.expectEqual(@as(u4, 7), @as(u4, @intCast(entry.coords & 0x0F)));
}

test "SaveEntry: pack and unpack values (old_value new_value)" {
    const entry = SaveEntry{ .coords = 0, .values = (@as(u8, @backingInt(cell.CellValue.three)) << 4) | @as(u8, @backingInt(cell.CellValue.seven)) };
    try std.testing.expectEqual(cell.CellValue.three, cell.rawToCellValue(entry.values >> 4));
    try std.testing.expectEqual(cell.CellValue.seven, cell.rawToCellValue(entry.values & 0x0F));
}

test "SaveFileMagic is 4 bytes 'SUD0'" {
    try std.testing.expectEqualStrings("SUD0", &SaveFileMagic);
}

test "Save file size: header + history_count(2) + N*entry_size + given_bits(16)" {
    const HistoryCountBytes = @sizeOf(u16);
    const GivenBitsBytes = @sizeOf(u128);
    const HeaderBytes = SaveFileMagic.len + 1; // magic + version

    // Empty game: header(5) + count(2) + 0 entries + given_bits(16) = 23
    const empty_size = HeaderBytes + HistoryCountBytes + GivenBitsBytes;
    try std.testing.expectEqual(@as(usize, 23), empty_size);

    // Game with 3 mutations: header(5) + count(2) + 3*2 entries + given_bits(16) = 29
    const three_mutations_size = HeaderBytes + HistoryCountBytes + (3 * @sizeOf(SaveEntry)) + GivenBitsBytes;
    try std.testing.expectEqual(@as(usize, 29), three_mutations_size);
}

// SaveFileHeader & SaveFileTrailer struct tests

test "SaveFileHeader: wire format is 11 bytes" {
    try std.testing.expectEqual(@as(usize, 11), SAVE_HEADER_SIZE);
}

test "SaveFileHeader: fields can be set and read back" {
    const header = SaveFileHeader{
        .magic = [_]u8{ 'S', 'U', 'D', '0' },
        .version_major = 0,
        .version_minor = 0,
        .version_patch = 1,
        .pointer = 2,
        .entry_count = 5,
    };
    try std.testing.expectEqualStrings("SUD0", &header.magic);
    try std.testing.expectEqual(@as(u8, 0), header.version_major);
    try std.testing.expectEqual(@as(u8, 0), header.version_minor);
    try std.testing.expectEqual(@as(u8, 1), header.version_patch);
    try std.testing.expectEqual(@as(u16, 2), header.pointer);
    try std.testing.expectEqual(@as(u16, 5), header.entry_count);
}

test "SaveFileHeader: round-trip write/read" {
    const original = SaveFileHeader{
        .magic = [_]u8{ 'S', 'U', 'D', '0' },
        .version_major = 0,
        .version_minor = 2,
        .version_patch = 1,
        .pointer = 3,
        .entry_count = 42,
    };

    var buf: [SAVE_HEADER_SIZE]u8 = undefined;
    writeSaveHeader(&buf, &original);

    const loaded = readSaveHeader(&buf);
    try std.testing.expectEqualStrings("SUD0", &loaded.magic);
    try std.testing.expectEqual(original.version_major, loaded.version_major);
    try std.testing.expectEqual(original.version_minor, loaded.version_minor);
    try std.testing.expectEqual(original.version_patch, loaded.version_patch);
    try std.testing.expectEqual(original.pointer, loaded.pointer);
    try std.testing.expectEqual(original.entry_count, loaded.entry_count);
}

test "SaveFileTrailer: wire format includes durable status tail" {
    try std.testing.expectEqual(@as(usize, SAVE_TRAILER_SIZE_V2 + 2 + MAX_STATUS_BYTES), SAVE_TRAILER_SIZE);
}

test "SaveFileTrailer: fields can be set and read back" {
    var board_vals: [81]u8 = undefined;
    for (0..81) |i| {
        board_vals[i] = @as(u8, @intCast(i % 10));
    }

    const trailer = SaveFileTrailer{
        .given_bits = 0xFFFF_FFFF_FFFF_FFFF,
        .flat_board = board_vals,
        .status_len = 0,
        .status_text = @splat(0),
    };

    try std.testing.expectEqual(@as(u128, 0xFFFF_FFFF_FFFF_FFFF), trailer.given_bits);
    try std.testing.expectEqual(board_vals, trailer.flat_board);
}

test "SaveFileTrailer: round-trip write/read" {
    var board_vals: [81]u8 = undefined;
    for (0..81) |i| {
        board_vals[i] = @as(u8, @intCast(i % 10));
    }

    const original = SaveFileTrailer{
        .given_bits = 0xCAFE_BABE_DEAD_BEEF_1234_5678_9ABC_DEF0,
        .flat_board = board_vals,
        .status_len = 8,
        .status_text = blk: {
            var tmp: [MAX_STATUS_BYTES]u8 = @splat(0);
            @memcpy(tmp[0..8], "You win!");
            break :blk tmp;
        },
    };

    var buf: [SAVE_TRAILER_SIZE]u8 = undefined;
    writeSaveTrailer(&buf, &original);

    const loaded = readSaveTrailer(&buf);
    try std.testing.expectEqual(original.given_bits, loaded.given_bits);
    try std.testing.expectEqual(original.flat_board, loaded.flat_board);
    try std.testing.expectEqual(original.status_len, loaded.status_len);
    try std.testing.expectEqualSlices(u8, original.status_text[0..original.status_len], loaded.status_text[0..loaded.status_len]);
}

// toSaveFormat / fromSaveFormat (in-memory blob serialization)

test "toSaveFormat empty history produces buffer of correct size" {
    const board_state = try board.fromOneLineString(_puzzle_gen.PuzzleGen.easy());
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();

    const st = state_mod.State{ .board = board_state, .history = hist };
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    // header + 0 entries + trailer
    try std.testing.expectEqual(@as(usize, SAVE_HEADER_SIZE + SAVE_TRAILER_SIZE), buf.len);
}

test "toSaveFormat header has correct magic and version" {
    const board_state = try board.fromOneLineString(_puzzle_gen.PuzzleGen.easy());
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();

    const st = state_mod.State{ .board = board_state, .history = hist };
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    const header = readSaveHeader(buf[0..SAVE_HEADER_SIZE]);
    try std.testing.expectEqualStrings("SUD0", &header.magic);
    try std.testing.expectEqual(@as(u8, 0), header.version_major);
    try std.testing.expectEqual(@as(u8, 0), header.version_minor);
    try std.testing.expectEqual(SaveFileVersion, header.version_patch);
    try std.testing.expectEqual(@as(u16, 0), header.pointer);
    try std.testing.expectEqual(@as(u16, 0), header.entry_count);
}

test "toSaveFormat includes history entries and correct trailer" {
    var board_state = try board.fromOneLineString(_puzzle_gen.PuzzleGen.default());
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();

    try board_state.setCell(0, 2, .seven);
    try hist.push(0, 2, .zero, .seven);
    try board_state.setCell(1, 1, .three);
    try hist.push(1, 1, .zero, .three);
    try board_state.setCell(4, 4, .one);
    try hist.push(4, 4, .zero, .one);

    const st = state_mod.State{ .board = board_state, .history = hist };
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    // Size check: header + 3 tagged cell entries + trailer
    try std.testing.expectEqual(@as(usize, SAVE_HEADER_SIZE + (3 * 3) + SAVE_TRAILER_SIZE), buf.len);

    // Verify entry count from header
    const header = readSaveHeader(buf[0..SAVE_HEADER_SIZE]);
    try std.testing.expectEqual(@as(u16, 3), header.entry_count);
    try std.testing.expectEqual(@as(u16, 3), header.pointer);

    // Verify first entry (tag, row=0, col=2, old=zero, new=seven)
    const first_entry = buf[SAVE_HEADER_SIZE .. SAVE_HEADER_SIZE + 3];
    try std.testing.expectEqual(@as(u8, 1), first_entry[0]);
    const coords: u8 = first_entry[1];
    const values: u8 = first_entry[2];
    try std.testing.expectEqual(@as(u4, 0), @as(u4, @intCast(coords >> 4)));
    try std.testing.expectEqual(@as(u4, 2), @as(u4, @intCast(coords & 0x0F)));
    try std.testing.expectEqual(cell.CellValue.zero, cell.rawToCellValue(values >> 4));
    try std.testing.expectEqual(cell.CellValue.seven, cell.rawToCellValue(values & 0x0F));

    // Verify trailer flat_board has the mutations at correct cells
    const off: usize = SAVE_HEADER_SIZE + (3 * 3);
    const trailer = readSaveTrailer(buf[off..]);
    try std.testing.expectEqual(trailer.given_bits, board_state.given_bits);
    // Cell (0,2) should be seven in trailer
    try std.testing.expectEqual(@as(u8, 7), trailer.flat_board[@as(usize, 0) * board.DIMENSION_SIZE + @as(usize, 2)]);
    // Cell (1,1) should be three
    try std.testing.expectEqual(@as(u8, 3), trailer.flat_board[@as(usize, 1) * board.DIMENSION_SIZE + @as(usize, 1)]);
    // Cell (4,4) should be one
    try std.testing.expectEqual(@as(u8, 1), trailer.flat_board[@as(usize, 4) * board.DIMENSION_SIZE + @as(usize, 4)]);
}

test "fromSaveFormat round-trip: board state given_bits history" {
    var board_state = try board.fromOneLineString(_puzzle_gen.PuzzleGen.default());
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();

    try board_state.setCell(0, 2, .seven);
    try hist.push(0, 2, .zero, .seven);
    try board_state.setCell(1, 1, .three);
    try hist.push(1, 1, .zero, .three);
    try board_state.setCell(4, 4, .one);
    try hist.push(4, 4, .zero, .one);
    hist.pointer = 2;

    const st = state_mod.State{ .board = board_state, .history = hist };
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try fromSaveFormat(std.testing.allocator, buf);
    defer loaded.history.deinit();
    // --- Assert board state (cells + given_bits) via board.equal() ---
    try std.testing.expect(board.equal(st.board, loaded.board));
    try std.testing.expectEqual(st.history.pointer, loaded.history.pointer);
    try std.testing.expectEqual(
        st.history.entries.items.len,
        loaded.history.entries.items.len,
    );
    for (st.history.entries.items, loaded.history.entries.items, 0..) |o, l, idx| {
        _ = idx;
        switch (o) {
            .cell => |oc| {
                const lc = l.cell;
                try std.testing.expectEqual(oc.row, lc.row);
                try std.testing.expectEqual(oc.col, lc.col);
                try std.testing.expectEqual(oc.old_value, lc.old_value);
                try std.testing.expectEqual(oc.new_value, lc.new_value);
            },
            .solve_batch => return error.TestFailed,
        }
    }
}

test "save v2 round-trips a cell entry and one solve snapshot" {
    var board_state = try board.fromOneLineString(_puzzle_gen.PuzzleGen.easy());
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();

    try board_state.setCell(0, 0, .four);
    try hist.push(0, 0, .zero, .four);
    const before_flat = board.toFlat(board_state);
    const before_given = board_state.given_bits;
    try hist.pushSolve(.{ .given_bits = before_given, .flat = before_flat });

    const st = state_mod.State{ .board = board_state, .history = hist };
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    const header = readSaveHeader(buf[0..SAVE_HEADER_SIZE]);
    try std.testing.expectEqual(SaveFileVersion, header.version_patch);

    var loaded = try fromSaveFormat(std.testing.allocator, buf);
    defer loaded.history.deinit();
    try std.testing.expect(board.equal(st.board, loaded.board));
    try std.testing.expectEqual(@as(usize, 2), loaded.history.entries.items.len);
    switch (loaded.history.entries.items[0]) {
        .cell => |c| {
            try std.testing.expectEqual(@as(u4, 0), c.row);
            try std.testing.expectEqual(@as(u4, 0), c.col);
            try std.testing.expectEqual(cell.CellValue.zero, c.old_value);
            try std.testing.expectEqual(cell.CellValue.four, c.new_value);
        },
        .solve_batch => return error.TestFailed,
    }
    switch (loaded.history.entries.items[1]) {
        .solve_batch => |snap| {
            try std.testing.expectEqual(before_given, snap.given_bits);
            try std.testing.expectEqual(before_flat, snap.flat);
        },
        .cell => return error.TestFailed,
    }
}

test "save v1 fixture still loads as a cell entry" {
    var board_state = try board.fromOneLineString(_puzzle_gen.PuzzleGen.easy());
    try board_state.setCell(0, 0, .four);

    var buf = try std.testing.allocator.alloc(u8, SAVE_HEADER_SIZE + @sizeOf(SaveEntry) + SAVE_TRAILER_SIZE);
    defer std.testing.allocator.free(buf);
    const header = SaveFileHeader{
        .magic = SaveFileMagic,
        .version_major = 0,
        .version_minor = 0,
        .version_patch = 1,
        .pointer = 1,
        .entry_count = 1,
    };
    writeSaveHeader(buf[0..SAVE_HEADER_SIZE], &header);
    buf[SAVE_HEADER_SIZE] = 0;
    buf[SAVE_HEADER_SIZE + 1] = @as(u8, @backingInt(cell.CellValue.four));
    const trailer = SaveFileTrailer{
        .given_bits = board_state.given_bits,
        .flat_board = board.toFlat(board_state),
        .status_len = 0,
        .status_text = @splat(0),
    };
    writeSaveTrailer(buf[SAVE_HEADER_SIZE + @sizeOf(SaveEntry) ..][0..SAVE_TRAILER_SIZE], &trailer);

    var loaded = try fromSaveFormat(std.testing.allocator, buf);
    defer loaded.history.deinit();
    try std.testing.expect(board.equal(board_state, loaded.board));
    try std.testing.expectEqual(@as(usize, 1), loaded.history.pointer);
    switch (loaded.history.entries.items[0]) {
        .cell => |c| {
            try std.testing.expectEqual(@as(u4, 0), c.row);
            try std.testing.expectEqual(@as(u4, 0), c.col);
            try std.testing.expectEqual(cell.CellValue.zero, c.old_value);
            try std.testing.expectEqual(cell.CellValue.four, c.new_value);
        },
        .solve_batch => return error.TestFailed,
    }
}
