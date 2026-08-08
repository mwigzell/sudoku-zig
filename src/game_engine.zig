const std = @import("std");
const board = @import("board.zig");
const cell = @import("cell.zig");
const command = @import("command/parse.zig");

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
    save: bool,
    open: bool,
    new: bool,
    save_as: bool,

    /// Fill `names` with the active command labels and return the count.
    /// Caller owns the buffer; the strings point at comptime literals.
    pub fn getNames(self: AvailableCommands, names: *[9][]const u8) usize {
        var count: usize = 0;
        if (self.fill) { names[count] = command.getName(.fill); count += 1; }
        if (self.clear) { names[count] = command.getName(.clear); count += 1; }
        if (self.quit) { names[count] = command.getName(.quit); count += 1; }
        if (self.undo) { names[count] = command.getName(.undo); count += 1; }
        if (self.redo) { names[count] = command.getName(.redo); count += 1; }
        if (self.save) { names[count] = command.getName(.save); count += 1; }
        if (self.open) { names[count] = command.getName(.open); count += 1; }
        if (self.new) { names[count] = command.getName(.new); count += 1; }
        if (self.save_as) { names[count] = command.getName(.save_as); count += 1; }
        return count;
    }
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

// Moved to src/command/mutation_history.zig, re-exported for backward compat
const mutation_history = @import("command/mutation_history.zig");
const fill_command = @import("command/fill.zig");
const clear_command = @import("command/clear.zig");
const undo_command = @import("command/undo.zig");
const redo_command = @import("command/redo.zig");
const quit_command = @import("command/quit.zig");
const save_command = @import("command/save.zig");
const open_command = @import("command/open.zig");
const save_as_command = @import("command/save_as.zig");
const mypath = @import("command/path.zig");
pub const MutationEntry = mutation_history.MutationEntry;
pub const MutationHistory = mutation_history.MutationHistory;


pub const GameEngine = struct {
    board: board.Board,
    history: MutationHistory,
    io: std.Io,
    data_dir: ?[]u8,
    last_save_msg: ?[]u8,
    /// Construct from a one-line puzzle string.
    pub fn init(puzzle_str: []const u8, io: std.Io) board.BoardError!@This() {
        var self = @This(){
            .board = try board.fromOneLineString(puzzle_str),
            .history = MutationHistory.init(std.heap.page_allocator),
            .io = io,
            .data_dir = null,
            .last_save_msg = null,
        };
        self.board.validate();
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.history.deinit();

        // Free optional string fields
        if (self.data_dir) |dir| std.heap.page_allocator.free(dir);
        if (self.last_save_msg) |msg| std.heap.page_allocator.free(msg);
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
            .save = true,
            .open = true,
            .new = true,
            .save_as = true,
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
    /// Deserialize from a toSaveFormat blob into a fresh GameEngine.
    pub fn fromSaveFormat(gpa: std.mem.Allocator, io: std.Io, buf: []const u8) !GameEngine {
        const header = readSaveHeader(buf[0..SAVE_HEADER_SIZE]);
        if (!std.mem.eql(u8, &header.magic, "SUD0")) {
            return error.InvalidSaveFile;
        }
        if (header.version_patch != SaveFileVersion) {
            return error.IncompatibleVersion;
        }

        const offset = SAVE_HEADER_SIZE;
        var history = MutationHistory.init(gpa);
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
        var engine = GameEngine{
            .board = try board.fromFlat(trailer.flat_board, .{ .given_bits = trailer.given_bits }),
            .history = history,
            .io = io,
            .data_dir = null,
            .last_save_msg = null,
        };

        engine.history.pointer = header.pointer;

        return engine;
    }

    /// Deserialize game state from a binary save file via an Io handle.
    pub fn openGame(self: *@This(), io: std.Io, path: []const u8) anyerror!void {
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);

        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        const buf = try std.heap.page_allocator.alloc(u8, stat.size);
        defer std.heap.page_allocator.free(buf);

        _ = try std.Io.File.readPositionalAll(file, io, buf, 0);

        const loaded = try GameEngine.fromSaveFormat(std.heap.page_allocator, io, buf);
        self.history.deinit();
        const old_board = self.board;
        self.* = loaded;
        _ = old_board;
    }



    /// Route a parsed command through Board mutation + render update.
    pub fn exec(self: *@This(), cmd: command.Command) anyerror!Event {
        switch (cmd) {
            .fill => |f| {
                return fill_command.execute(self, f);
            },
            .clear => |c| {
                return clear_command.execute(self, c);
            },
            .quit => {
                return quit_command.execute(self);
            },
            .undo => {
                return undo_command.execute(self);
            },
            .redo => {
                return redo_command.execute(self);
            },
            .save => |data| {
                return save_command.execute(self, data.path);
            },
            .open => |data| {
                return open_command.execute(self, data.path);
            },
            .new => {
                return Event{
                    .ok = .{
                        .board_view = self.board.asView(),
                        .msg = "New game not yet implemented",
                        .is_quit = false,
                    },
                };
            },
            .save_as => |data| {
                return save_as_command.execute(self, data.path);
            }
        }
    }

    /// Attempt to fill a cell with a digit. Records mutation in history.
    pub fn tryFill(self: *@This(), row: u4, col: u4, digit: cell.CellValue) anyerror!Event {
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
        return Event{ .ok = .{ .board_view = self.board.asView(), .msg = null, .is_quit = false } };
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


test "GameEngine fill updates cell value" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 3, .digit = cell.CellValue.seven },
    }));
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 3));
}

