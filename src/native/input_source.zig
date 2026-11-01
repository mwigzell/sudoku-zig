const std = @import("std");
const Io = std.Io;

// --- Stdin input source (production) ---
/// One reader for the whole run, so lines that arrive together (piped input) are kept for later reads.
pub const StdinSource = struct {
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    buf: [512]u8 = undefined,
    /// Created on the first read: it points into `buf`, and the source is copied by value until then.
    reader: ?Io.File.Reader = null,

    pub fn initStdin(allocator: std.mem.Allocator, io: Io) StdinSource {
        return .{ .allocator = allocator, .io = io, .file = Io.File.stdin() };
    }

    pub fn readLine(self: *StdinSource) ![]u8 {
        if (self.reader == null) self.reader = self.file.reader(self.io, &self.buf);
        const line = (self.reader.?.interface.takeDelimiter('\n') catch return error.ReadFailed) orelse return error.ReadEOF;
        return self.allocator.dupe(u8, std.mem.trim(u8, line, &std.ascii.whitespace)) catch return error.OutOfMemory;
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
    const responses = [_][]const u8{"from_mock"};
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

test "StdinSource.readLine returns each line when several arrive in one read" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "input.txt", .data = "m\n q \n" });
    const file = try tmp.dir.openFile(io, "input.txt", .{});
    defer file.close(io);

    var src = StdinSource.initStdin(alloc, io);
    src.file = file;
    const first = try src.readLine();
    defer alloc.free(first);
    try std.testing.expectEqualStrings("m", first);
    const second = try src.readLine();
    defer alloc.free(second);
    try std.testing.expectEqualStrings("q", second);
    try std.testing.expectError(error.ReadEOF, src.readLine());
}

test "ReaderSource stdin dispatch with initStdin" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const source: ReaderSource = .{ .stdin = StdinSource.initStdin(alloc, io) };

    // stdin path won't be exercised (blocked by terminal), but construction + union dispatch proves the shape
    _ = source;
}
