const std = @import("std");
const board = @import("board.zig");
const cell = @import("cell.zig");

// Moved to src/event.zig, re-exported for backward compat
const event = @import("event.zig");
pub const Event = event.Event;
// Step 3 — context-aware command availability
pub const AvailableCommands = struct {
    fill: bool,
    clear: bool,
    quit: bool,
    undo: bool,
    redo: bool,
};
// Step 3 — binary save file format
pub const SaveFileMagic = [_]u8{ 'S', 'U', 'D', '0' };
pub const SaveFileVersion: u8 = 1;

pub const SaveFileHeader = struct {
    magic:         [4]u8,   // "SUD0"
    version_major: u8,
    version_minor: u8,
    version_patch: u8,
    pointer:       u16,
    entry_count:   u16,
};

pub const SaveFileTrailer = struct {
    given_bits:  u128,
    flat_board:  [81]u8,
};

const SAVE_HEADER_SIZE: usize = 11; // magic(4) + ver_major(1) + ver_minor(1) + ver_patch(1) + pointer(2) + entry_count(2)
const SAVE_TRAILER_SIZE: usize = 97; // given_bits(16) + flat_board(81)

/// Write a SaveFileHeader as exactly 11 bytes into buf.
fn writeSaveHeader(buf: []u8, header: *const SaveFileHeader) void {
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
fn readSaveHeader(buf: []const u8) SaveFileHeader {
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
fn writeSaveTrailer(buf: []u8, trailer: *const SaveFileTrailer) void {
    const bytes = std.mem.toBytes(trailer.given_bits);
    @memcpy(buf[0..16], &bytes);
    @memcpy(buf[16..97], &trailer.flat_board);
}

/// Read a SaveFileTrailer from exactly 97 bytes.
fn readSaveTrailer(buf: []const u8) SaveFileTrailer {
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
pub const TestStruct = struct {};

// Moved to src/undo.zig, re-exported for backward compat
const undo = @import("undo.zig");
pub const MutationEntry = undo.MutationEntry;
pub const MutationHistory = undo.MutationHistory;


pub const GameEngine = struct {
    board: board.Board,
    history: MutationHistory,

    /// Construct from a one-line puzzle string.
    pub fn init(puzzle_str: []const u8) board.BoardError!@This() {
        var self = @This(){
            .board = try board.fromOneLineString(puzzle_str),
            .history = MutationHistory.init(std.heap.page_allocator),
        };
        self.board.validate();
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.history.deinit();
    }

    /// Return a snapshot of the current board view.
    pub fn eventBoard(self: *@This()) board.Board.BoardView {
        return self.board.asView();
    }

    /// Which commands are available in the current game state.
    pub fn getAvailableCommands(self: *const @This()) AvailableCommands {
        return AvailableCommands{
            .fill = true,
            .clear = true,
            .quit = true,
            .undo = self.history.pointer > 0,
            .redo = self.history.pointer < self.history.entries.items.len,
        };
    }

    /// Serialize game state to a binary save file via an Io handle.

    pub fn saveGame(self: *const @This(), io: std.Io, path: []const u8) anyerror!void {
        const buf = try self.toSaveFormat(std.heap.page_allocator);
        defer std.heap.page_allocator.free(buf);

        var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try std.Io.File.writeStreamingAll(file, io, buf);
    }




    /// Serialize full game state to a heap-allocated byte buffer.
    /// Returns allocated []u8 — caller owns and must free with the same allocator.
    pub fn toSaveFormat(self: *const @This(), gpa: std.mem.Allocator) ![]u8 {
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


    /// Deserialize game state from a binary save file via an Io handle.
    pub fn openGame(self: *@This(), io: std.Io, path: []const u8) anyerror!void {
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);

        var reader_buf: [1024]u8 = undefined;
        var reader = file.reader(io, &reader_buf);

        // Read and validate magic + version
        var magic_buf: @TypeOf(SaveFileMagic) = undefined;
        _ = try reader.interface.readSliceShort(&magic_buf);
        if (!std.mem.eql(u8, &magic_buf, "SUD0")) {
            return error.InvalidSaveFile;
        }
        const version: u8 = try reader.interface.takeInt(u8, .little);
        if (version != SaveFileVersion) {
            return error.IncompatibleVersion;
        }

        // Pointer position (1 byte)
        const pointer_u8: u8 = try reader.interface.takeInt(u8, .little);
        const pointer: usize = @intCast(pointer_u8);

        // History entry count (2 bytes little-endian)
        const ecount: u16 = try reader.interface.takeInt(u16, .little);

        // Read mutation entries (2 bytes each)
        var entries = MutationHistory.init(std.heap.page_allocator);
        errdefer entries.deinit();
        for (0..ecount) |_| {
            var se_buf: [2]u8 = undefined;
            try reader.interface.readSliceAll(&se_buf);
            const coords = se_buf[0];
            const values = se_buf[1];
            try entries.push(
                @as(u4, @intCast(coords >> 4)),
                @as(u4, @intCast(coords & 0x0F)),
                cell.rawToCellValue(@as(u4, @intCast(values >> 4))),
                cell.rawToCellValue(@as(u4, @intCast(values & 0x0F))),
            );
        }

        // Given bits (u128 LE)
        const given_bits: u128 = try reader.interface.takeInt(u128, .little);

        // Board flat values (81 bytes)
        var flat_buf: [CELL_COUNT]u8 = undefined;
        try reader.interface.readSliceAll(&flat_buf);

        // Reconstruct board
        self.board = try board.fromFlat(flat_buf);
        self.board.given_bits = given_bits;
        self.history = entries;
        self.history.pointer = pointer;
    }



    /// Route a parsed command through Board mutation + render update.
    pub fn exec(self: *@This(), cmd: command.Command) anyerror!Event {
        switch (cmd) {
            .fill => |f| {
                return self.tryFill(f.row, f.col, f.digit);
            },
            .clear => |c| {
                return self.tryFill(c.row, c.col, .zero);
            },
            .quit => {
                return Event{ .ok = .{ .board_view = self.board.asView(), .msg = null } };
            },
            .undo => {
                if (self.history.pointer == 0) {
                    return Event{ .error_msg = "nothing to undo" };
                }
                self.history.pointer -= 1;
                const entry = self.history.entries.items[self.history.pointer];
                self.board.setCell(entry.row, entry.col, entry.old_value) catch |err| {
                    var buf: [80]u8 = undefined;
                    return Event{ .error_msg = std.fmt.bufPrint(&buf, "undo fail: {s}", .{@errorName(err)}) catch "undo failed" };
                };
                self.board.refreshConflictsForCell(entry.row, entry.col);
                return Event{ .ok = .{ .board_view = self.board.asView(), .msg = null } };
            },
            .redo => {
                if (self.history.pointer >= self.history.entries.items.len) {
                    return Event{ .error_msg = "nothing to redo" };
                }
                const entry = self.history.entries.items[self.history.pointer];
                // Re-apply the stored mutation (restore new_value)
                self.board.setCell(entry.row, entry.col, entry.new_value) catch |err| {
                    var buf: [80]u8 = undefined;
                    return Event{ .error_msg = std.fmt.bufPrint(&buf, "redo fail: {s}", .{@errorName(err)}) catch "redo failed" };
                };
                self.board.refreshConflictsForCell(entry.row, entry.col);
                self.history.pointer += 1;
                return Event{ .ok = .{ .board_view = self.board.asView(), .msg = null } };
            },
            else => {
                @panic("save/open handled in sudoku.zig, not exec()");
            },
        }
    }
    fn tryFill(self: *@This(), row: u4, col: u4, digit: cell.CellValue) anyerror!Event {
        // Snapshot old value before mutation (only recorded on success)
        const old_value = self.board.asView().get(row, col);
        self.board.setCell(row, col, digit) catch |err| {
            var buf: [80]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "set cell ({d},{d}) failed: {s}", .{ row, col, @errorName(err) }) catch unreachable;
            return Event{ .error_msg = msg };
        };
        // Record successful mutation into history (Step 5)
        // First discard stale future entries from any earlier undo branch
        self.history.truncateFuture();
        self.history.push(row, col, old_value, digit) catch |err| {
            var buf: [80]u8 = undefined;
            return Event{ .error_msg = std.fmt.bufPrint(&buf, "history push failed: {s}", .{@errorName(err)}) catch "history error" };
        };
        self.board.refreshConflictsForCell(row, col);
        return Event{ .ok = .{ .board_view = self.board.asView(), .msg = null } };
    }
};

const puzzle_gen = @import("puzzle_gen.zig");

fn expectOk(e: Event) !board.Board.BoardView {
    return switch (e) {
        .ok => |data| data.board_view,
        .error_msg => return error.TestFailed,
    };
}

fn expectErrorResult(e: Event) !void {
    switch (e) {
        .error_msg => {},
        .ok => return error.TestFailed,
    }
}

const command = @import("command.zig");

test "GameEngine fill updates cell value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 3));
}

test "GameEngine init builds board from puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();
    const view = engine.eventBoard();

    // puzzle[0..2] is '6' → A1 should be a given (six)
    try std.testing.expect(view.isGiven(0, 0));
    try std.testing.expectEqual(cell.CellValue.six, view.get(0, 0));

    // puzzle[2] is '.' → A3 should be non-given and empty
    try std.testing.expect(!view.isGiven(0, 2));
    try std.testing.expectEqual(cell.CellValue.zero, view.get(0, 2));
}

