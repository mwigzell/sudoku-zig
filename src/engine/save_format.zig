// Save-file wire format: header/entries/trailer types, blob (de)serialization,
// and file-backed save/open over an Io handle.
const std = @import("std");
const ge = @import("game_engine.zig");
const board = @import("../board.zig");
const cell = @import("../board/cell.zig");
const _puzzle_gen = @import("../puzzle_gen.zig");
const command = @import("../command.zig");

pub const IoError = error{ OutOfMemory, FileNotFound, AccessDenied, System };

// ---------------------------------------------------------------------------
// Save file wire format types
// ---------------------------------------------------------------------------

pub const SaveFileMagic = [_]u8{ 'S', 'U', 'D', '0' };
pub const SaveFileVersion: u8 = 1;

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
};

pub const SAVE_HEADER_SIZE: usize = 11; // magic(4) + ver_major(1) + ver_minor(1) + ver_patch(1) + pointer(2) + entry_count(2)
pub const SAVE_TRAILER_SIZE: usize = 97; // given_bits(16) + flat_board(81)

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

/// Write a SaveFileTrailer as exactly 97 bytes into buf.
pub fn writeSaveTrailer(buf: []u8, trailer: *const SaveFileTrailer) void {
    const bytes = std.mem.toBytes(trailer.given_bits);
    @memcpy(buf[0..16], &bytes);
    @memcpy(buf[16..97], &trailer.flat_board);
}