test "GameEngine init builds board from puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
}

test "exec fill given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const result = try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 0, .digit = cell.CellValue.nine },
    });
    try expectErrorResult(result);
}

test "exec clear given cell → .error_msg" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const result = try engine.exec(command.Command{
        .clear = command.ClearData{ .row = 0, .col = 0 },
    });
    try expectErrorResult(result);
}

test "exec quit → .ok" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const view = try expectOk(try engine.exec(command.Command{ .quit = {} }));
    // quit returns board_view with no message
    _ = view;
}

// T3 — exec wires validator into mutation path
// Integration chain: exec → board mutation → conflict refresh → event emission
// Check conflict bits through the returned Event board_view

test "exec fill creates conflict → cell marked" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
            .is_quit = false,
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
            .is_quit = false,
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
        GameEngine.init("too-short", std.testing.io),
    );
}

test "GameEngine is non-generic, init takes only puzzle string" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();
    const view = engine.eventBoard();

    // Board was built correctly from the puzzle string
    try std.testing.expect(view.isGiven(0, 0));

    // No renderer field exists (compile-time guarantee if struct is non-generic)
}

test "exec fill returns Event.ok with board_view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();
    const view = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    // board_view reflects the mutation
    try std.testing.expectEqual(cell.CellValue.seven, view.get(0, 2));
}

test "eventBoard returns current board view" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const result = switch (try engine.exec(command.Command{ .undo = {} })) {
        .ok => return error.TestFailed,
        .error_msg => |msg| msg,
    };
    try std.testing.expectEqualStrings(result, "nothing to undo");
}

test "exec then undo reverses a fill back to zero" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const cmds = engine.getAvailableCommands();
    try std.testing.expect(cmds.fill);
    try std.testing.expect(cmds.clear);
    try std.testing.expect(cmds.quit);
    try std.testing.expect(!cmds.undo);
    try std.testing.expect(!cmds.redo);
}

test "getAvailableCommands: after fill Undo appears" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
test "getAvailableCommands: Save and Open always available" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const cmds = engine.getAvailableCommands();
    // Save and Open are always available like Fill/Clear/Quit (not state-contingent)
    try std.testing.expect(cmds.save);
    try std.testing.expect(cmds.open);
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

test "saveGame returns error on bad path" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const result = engine.saveGame(std.testing.io, "/nonexistent/dir/save.sud");
    try std.testing.expectError(error.FileNotFound, result);
}