// T2: exec(Command) returns structured results with given-cell feedback

test "exec fill non-given cell → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
}

test "exec fill given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const result = try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 0, .digit = cell.CellValue.nine },
    });
    try expectErrorResult(result);
}

test "exec clear given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const result = try engine.exec(command.Command{
        .clear = command.ClearData{ .row = 0, .col = 0 },
    });
    try expectErrorResult(result);
}

test "exec quit → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const view = try expectOk(try engine.exec(command.Command{ .quit = {} }));
    // quit returns board_view with no message
    _ = view;
}

// T3 — exec wires validator into mutation path
// Integration chain: exec → board mutation → conflict refresh → event emission
// Check conflict bits through the returned Event board_view

test "exec fill creates conflict → cell marked" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Row 0: cells (0,2) and (0,3) are both empty — fill both with eight
    const fill1 = command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
    };

    _ = try expectOk(try engine.exec(fill1));

    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
    }));

    // Both cells in row 0 must now be flagged as conflicting
    try std.testing.expect(view.isConflictingRowCol(0, 2));
    try std.testing.expect(view.isConflictingRowCol(0, 3));

    // A cell not in the conflict path should be clean (row 5, col 5)
    try std.testing.expect(!view.isConflictingRowCol(5, 5));
}

test "exec clear resolves conflict → previously-conflicting peer now clean" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Create a row-0 conflict pair: (0,2) and (0,3) both eight
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.eight },
    }));

    {
        const view = try expectOk(try engine.exec(command.Command{
            .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.eight },
        }));
        try std.testing.expect(view.isConflictingRowCol(0, 2));
        try std.testing.expect(view.isConflictingRowCol(0, 3));
    }

    // Clear (0,3) → its peer (0,2) should no longer be flagged either
    {
        const view = try expectOk(try engine.exec(command.Command{
            .clear = command.ClearData{ .row = 0, .col = 3 },
        }));
        try std.testing.expect(!view.isConflictingRowCol(0, 2));
        try std.testing.expect(!view.isConflictingRowCol(0, 3));
    }
}