/// Read a SaveFileTrailer from exactly 97 bytes.
pub fn readSaveTrailer(buf: []const u8) SaveFileTrailer {
    var given_bits: u128 = undefined;
    given_bits = std.mem.bytesToValue(u128, buf[0..16]);
    return SaveFileTrailer{
        .given_bits = given_bits,
        .flat_board = buf[16..97].*,
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
pub fn toSaveFormat(self: *const ge.GameEngine, gpa: std.mem.Allocator) ![]u8 {
    const entry_count = self.history.entries.items.len;
    const total_size = SAVE_HEADER_SIZE + (entry_count * @sizeOf(SaveEntry)) + SAVE_TRAILER_SIZE;

    var buf = try gpa.alloc(u8, total_size);

    // Write header
    const header = SaveFileHeader{
        .magic = SaveFileMagic,
        .version_major = 0,
        .version_minor = 0,
        .version_patch = SaveFileVersion,
        .pointer = @as(u16, @intCast(self.history.pointer)),
        .entry_count = @as(u16, @intCast(entry_count)),
    };
    writeSaveHeader(buf[0..SAVE_HEADER_SIZE], &header);

    // Write SaveEntry records
    var offset: usize = SAVE_HEADER_SIZE;
    for (self.history.entries.items) |entry| {
        const se = SaveEntry{
            .coords = (@as(u8, @intCast(entry.row)) << 4) | @as(u8, @intCast(entry.col)),
            .values = (@as(u8, @intFromEnum(entry.old_value)) << 4) | @as(u8, @intFromEnum(entry.new_value)),
        };
        buf[offset + 0] = se.coords;
        buf[offset + 1] = se.values;
        offset += @sizeOf(SaveEntry);
    }
    // Write trailer
    const trailer = SaveFileTrailer{
        .given_bits = self.board.given_bits,
        .flat_board = self.board.toFlat(),
    };
    writeSaveTrailer(buf[offset..], &trailer);

    return buf;
}

/// Deserialize from a toSaveFormat blob into a fresh GameEngine.
pub fn fromSaveFormat(gpa: std.mem.Allocator, io: std.Io, buf: []const u8) !ge.GameEngine {
    const header = readSaveHeader(buf[0..SAVE_HEADER_SIZE]);
    if (!std.mem.eql(u8, &header.magic, "SUD0")) {
        return error.InvalidSaveFile;
    }
    if (header.version_patch != SaveFileVersion) {
        return error.IncompatibleVersion;
    }

    const offset = SAVE_HEADER_SIZE;
    var history = ge.MutationHistory.init(gpa);
    for (0..header.entry_count) |i| {
        const idx: usize = offset + (@as(usize, i) * @sizeOf(SaveEntry));
        const se = SaveEntry{
            .coords = buf[idx],
            .values = buf[idx + 1],
        };
        try history.push(
            @as(u4, @intCast(se.coords >> 4)),
            @as(u4, @intCast(se.coords & 0x0F)),
            cell.rawToCellValue(@as(u4, @intCast(se.values >> 4))),
            cell.rawToCellValue(@as(u4, @intCast(se.values & 0x0F))),
        );
    }
    const entries_end = offset + (header.entry_count * @sizeOf(SaveEntry));
    const trailer = readSaveTrailer(buf[entries_end..]);
    var engine = ge.GameEngine{
        .board = try board.fromFlat(trailer.flat_board, .{ .given_bits = trailer.given_bits }),
        .history = history,
        .io = io,
        .data_dir = null,
        .last_save_msg = null,
    };

    engine.history.pointer = header.pointer;

    return engine;
}

/// Serialize game state to a binary save file via an Io handle.
pub fn saveGame(self: *const ge.GameEngine, io: std.Io, path: []const u8) IoError!void {
    const buf = toSaveFormat(self, std.heap.page_allocator) catch {
        return IoError.System;
    };
    defer std.heap.page_allocator.free(buf);

    var file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch {
        return IoError.System;
    };
    defer file.close(io);

    std.Io.File.writeStreamingAll(file, io, buf) catch {
        return IoError.System;
    };
}

/// Load a save file over an Io handle; replaces this engine's board, history, and pointer.
pub fn openGame(self: *ge.GameEngine, io: std.Io, path: []const u8) IoError!void {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
        return IoError.System;
    };
    defer file.close(io);

    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        return IoError.System;
    };
    const buf = std.heap.page_allocator.alloc(u8, stat.size) catch {
        return IoError.OutOfMemory;
    };
    defer std.heap.page_allocator.free(buf);

    _ = std.Io.File.readPositionalAll(file, io, buf, 0) catch {
        return IoError.System;
    };

    const loaded = fromSaveFormat(std.heap.page_allocator, io, buf) catch {
        return IoError.System;
    };
    self.history.deinit();
    const old_board = self.board;
    self.* = loaded;
    _ = old_board;
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
    const entry = SaveEntry{ .coords = 0, .values = (@as(u8, @intFromEnum(cell.CellValue.three)) << 4) | @as(u8, @intFromEnum(cell.CellValue.seven)) };
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

test "saveGame returns error on bad path" {
    var engine = try ge.GameEngine.init(_puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const result = engine.saveGame(std.testing.io, "/nonexistent/dir/save.sud");
    try std.testing.expectError(IoError.System, result);
}

// save → open round-trip (full saved state equality)

test "saveGame then openGame: full state round-trip equals original" {
    var original = try ge.GameEngine.init(_puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer original.deinit();

    // Make mutations to populate history and alter board
    _ = original.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });
    _ = original.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    });
    _ = original.exec(command.Command{
        .fill = command.FillData{ .row = 4, .col = 4, .digit = cell.CellValue.one },
    });

    // Undo one mutation — tests that pointer position is preserved
    _ = original.exec(command.Command{ .undo = {} });

    // Save to temp file using test I/O
    const tmp_path = "/tmp/sudoku_roundtrip_test.sud";
    _ = original.saveGame(std.testing.io, tmp_path) catch |err| return err;

    // Open into a new engine
    var loaded = try ge.GameEngine.init(_puzzle_gen.PuzzleGen.default(), std.testing.io);
    try loaded.openGame(std.testing.io, tmp_path);
    defer loaded.deinit();

    // --- Assert board state (cells + given_bits) via Board.equal() ---
    try std.testing.expect(original.board.equal(loaded.board));

    // --- Assert history pointer position ---
    try std.testing.expectEqual(
        original.history.pointer,
        loaded.history.pointer,
    );

    // --- Assert history entries count + contents ---
    const orig_count = original.history.entries.items.len;
    const load_count = loaded.history.entries.items.len;
    try std.testing.expectEqual(orig_count, load_count);

    for (original.history.entries.items, loaded.history.entries.items, 0..) |orig_e, load_e, idx| {
        _ = idx;
        try std.testing.expectEqual(orig_e.row, load_e.row);
        try std.testing.expectEqual(orig_e.col, load_e.col);
        try std.testing.expectEqual(orig_e.old_value, load_e.old_value);
        try std.testing.expectEqual(orig_e.new_value, load_e.new_value);
    }

    _ = std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};
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

test "SaveFileTrailer: wire format is 97 bytes" {
    try std.testing.expectEqual(@as(usize, 97), SAVE_TRAILER_SIZE);
}

test "SaveFileTrailer: fields can be set and read back" {
    var board_vals: [81]u8 = undefined;
    for (0..81) |i| {
        board_vals[i] = @as(u8, @intCast(i % 10));
    }

    const trailer = SaveFileTrailer{
        .given_bits = 0xFFFF_FFFF_FFFF_FFFF,
        .flat_board = board_vals,
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
    };

    var buf: [SAVE_TRAILER_SIZE]u8 = undefined;
    writeSaveTrailer(&buf, &original);

    const loaded = readSaveTrailer(&buf);
    try std.testing.expectEqual(original.given_bits, loaded.given_bits);
    try std.testing.expectEqual(original.flat_board, loaded.flat_board);
}

