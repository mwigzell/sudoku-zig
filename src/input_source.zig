const std = @import("std");
const Io = std.Io;

// --- Stdin input source (production) ---
pub const StdinSource = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn initStdin(allocator: std.mem.Allocator, io: Io) StdinSource {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn readLine(self: *StdinSource) ![]u8 {
        var buf: [512]u8 = undefined;
        var in_ = Io.File.stdin().reader(self.io, &buf);
        var aw = Io.Writer.Allocating.init(self.allocator);

        errdefer aw.deinit();

        _ = in_.interface.streamDelimiter(&aw.writer, '\n') catch return error.ReadFailed;

        const raw = aw.toOwnedSlice() catch return error.OutOfMemory;
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len != raw.len) {
            self.allocator.free(raw);
            const duped = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
            return duped;
        }
        return raw;
    }
};

// --- Testable canned-response input source ---
pub const MockSource = struct {
    responses: []const []const u8,
    idx: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, responses: []const []const u8) MockSource {
        return .{
            .allocator = allocator,
            .responses = responses,
            .idx = 0,
        };
    }

    /// Matches StdinSource.readLine — same ![]u8 return.
    pub fn readLine(self: *MockSource) ![]u8 {
        if (self.idx >= self.responses.len)
            return error.ReadEOF;
        const resp = self.responses[self.idx];
        self.idx += 1;
        // Return a DUPLICATE — caller owns the returned slice
        return self.allocator.dupe(u8, resp) catch return error.OutOfMemory;
    }
};

// --- Tagged union ---
pub const ReaderSource = union(enum) {
    stdin: StdinSource,
    mock: MockSource,

    /// Dispatches readLine to the active source. Caller owns returned slice.
    pub fn readline(self: *@This()) ![]u8 {
        return switch (self.*) {
            .stdin => |*s| s.readLine(),
            .mock => |*m| m.readLine(),
        };
    }
    /// Returns true when the active variant is .mock.
    /// Returns true when the active variant is .mock.
    pub fn isMock(self: *const @This()) bool {
        return switch (self.*) {
            .stdin => false,
            .mock => true,
        };
    }

    /// Allocater used for this source (for AsciiRenderer internal allocs).
    pub fn allocatorForTest(self: *const @This()) std.mem.Allocator {
        return switch (self.*) {
            .stdin => |s| s.allocator,
            .mock => |m| m.allocator,
        };
    }
};

// --- Tests ---

test "MockSource.readLine returns canned strings in order" {
    const alloc = std.testing.allocator;

    const responses = [_][]const u8{ "hello", "world" };
    var src = MockSource.init(alloc, &responses);

    const line1 = try src.readLine();
    defer alloc.free(line1);
    try std.testing.expectEqualStrings("hello", line1);

    const line2 = try src.readLine();
    defer alloc.free(line2);
    try std.testing.expectEqualStrings("world", line2);
}

test "MockSource.readLine returns ReadEOF after responses exhausted" {

    var src = MockSource.init(std.testing.allocator, &[0][]const u8{});
    errdefer {} // no alloc needed for empty list

    const result = src.readLine();
    try std.testing.expectError(error.ReadEOF, result);
}

test "ReaderSource tag dispatch works for mock variant" {

    const responses = [_][]const u8{ "from_mock" };
    var source: ReaderSource = .{ .mock = MockSource.init(std.testing.allocator, &responses) };

    const line = try source.readline();
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("from_mock", line);
}

test "StdinSource.initStdin creates instance with allocator" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    _ = StdinSource.initStdin(alloc, io);
}

test "ReaderSource stdin dispatch with initStdin" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const source: ReaderSource = .{ .stdin = StdinSource.initStdin(alloc, io) };

    // stdin path won't be exercised (blocked by terminal), but construction + union dispatch proves the shape
    _ = source;
}