test "exec fill no conflict → no bits set" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Row 0 already has six at (0,0) and seven at (0,1).
    // Fill (0,2) with one — unique across its row, col, and box → clean.
    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
    }));

    // The filled cell must be conflict-free
    try std.testing.expect(!view.isConflictingRowCol(0, 2));

    // Row 0 cells must all be conflict-free
    for (0..board.DIMENSION_SIZE) |c| {
        const c4: u4 = @intCast(c);
        try std.testing.expect(!view.isConflictingRowCol(0, c4));
    }
    // Column 2 cells must all be conflict-free
    for (0..board.DIMENSION_SIZE) |r| {
        const r4: u4 = @intCast(r);
        try std.testing.expect(!view.isConflictingRowCol(r4, 2));
    }
}

test "init calls validate so initial conflicts are detected" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // A well-formed puzzle confirms at least that validate runs without crashing.
}

// Event union shape tests

test "Event.ok carries board_view and optional msg" {
    const puzzle_str: []const u8 = puzzle_gen.PuzzleGen.default();
    var board_inst = try board.fromOneLineString(puzzle_str);
    const view = board_inst.asView();

    _ = Event{
        .ok = .{
            .board_view = view,
            .msg = null,
        },
    };
}

test "Event.ok can carry a message" {
    const puzzle_str: []const u8 = puzzle_gen.PuzzleGen.default();
    var board_inst = try board.fromOneLineString(puzzle_str);
    const view = board_inst.asView();

    _ = Event{
        .ok = .{
            .board_view = view,
            .msg = "puzzle complete!",
        },
    };
}

