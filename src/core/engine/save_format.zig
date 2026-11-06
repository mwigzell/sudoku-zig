// Save-file wire format: the sectioned SUD0 codec for `State`. File I/O lives in the platform session handlers.
//
// Layout (little-endian):
//   header   magic "SUD0" (4), version u16, section_count u16
//   section  tag u8, len u32, payload[len]        — repeated section_count times
//   history payload: pointer u16, then entries: tag u8, len u8, payload[len]
// A reader skips sections and history entries whose tag it does not know, so new data needs no version bump.
const std = @import("std");
const mutation_history = @import("mutation_history.zig");
const state_mod = @import("state.zig");
const board = @import("../board/board.zig");
const cell = @import("../board/cell.zig");
const _puzzle_gen = @import("../puzzle_gen/mod.zig");

/// First four bytes of every save file.
pub const SaveFileMagic = [_]u8{ 'S', 'U', 'D', '0' };
/// Wire-format version. Changes only when an existing section or entry changes meaning; new data is a new tag.
pub const SaveFileVersion: u16 = 1;
/// Longest status text kept in a save; longer text is cut to this.
pub const MAX_STATUS_BYTES: usize = 256;

/// Header: magic, version, section count.
pub const HEADER_SIZE: usize = SaveFileMagic.len + @sizeOf(u16) + @sizeOf(u16);
/// Before each section's payload: tag and payload length.
pub const SECTION_PREFIX_SIZE: usize = @sizeOf(u8) + @sizeOf(u32);
/// Before each history entry's payload: tag and payload length.
pub const ENTRY_PREFIX_SIZE: usize = @sizeOf(u8) + @sizeOf(u8);

/// What a section holds. Unknown values are skipped on read.
pub const SectionTag = enum(u8) {
    board = 1,
    givens = 2,
    history = 3,
    status = 4,
    marks = 5,
    _,
};

/// What a history entry holds. Unknown values are skipped on read.
pub const EntryTag = enum(u8) {
    cell = 1,
    solve = 2,
    mark = 3,
    _,
};

/// Ways a save file is refused. The engine shows one message for all of them.
pub const Error = error{ InvalidSaveFile, IncompatibleVersion, OutOfMemory };

const GIVENS_SIZE: usize = @sizeOf(u128);
const BOARD_SIZE: usize = board.CELL_COUNT;
const POINTER_SIZE: usize = @sizeOf(u16);
/// Cell entry: row<<4|col, old<<4|new.
const CELL_ENTRY_SIZE: usize = 2;
const SOLVE_ENTRY_SIZE: usize = GIVENS_SIZE + BOARD_SIZE;
/// Mark entry: row<<4|col, digit<<4|old value.
const MARK_ENTRY_SIZE: usize = 2;
/// Marks section: one cell mask per digit, each stored like the givens mask.
const MARKS_SIZE: usize = board.DIMENSION_SIZE * GIVENS_SIZE;
const NIBBLE_BITS: u3 = 4;
const NIBBLE_MASK: u8 = 0x0F;
const MAX_CELL_VALUE: u8 = 9;
const SECTION_COUNT: u16 = 5;

// ---------------------------------------------------------------------------
// Byte cursors
// ---------------------------------------------------------------------------

/// Appends little-endian fields to a buffer sized up front.
const ByteWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn bytes(self: *ByteWriter, data: []const u8) void {
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn int(self: *ByteWriter, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.buf[self.pos..][0..@sizeOf(T)], value, .little);
        self.pos += @sizeOf(T);
    }

    fn sectionPrefix(self: *ByteWriter, tag: SectionTag, len: usize) void {
        self.int(u8, @backingInt(tag));
        self.int(u32, @intCast(len));
    }
};