// Step 6 — save → open round-trip (full saved state equality)

 test "saveGame then openGame: full state round-trip equals original" {
    var original = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    const tmp_path = "/tmp/sudoku_roundtrip_test.sud";
    _ = original.saveGame(std.testing.io, tmp_path) catch |err| return err;

    // Open into a new engine
    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    try loaded.openGame(std.testing.io, tmp_path);
    defer loaded.deinit();

    // --- Assert board state (cells + given_bits) via Board.equal() ---
    try std.testing.expect(original.board.equal(loaded.board));

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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    const buf = try engine.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    // header(11) + 0 entries + trailer(97) = 108
    try std.testing.expectEqual(@as(usize, SAVE_HEADER_SIZE + SAVE_TRAILER_SIZE), buf.len);
}


test "toSaveFormat header has correct magic and version" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
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



test "fromSaveFormat round-trip: board state given_bits history" {
    var original = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer original.deinit();

    _ = try expectOk(try original.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    _ = try expectOk(try original.exec(command.Command{
        .fill = command.FillData{ .row = 1, .col = 1, .digit = cell.CellValue.three },
    }));
    _ = try expectOk(try original.exec(command.Command{
        .fill = command.FillData{ .row = 4, .col = 4, .digit = cell.CellValue.one },
    }));
    _ = try expectOk(try original.exec(command.Command{ .undo = {} }));

    const buf = try original.toSaveFormat(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var loaded = try GameEngine.fromSaveFormat(std.testing.allocator, std.testing.io, buf);
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



// Issue 28 Step 4 — Cycle 3: save/open command handlers via exec()
// Issue 28 Step 1 — io threaded through GameEngine constructor
test "GameEngine.init accepts io handle" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    // io field stored on struct (compile-time proof if the field exists)
    _ = engine.io;
}
// Issue 28 Step 4 — Cycle 3: save/open command handlers via exec()
test "Save fields moved to GameEngine struct" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    // Fields exist on GameEngine (compile-time proof) and start null
    try std.testing.expectEqual(@as(?[]u8, null), engine.data_dir);
}

test "exec save: delegates to save handler via command/save.zig" {
    var engine = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer engine.deinit();

    // Give a known data dir so save handler has path
    const gpa = std.heap.page_allocator;
    engine.data_dir = try mypath.getDataDir(gpa, std.testing.io);
    errdefer gpa.free(engine.data_dir.?);

    // Make a mutation to save meaningful state
    _ = try expectOk(try engine.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));

    // exec() must NOT panic on .save — it should delegate to command handler
    const result = engine.exec(command.Command{ .save = command.SaveData{ .path = "sudoku_save.sud" } }) catch return error.SkipZigTest;

    // Should return ok with message and is_quit = false
    switch (result) {
        .ok => |data| {
            try std.testing.expect(!data.is_quit);
            try std.testing.expect(data.msg != null);
        },
        .error_msg => return error.TestFailed,
    }
}

test "exec open: delegates to open handler via command/open.zig" {
    const tmp_path = "/tmp/sudoku_step4_open_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, tmp_path) catch {};

    // Create a known save file
    var original = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer original.deinit();
    _ = try expectOk(try original.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.seven },
    }));
    try original.saveGame(std.testing.io, tmp_path);

    // Now create a second engine and open through exec()
    var loaded = try GameEngine.init(puzzle_gen.PuzzleGen.default(), std.testing.io);
    defer loaded.deinit();
    _ = try expectOk(try loaded.exec(command.Command{
        .fill = command.FillData{ .row = 0, .col = 2, .digit = cell.CellValue.one },
    }));

    // exec open through .open command — must delegate to handler, not panic
    const result = loaded.exec(command.Command{ .open = command.OpenData{ .path = tmp_path } }) catch return error.SkipZigTest;

    switch (result) {
        .ok => |data| {
            try std.testing.expect(!data.is_quit);
            // Board cell (0,2) should be seven from saved state, not one (overwritten by open)
            try std.testing.expectEqual(cell.CellValue.seven, data.board_view.get(0, 2));
        },
        .error_msg => return error.TestFailed,
    }
}