test "Event.error_msg carries an error string" {
    _ = Event{
        .error_msg = "cannot modify a given cell",
    };
}

// Integration test — game engine init propagates board error from puzzle

test "GameEngine.init propagates invalid puzzle error" {
    try std.testing.expectError(
        board.BoardError.WrongLength,
        GameEngine.init("too-short"),
    );
}

test "GameEngine is non-generic, init takes only puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();
    const view = engine.eventBoard();

    // Board was built correctly from the puzzle string
    try std.testing.expect(view.isGiven(0, 0));

    // No renderer field exists (compile-time guarantee if struct is non-generic)
}

test "exec fill returns Event.ok with board_view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();
    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    // board_view reflects the mutation
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 2));
}

test "eventBoard returns current board view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const view1 = engine.eventBoard();
    // A1 is a given (six)
    try std.testing.expectEqual(cell.CellValue.six, view1.get(0, 0));

    // Mutate the board
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const view2 = engine.eventBoard();
    // A3 now reflects the fill
    try std.testing.expectEqual(cell.CellValue.seven, view2.get(0, 2));
}

// Step 2 — MutationHistory struct tests

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

test "exec undo on empty history returns .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const result = switch (try engine.exec(command.Command{ .undo = {} })) {
        .ok => return error.TestFailed,
        .error_msg => |msg| msg,
    };
    try std.testing.expectEqualStrings(result, "nothing to undo");
}

test "exec then undo reverses a fill back to zero" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Fill A3 (row 0, col 2) with seven
    const fill_view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, fill_view.get(0, 2));

    // Undo — should revert to zero
    const undo_view = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.zero, undo_view.get(0, 2));
}

test "exec then undo then redo re-applies the fill" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Fill A3 with seven
    const fill_view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, fill_view.get(0, 2));

    // Undo — should revert to zero
    const undo_view = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.zero, undo_view.get(0, 2));

    // Redo — should re-apply seven
    const redo_view = try expectOk(try engine.exec(command.Command{ .redo = {} }));
    try std.testing.expectEqual(cell.CellValue.seven, redo_view.get(0, 2));
}

test "new mutation after undo truncates future redo path" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Fill 3 cells A, B, C all on different empty cells
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    // Undo twice — back to after A only (pointer=1)
    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));

    // Now B and C cells should be empty again
    const view_after_undo = engine.eventBoard();
    try std.testing.expectEqual(cell.CellValue.zero, view_after_undo.get(1, 2));
    try std.testing.expectEqual(cell.CellValue.zero, view_after_undo.get(1, 3));

    // Make new fill D on B's cell — should truncate [B,C] from future
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.four },
    }));

    // Redo should fail (no future to redo — path was truncated)
    const redo_result = try engine.exec(command.Command{ .redo = {} });
    try expectErrorResult(redo_result);
}