/// Reads little-endian fields; running past the end is `InvalidSaveFile`, never a crash.
const ByteReader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn take(self: *ByteReader, n: usize) Error![]const u8 {
        if (n > self.buf.len - self.pos) return error.InvalidSaveFile;
        const out = self.buf[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    fn int(self: *ByteReader, comptime T: type) Error!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn atEnd(self: ByteReader) bool {
        return self.pos == self.buf.len;
    }
};

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Serialize full game state to a heap-allocated SUD0 buffer. Caller owns and frees it with `gpa`.
pub fn toSaveFormat(self: *const state_mod.State, gpa: std.mem.Allocator) ![]u8 {
    const status = statusBytes(self);
    const history_len = historyPayloadSize(&self.history);
    const total = HEADER_SIZE +
        SECTION_PREFIX_SIZE + BOARD_SIZE +
        SECTION_PREFIX_SIZE + GIVENS_SIZE +
        SECTION_PREFIX_SIZE + history_len +
        SECTION_PREFIX_SIZE + status.len +
        SECTION_PREFIX_SIZE + MARKS_SIZE;
    const buf = try gpa.alloc(u8, total);
    var w = ByteWriter{ .buf = buf };

    w.bytes(&SaveFileMagic);
    w.int(u16, SaveFileVersion);
    w.int(u16, SECTION_COUNT);

    w.sectionPrefix(.board, BOARD_SIZE);
    w.bytes(&board.toFlat(self.board));

    w.sectionPrefix(.givens, GIVENS_SIZE);
    w.int(u128, self.board.given_bits);

    w.sectionPrefix(.history, history_len);
    w.int(u16, @intCast(self.history.pointer));
    for (self.history.entries.items) |entry| writeEntry(&w, entry);

    w.sectionPrefix(.status, status.len);
    w.bytes(status);

    w.sectionPrefix(.marks, MARKS_SIZE);
    for (self.board.mark_bits) |plane| w.int(u128, plane);

    std.debug.assert(w.pos == total);
    return buf;
}

fn statusBytes(self: *const state_mod.State) []const u8 {
    const text = self.status.slice();
    return text[0..@min(text.len, MAX_STATUS_BYTES)];
}

fn entryPayloadSize(entry: mutation_history.MutationEntry) usize {
    return switch (entry) {
        .cell => CELL_ENTRY_SIZE,
        .solve_batch => SOLVE_ENTRY_SIZE,
        .mark => MARK_ENTRY_SIZE,
    };
}

fn historyPayloadSize(history: *const mutation_history.MutationHistory) usize {
    var size: usize = POINTER_SIZE;
    for (history.entries.items) |entry| size += ENTRY_PREFIX_SIZE + entryPayloadSize(entry);
    return size;
}

fn writeEntry(w: *ByteWriter, entry: mutation_history.MutationEntry) void {
    switch (entry) {
        .cell => |c| {
            w.int(u8, @backingInt(EntryTag.cell));
            w.int(u8, CELL_ENTRY_SIZE);
            w.int(u8, packNibbles(c.row, c.col));
            w.int(u8, packNibbles(@backingInt(c.old_value), @backingInt(c.new_value)));
        },
        .solve_batch => |snap| {
            w.int(u8, @backingInt(EntryTag.solve));
            w.int(u8, SOLVE_ENTRY_SIZE);
            w.int(u128, snap.given_bits);
            w.bytes(&snap.flat);
        },
        .mark => |m| {
            w.int(u8, @backingInt(EntryTag.mark));
            w.int(u8, MARK_ENTRY_SIZE);
            w.int(u8, packNibbles(m.row, m.col));
            w.int(u8, packNibbles(@backingInt(m.digit), @backingInt(m.old_value)));
        },
    }
}

fn packNibbles(high: u4, low: u4) u8 {
    return (@as(u8, high) << NIBBLE_BITS) | @as(u8, low);
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Sections found while reading; board and givens are required, history and status are optional.
const ReadSections = struct {
    flat: ?[BOARD_SIZE]u8 = null,
    given_bits: ?board.CellMask = null,
    history: ?[]const u8 = null,
    status: []const u8 = &.{},
    marks: [board.DIMENSION_SIZE]board.CellMask = @splat(0),
};

/// Deserialize a SUD0 buffer into a fresh State; the caller owns its history.
pub fn fromSaveFormat(gpa: std.mem.Allocator, buf: []const u8) Error!state_mod.State {
    var r = ByteReader{ .buf = buf };
    const magic = try r.take(SaveFileMagic.len);
    if (!std.mem.eql(u8, magic, &SaveFileMagic)) return error.InvalidSaveFile;
    if (try r.int(u16) != SaveFileVersion) return error.IncompatibleVersion;
    const section_count = try r.int(u16);

    var found = ReadSections{};
    for (0..section_count) |_| try readSection(&r, &found);

    const flat = found.flat orelse return error.InvalidSaveFile;
    const given_bits = found.given_bits orelse return error.InvalidSaveFile;
    var state = state_mod.State{
        .board = board.fromFlat(flat, .{ .given_bits = given_bits }) catch return error.InvalidSaveFile,
        .history = mutation_history.MutationHistory.init(gpa),
    };
    state.board.mark_bits = found.marks;
    errdefer state.history.deinit();
    if (found.history) |payload| try readHistory(&state.history, payload);
    state.status.reset();
    if (found.status.len > 0) state.status.append(found.status[0..@min(found.status.len, MAX_STATUS_BYTES)]);
    return state;
}

fn readSection(r: *ByteReader, found: *ReadSections) Error!void {
    const tag: SectionTag = @fromBackingInt(@intCast(try r.int(u8)));
    const len = try r.int(u32);
    const payload = try r.take(len);
    switch (tag) {
        .board => {
            if (payload.len != BOARD_SIZE) return error.InvalidSaveFile;
            found.flat = payload[0..BOARD_SIZE].*;
        },
        .givens => {
            if (payload.len != GIVENS_SIZE) return error.InvalidSaveFile;
            found.given_bits = try readMask(payload[0..GIVENS_SIZE]);
        },
        .history => found.history = payload,
        .status => found.status = payload,
        .marks => {
            if (payload.len != MARKS_SIZE) return error.InvalidSaveFile;
            for (&found.marks, 0..) |*plane, k| plane.* = try readMask(payload[k * GIVENS_SIZE ..][0..GIVENS_SIZE]);
        },
        // Written by a newer app: skip it so the rest of the game still opens.
        _ => {},
    }
}

/// Rebuild history from its section. Skipped entries don't count toward the undo pointer.
fn readHistory(history: *mutation_history.MutationHistory, payload: []const u8) Error!void {
    var r = ByteReader{ .buf = payload };
    const file_pointer = try r.int(u16);
    var file_index: usize = 0;
    var pointer: usize = 0;
    while (!r.atEnd()) : (file_index += 1) {
        const tag: EntryTag = @fromBackingInt(@intCast(try r.int(u8)));
        const len = try r.int(u8);
        const entry = try r.take(len);
        const known = try readEntry(history, tag, entry);
        if (known and file_index < file_pointer) pointer += 1;
    }
    if (file_pointer > file_index) return error.InvalidSaveFile;
    history.pointer = pointer;
}

/// Append one entry; false when the tag is unknown and the entry was skipped.
fn readEntry(history: *mutation_history.MutationHistory, tag: EntryTag, entry: []const u8) Error!bool {
    switch (tag) {
        .cell => {
            if (entry.len != CELL_ENTRY_SIZE) return error.InvalidSaveFile;
            const row = highNibble(entry[0]);
            const col = lowNibble(entry[0]);
            if (row >= board.DIMENSION_SIZE or col >= board.DIMENSION_SIZE) return error.InvalidSaveFile;
            try history.push(row, col, try cellValue(highNibble(entry[1])), try cellValue(lowNibble(entry[1])));
            return true;
        },
        .solve => {
            if (entry.len != SOLVE_ENTRY_SIZE) return error.InvalidSaveFile;
            var flat: [BOARD_SIZE]u8 = undefined;
            @memcpy(&flat, entry[GIVENS_SIZE..][0..BOARD_SIZE]);
            for (flat) |v| _ = try cellValue(v);
            try history.pushSolve(.{
                .given_bits = try readMask(entry[0..GIVENS_SIZE]),
                .flat = flat,
            });
            return true;
        },
        .mark => {
            if (entry.len != MARK_ENTRY_SIZE) return error.InvalidSaveFile;
            const row = highNibble(entry[0]);
            const col = lowNibble(entry[0]);
            if (row >= board.DIMENSION_SIZE or col >= board.DIMENSION_SIZE) return error.InvalidSaveFile;
            const digit = try cellValue(highNibble(entry[1]));
            if (digit == .zero) return error.InvalidSaveFile;
            try history.pushMark(.{ .row = row, .col = col, .digit = digit, .old_value = try cellValue(lowNibble(entry[1])) });
            return true;
        },
        _ => return false,
    }
}

/// A stored cell mask (givens or a mark plane), refused when a bit beyond the last cell is set.
fn readMask(bytes: *const [GIVENS_SIZE]u8) Error!board.CellMask {
    return std.math.cast(board.CellMask, std.mem.readInt(u128, bytes, .little)) orelse error.InvalidSaveFile;
}

fn highNibble(byte: u8) u4 {
    return @intCast(byte >> NIBBLE_BITS);
}

fn lowNibble(byte: u8) u4 {
    return @intCast(byte & NIBBLE_MASK);
}

fn cellValue(raw: u8) Error!cell.CellValue {
    if (raw > MAX_CELL_VALUE) return error.InvalidSaveFile;
    return cell.rawToCellValue(raw);
}

// ---------------------------------------------------------------------------
// Tests (co-located)
// ---------------------------------------------------------------------------

/// A default-puzzle state with three cell edits, the pointer after the second, and a status.
fn sampleState(hist: *mutation_history.MutationHistory) !state_mod.State {
    var b = try board.fromPuzzle(_puzzle_gen.PuzzleGen.default());
    try b.setCell(0, 2, .seven);
    try hist.push(0, 2, .zero, .seven);
    try b.setCell(1, 1, .three);
    try hist.push(1, 1, .zero, .three);
    try b.setCell(4, 4, .one);
    try hist.push(4, 4, .zero, .one);
    hist.pointer = 2;
    var st = state_mod.State{ .board = b, .history = hist.* };
    st.status.append("status line 1");
    return st;
}

fn expectSameHistory(want: mutation_history.MutationHistory, got: mutation_history.MutationHistory) !void {
    try std.testing.expectEqual(want.pointer, got.pointer);
    try std.testing.expectEqual(want.entries.items.len, got.entries.items.len);
    for (want.entries.items, got.entries.items) |w, g| {
        try std.testing.expectEqualDeep(w, g);
    }
}

/// Bytes of a section: tag, little-endian length, payload.
fn appendSection(list: *std.ArrayList(u8), tag: u8, payload: []const u8) !void {
    try list.append(std.testing.allocator, tag);
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(payload.len), .little);
    try list.appendSlice(std.testing.allocator, &len);
    try list.appendSlice(std.testing.allocator, payload);
}

test "save round-trip keeps board, givens, history with pointer, and status" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    const st = try sampleState(&hist);
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try fromSaveFormat(std.testing.allocator, buf);
    defer loaded.history.deinit();
    try std.testing.expect(board.equal(st.board, loaded.board));
    try expectSameHistory(st.history, loaded.history);
    try std.testing.expectEqualStrings("status line 1", loaded.status.optional().?);
}