// toSaveFormat / fromSaveFormat (in-memory blob serialization)

test "toSaveFormat empty history produces buffer of correct size" {
    var engine = try ge.GameEngine.init(_puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const buf = try toSaveFormat(&engine, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    // header(11) + 0 entries + trailer(97) = 108
    try std.testing.expectEqual(@as(usize, SAVE_HEADER_SIZE + SAVE_TRAILER_SIZE), buf.len);
}

test "toSaveFormat header has correct magic and version" {
    var engine = try ge.GameEngine.init(_puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const buf = try toSaveFormat(&engine, std.testing.allocator);
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
    var engine = try ge.GameEngine.init(_puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    // Make 3 mutations (same as existing round-trip test)
    _ = engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });
    _ = engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    });
    _ = engine.exec(command.Command{
        .fill = command.FillData{ .row = 4, .col = 4, .digit = cell.CellValue.one },
    });

    const buf = try toSaveFormat(&engine, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    // Size check: header(11) + 3 entries(6) + trailer(97) = 114
    try std.testing.expectEqual(@as(usize, SAVE_HEADER_SIZE + (3 * @sizeOf(SaveEntry)) + SAVE_TRAILER_SIZE), buf.len);

    // Verify entry count from header
    const header = readSaveHeader(buf[0..SAVE_HEADER_SIZE]);
    try std.testing.expectEqual(@as(u16, 3), header.entry_count);
    try std.testing.expectEqual(@as(u16, 3), header.pointer);

    // Verify first entry (row=0, col=2, old=zero, new=seven)
    const first_entry = buf[SAVE_HEADER_SIZE .. SAVE_HEADER_SIZE + @sizeOf(SaveEntry)];
    const coords: u8 = first_entry[0];
    const values: u8 = first_entry[1];
    try std.testing.expectEqual(@as(u4, 0), @as(u4, @intCast(coords >> 4)));
    try std.testing.expectEqual(@as(u4, 2), @as(u4, @intCast(coords & 0x0F)));
    try std.testing.expectEqual(cell.CellValue.zero, cell.rawToCellValue(values >> 4));
    try std.testing.expectEqual(cell.CellValue.seven, cell.rawToCellValue(values & 0x0F));

    // Verify trailer flat_board has the mutations at correct cells
    const off: usize = SAVE_HEADER_SIZE + (3 * @sizeOf(SaveEntry));
    const trailer = readSaveTrailer(buf[off..]);
    try std.testing.expectEqual(trailer.given_bits, engine.board.given_bits);
    // Cell (0,2) should be seven in trailer
    try std.testing.expectEqual(@as(u8, 7), trailer.flat_board[@as(usize, 0) * board.DIMENSION_SIZE + @as(usize, 2)]);
    // Cell (1,1) should be three
    try std.testing.expectEqual(@as(u8, 3), trailer.flat_board[@as(usize, 1) * board.DIMENSION_SIZE + @as(usize, 1)]);
    // Cell (4,4) should be one
    try std.testing.expectEqual(@as(u8, 1), trailer.flat_board[@as(usize, 4) * board.DIMENSION_SIZE + @as(usize, 4)]);
}

test "fromSaveFormat round-trip: board state given_bits history" {
    var original = try ge.GameEngine.init(_puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer original.deinit();

    _ = original.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    });
    _ = original.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    });
    _ = original.exec(command.Command{
        .fill = command.FillData{ .row = 4, .col = 4, .digit = cell.CellValue.one },
    });
    _ = original.exec(command.Command{ .undo = {} });

    const buf = try toSaveFormat(&original, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try fromSaveFormat(std.testing.allocator, std.testing.io, buf);
    defer loaded.deinit();
    // --- Assert board state (cells + given_bits) via Board.equal() ---
    try std.testing.expect(original.board.equal(loaded.board));
    try std.testing.expectEqual(original.history.pointer, loaded.history.pointer);
    try std.testing.expectEqual(
        original.history.entries.items.len,
        loaded.history.entries.items.len,
    );
    for (original.history.entries.items, loaded.history.entries.items, 0..) |o, l, idx| {
        _ = idx;
        try std.testing.expectEqual(o.row, l.row);
        try std.testing.expectEqual(o.col, l.col);
        try std.testing.expectEqual(o.old_value, l.old_value);
        try std.testing.expectEqual(o.new_value, l.new_value);
    }
}