test "undo clear restores previous value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Fill B1 (row 1, col 1) with three
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    }));

    // Clear B1
    const clear_view = try expectOk(try engine.exec(command.Command{
        .clear = command.ClearData{ .row = 1, .col = 1 },
    }));
    try std.testing.expectEqual(cell.CellValue.zero, clear_view.get(1, 1));

    // Undo the clear — should restore three
    const undo_view = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    try std.testing.expectEqual(cell.CellValue.three, undo_view.get(1, 1));
}

// Step 6 — remaining integration tests

test "multiple undo walks history backwards" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Fill three cells: A=one at (1,1), B=two at (1,2), C=three at (1,3)
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    // All three filled
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.three, v.get(1, 3));
    }

    // Undo #1 reverts C → (1,3) empty again
    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Undo #2 reverts B → (1,2) empty again
    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }
}

test "multiple redo walks forwards correctly" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Fill three cells: A=one at (1,1), B=two at (1,2), C=three at (1,3)
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    // Undo all three
    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #1 re-applies A → (1,1) = one
    _ = try expectOk(try engine.exec(command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #2 re-applies B → (1,2) = two
    _ = try expectOk(try engine.exec(command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.zero, v.get(1, 3));
    }

    // Redo #3 re-applies C → (1,3) = three
    _ = try expectOk(try engine.exec(command.Command{ .redo = {} }));
    {
        const v = engine.eventBoard();
        try std.testing.expectEqual(cell.CellValue.one, v.get(1, 1));
        try std.testing.expectEqual(cell.CellValue.two, v.get(1, 2));
        try std.testing.expectEqual(cell.CellValue.three, v.get(1, 3));
    }
}

test "redo on empty future returns .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Fill some cells — no undo yet, so nothing to redo
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    // Redo with nothing undone should fail
    const result = try engine.exec(command.Command{ .redo = {} });
    try expectErrorResult(result);
}

test "getAvailableCommands: fresh engine has Fill/Clear/Quit only" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const cmds = engine.getAvailableCommands();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(!cmds.redo);
}

test "getAvailableCommands: after fill Undo appears" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    const cmds = engine.getAvailableCommands();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(cmds.undo);
    try std.testing.expect(!cmds.redo);
}

test "getAvailableCommands: after undo-one-of-one Redo appears Undo disappears" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));

    const cmds = engine.getAvailableCommands();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(cmds.redo);
}

test "getAvailableCommands: after partial undo both Undo and Redo available" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));

    const cmds = engine.getAvailableCommands();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(cmds.undo);
    try std.testing.expect(cmds.redo);
}

test "getAvailableCommands: after full undo Undo hidden Redo replays" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 2, .digit = cell.CellValue.two },
    }));

    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));
    _ = try expectOk(try engine.exec(command.Command{ .undo = {} }));

    const cmds = engine.getAvailableCommands();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(cmds.redo);
}


// Step 3 — Save file format tests
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


// Step 4 — saveGame() unit tests

const CELL_COUNT = board.DIMENSION_SIZE * board.DIMENSION_SIZE;

test "saveGame writes file with correct size (empty history)" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const tmp_path = "/tmp/sudoku_test_save_empty.dat";
    _ = engine.saveGame(std.testing.io, tmp_path) catch |err| return err;

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, tmp_path, .{});

    // header: magic(4) + version(1) + pointer(1) + count(u16)=2 + given_bits(16) + cells(81) = 105
    const expected_size: usize = @as(usize, SaveFileMagic.len) + 1 + 1 + @sizeOf(u16) + @sizeOf(u128) + CELL_COUNT;
    try std.testing.expectEqual(expected_size, stat.size);

    _ = std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};
}