test "save round-trip keeps a solve entry" {
    var b = try board.fromPuzzle(_puzzle_gen.PuzzleGen.easy());
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    try b.setCell(0, 0, .four);
    try hist.push(0, 0, .zero, .four);
    try hist.pushSolve(.{ .given_bits = b.given_bits, .flat = board.toFlat(b) });
    const st = state_mod.State{ .board = b, .history = hist };

    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);
    var loaded = try fromSaveFormat(std.testing.allocator, buf);
    defer loaded.history.deinit();
    try expectSameHistory(st.history, loaded.history);
}

test "header is magic, version 1 and the section count" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    const st = state_mod.State{ .board = try board.fromPuzzle(_puzzle_gen.PuzzleGen.easy()), .history = hist };
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqualStrings("SUD0", buf[0..4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[4..6], .little));
    try std.testing.expectEqual(SECTION_COUNT, std.mem.readInt(u16, buf[6..8], .little));
}

test "status is stored at its own length, not padded" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    var st = state_mod.State{ .board = try board.fromPuzzle(_puzzle_gen.PuzzleGen.easy()), .history = hist };
    const empty = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(empty);
    st.status.append("abc");
    const with_text = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(with_text);
    try std.testing.expectEqual(empty.len + 3, with_text.len);
}

test "an unknown section is skipped and the rest of the game opens" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    const st = try sampleState(&hist);
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, buf[0..HEADER_SIZE]);
    std.mem.writeInt(u16, list.items[6..8], SECTION_COUNT + 1, .little);
    try appendSection(&list, 200, "from a newer app");
    try list.appendSlice(std.testing.allocator, buf[HEADER_SIZE..]);

    var loaded = try fromSaveFormat(std.testing.allocator, list.items);
    defer loaded.history.deinit();
    try std.testing.expect(board.equal(st.board, loaded.board));
    try expectSameHistory(st.history, loaded.history);
}

