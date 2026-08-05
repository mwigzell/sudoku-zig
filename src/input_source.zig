const std = @import("std");
const Io = std.Io;

// --- Stdin input source (production) ---
pub const StdinSource = struct {
    pub fn readLine(self: *StdinSource, io: Io) ![]u8 {
        _ = self;
        var buf: [512]u8 = undefined;
        var in_ = Io.File.stdin().reader(io, &buf);
        const result = in_.interface.takeDelimiter('\n') catch return error.ReadFailed;
        return result orelse return error.ReadEOF;
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
    pub fn readLine(self: *MockSource, io: Io) ![]u8 {
        _ = io; // tests never call real I/O
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
    pub fn readline(self: *@This(), io: Io) ![]u8 {
        return switch (self.*) {
            .stdin => |*s| s.readLine(io),
            .mock => |*m| m.readLine(io),
        };
    }
};

// --- Tests ---

test "MockSource.readLine returns canned strings in order" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const responses = [_][]const u8{ "hello", "world" };
    var src = MockSource.init(alloc, &responses);

    const line1 = try src.readLine(io);
    defer alloc.free(line1);
    try std.testing.expectEqualStrings("hello", line1);

    const line2 = try src.readLine(io);
    defer alloc.free(line2);
    try std.testing.expectEqualStrings("world", line2);
}

test "MockSource.readLine returns ReadEOF after responses exhausted" {
    const io = std.testing.io;

    var src = MockSource.init(std.testing.allocator, &[0][]const u8{});
    errdefer {} // no alloc needed for empty list

    const result = src.readLine(io);
    try std.testing.expectError(error.ReadEOF, result);
}

test "ReaderSource tag dispatch works for mock variant" {
    const io = std.testing.io;

    const responses = [_][]const u8{ "from_mock" };
    var source: ReaderSource = .{ .mock = MockSource.init(std.testing.allocator, &responses) };

    const line = try source.readline(io);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("from_mock", line);
}