test "saveGame writes file with correct size (3 history entries)" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.two },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 3, .digit = cell.CellValue.three },
    }));

    const tmp_path = "/tmp/sudoku_test_save_3entries.dat";
    _ = engine.saveGame(std.testing.io, tmp_path) catch |err| return err;

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, tmp_path, .{});

    // header(6) + count(2) + 3*2 entries + given_bits(16) + cells(81) = 111
    const expected_size: usize = SaveFileMagic.len + 1 + 1 + @sizeOf(u16) + (3 * @sizeOf(SaveEntry)) + @sizeOf(u128) + CELL_COUNT;
    try std.testing.expectEqual(expected_size, stat.size);

    _ = std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};
}

test "saveGame writes correct header magic and version" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const tmp_path = "/tmp/sudoku_test_save_header.dat";
    _ = engine.saveGame(std.testing.io, tmp_path) catch |err| return err;

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, tmp_path, .{});
    defer file.close(std.testing.io);

    var header_buf: [5]u8 = undefined;
    var readerbuf: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &readerbuf);
    _ = try reader.interface.readSliceShort(&header_buf);

    try std.testing.expectEqualStrings("SUD0", header_buf[0..4]);
    try std.testing.expectEqual(@as(u8, 1), header_buf[4]);

    _ = std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};
}

test "saveGame returns error on bad path" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const result = engine.saveGame(std.testing.io, "/nonexistent/dir/save.dat");
    try std.testing.expectError(error.FileNotFound, result);
}

// Step 6 — save → open round-trip (full saved state equality)

 test "saveGame then openGame: full state round-trip equals original" {
    var original = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer original.deinit();

    // Make mutations to populate history and alter board
    _ = try expectOk(try original.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    _ = try expectOk(try original.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    }));
    _ = try expectOk(try original.exec(command.Command{
        .fill = command.FillData{ .row = 4, .col = 4, .digit = cell.CellValue.one },
    }));

    // Undo one mutation — tests that pointer position is preserved
    _ = try expectOk(try original.exec(command.Command{ .undo = {} }));

    // Save to temp file using test I/O
    const tmp_path = "/tmp/sudoku_roundtrip_test.dat";
    _ = original.saveGame(std.testing.io, tmp_path) catch |err| return err;

    // Open into a new engine
    var loaded: GameEngine = undefined; // initialised by openGame
    try loaded.openGame(std.testing.io, tmp_path);
    defer loaded.deinit();

    // --- Assert DIMENSION 1: board cell values (all 81) ---
    const orig_view = original.eventBoard();
    const load_view = loaded.eventBoard();
    for (0..CELL_COUNT) |i| {
        const row: u4 = @intCast(@divTrunc(i, board.DIMENSION_SIZE));
        const col: u4 = @intCast(@mod(i, board.DIMENSION_SIZE));
        try std.testing.expectEqual(
            orig_view.get(row, col),
            load_view.get(row, col),
        );
    }

    // --- Assert DIMENSION 2: given_bits (explicitly written, not re-derived) ---
    try std.testing.expectEqual(original.board.given_bits, loaded.board.given_bits);

    // --- Assert DIMENSION 3: history pointer position ---
    try std.testing.expectEqual(
        original.history.pointer,
        loaded.history.pointer,
    );

    // --- Assert DIMENSION 4: history entries count + contents ---
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

// Step 3 — SaveFileHeader & SaveFileTrailer struct tests

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

// Step 4 — toSaveFormat / fromSaveFormat (in-memory blob serialization)

test "toSaveFormat empty history produces buffer of correct size" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const buf = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    // header(11) + 0 entries + trailer(97) = 108
    try std.testing.expectEqual(@as(usize, SAVE_HEADER_SIZE + SAVE_TRAILER_SIZE), buf.len);
}


test "toSaveFormat header has correct magic and version" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    const buf = try engine.toSaveFormat(std.testing.allocator);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default());
    defer engine.deinit();

    // Make 3 mutations
    // Make 3 mutations (same as existing round-trip test)
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    }));
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 4, .col = 4, .digit = cell.CellValue.one },
    }));



    const buf = try engine.toSaveFormat(std.testing.allocator);
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