test "an unknown history entry is skipped and does not count toward the pointer" {
    const b = try board.fromPuzzle(_puzzle_gen.PuzzleGen.default());
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(std.testing.allocator);
    // pointer 2 covers the unknown entry and the cell entry after it
    try history.appendSlice(std.testing.allocator, &.{ 2, 0 });
    try history.appendSlice(std.testing.allocator, &.{ 99, 3, 'x', 'y', 'z' });
    try history.appendSlice(std.testing.allocator, &.{ @backingInt(EntryTag.cell), CELL_ENTRY_SIZE, packNibbles(0, 2), packNibbles(0, 7) });

    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    try file.appendSlice(std.testing.allocator, &SaveFileMagic);
    try file.appendSlice(std.testing.allocator, &.{ 1, 0, 3, 0 });
    try appendSection(&file, @backingInt(SectionTag.board), &board.toFlat(b));
    var givens: [GIVENS_SIZE]u8 = undefined;
    std.mem.writeInt(u128, &givens, b.given_bits, .little);
    try appendSection(&file, @backingInt(SectionTag.givens), &givens);
    try appendSection(&file, @backingInt(SectionTag.history), history.items);

    var loaded = try fromSaveFormat(std.testing.allocator, file.items);
    defer loaded.history.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.history.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.history.pointer);
    try std.testing.expectEqual(cell.CellValue.seven, loaded.history.entries.items[0].cell.new_value);
}

test "every truncation of a save is refused, never a crash" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    const st = try sampleState(&hist);
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);
    for (0..buf.len) |cut| {
        try std.testing.expectError(error.InvalidSaveFile, fromSaveFormat(std.testing.allocator, buf[0..cut]));
    }
}

test "a section whose length runs past the end is refused" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    const st = try sampleState(&hist);
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);
    const len_at = HEADER_SIZE + @sizeOf(u8);
    std.mem.writeInt(u32, buf[len_at..][0..4], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidSaveFile, fromSaveFormat(std.testing.allocator, buf));
}

test "an unknown version is refused, including old files that read as version 0" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    const st = try sampleState(&hist);
    const buf = try toSaveFormat(&st, std.testing.allocator);
    defer std.testing.allocator.free(buf);

    std.mem.writeInt(u16, buf[4..6], 2, .little);
    try std.testing.expectError(error.IncompatibleVersion, fromSaveFormat(std.testing.allocator, buf));
    // A pre-section file: magic, major 0, minor 0, patch 3, ...
    const old_header = SaveFileMagic ++ [_]u8{ 0, 0, 3, 0, 0, 0, 0 };
    try std.testing.expectError(error.IncompatibleVersion, fromSaveFormat(std.testing.allocator, &old_header));
}

test "a cell entry with an out-of-range value is refused" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    try std.testing.expectError(error.InvalidSaveFile, readEntry(&hist, .cell, &.{ packNibbles(0, 0), packNibbles(0, 12) }));
    try std.testing.expectError(error.InvalidSaveFile, readEntry(&hist, .cell, &.{ packNibbles(9, 0), packNibbles(0, 1) }));
}

test "a givens mask with a bit beyond the last cell is refused" {
    const b = try board.fromPuzzle(_puzzle_gen.PuzzleGen.default());
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    try file.appendSlice(std.testing.allocator, &SaveFileMagic);
    try file.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });
    try appendSection(&file, @backingInt(SectionTag.board), &board.toFlat(b));
    var givens: [GIVENS_SIZE]u8 = undefined;
    std.mem.writeInt(u128, &givens, @as(u128, b.given_bits) | (@as(u128, 1) << board.CELL_COUNT), .little);
    try appendSection(&file, @backingInt(SectionTag.givens), &givens);

    try std.testing.expectError(error.InvalidSaveFile, fromSaveFormat(std.testing.allocator, file.items));
}

test "save round-trip keeps pencil marks and a mark toggle" {
    var hist = mutation_history.MutationHistory.init(std.testing.allocator);
    defer hist.deinit();
    var state = try sampleState(&hist);
    state.board.toggleMark(0, 3, .two);
    state.board.toggleMark(8, 8, .nine);
    try state.history.pushMark(.{ .row = 0, .col = 3, .digit = .two, .old_value = .zero });
    try state.history.pushMark(.{ .row = 4, .col = 4, .digit = .nine, .old_value = .one });

    const buf = try toSaveFormat(&state, std.testing.allocator);
    defer std.testing.allocator.free(buf);
    var loaded = try fromSaveFormat(std.testing.allocator, buf);
    defer loaded.history.deinit();

    try std.testing.expectEqual(state.board.mark_bits, loaded.board.mark_bits);
    try expectSameHistory(state.history, loaded.history);
}

test "a save without a marks section opens with no marks" {
    const b = try board.fromPuzzle(_puzzle_gen.PuzzleGen.default());
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    try file.appendSlice(std.testing.allocator, &SaveFileMagic);
    try file.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });
    try appendSection(&file, @backingInt(SectionTag.board), &board.toFlat(b));
    var givens: [GIVENS_SIZE]u8 = undefined;
    std.mem.writeInt(u128, &givens, b.given_bits, .little);
    try appendSection(&file, @backingInt(SectionTag.givens), &givens);

    var loaded = try fromSaveFormat(std.testing.allocator, file.items);
    defer loaded.history.deinit();
    for (loaded.board.mark_bits) |plane| try std.testing.expectEqual(@as(board.CellMask, 0), plane);
}
