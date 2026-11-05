// In-memory file transport for shell tests: files live in a map, so a test controls what is
// there, which writes and reads fail, and sees every write the shell made.
const std = @import("std");
const file_transport = @import("file_transport.zig");

/// Bare names resolve under `DIR`, absolute paths stay as given.
pub const MemoryTransport = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMap([]u8),
    /// Paths written through the transport, in order (setup `put`s are not recorded).
    written: std.ArrayListUnmanaged([]u8) = .empty,
    /// File names (compared by base name) whose writes fail.
    fail_writes: []const []const u8 = &.{},
    /// File names (compared by base name) whose reads fail.
    fail_reads: []const []const u8 = &.{},

    /// Folder bare names resolve into.
    pub const DIR = "/virtual";

    /// Empty store; files are owned copies.
    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{ .gpa = gpa, .files = std.StringHashMap([]u8).init(gpa) };
    }

    /// Frees every stored file and recorded write path.
    pub fn deinit(self: *@This()) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.files.deinit();
        self.clearWritten();
        self.written.deinit(self.gpa);
    }

    /// Forget the writes recorded so far.
    pub fn clearWritten(self: *@This()) void {
        for (self.written.items) |path| self.gpa.free(path);
        self.written.clearRetainingCapacity();
    }

    /// Seeds a file at `path` (an owned copy) without recording a write.
    pub fn put(self: *@This(), path: []const u8, bytes: []const u8) !void {
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        const value = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(value);
        const found = self.files.getEntry(path);
        if (found) |existing| {
            self.gpa.free(existing.key_ptr.*);
            self.gpa.free(existing.value_ptr.*);
            existing.key_ptr.* = key;
            existing.value_ptr.* = value;
            return;
        }
        try self.files.put(key, value);
    }

    /// Transport seam backed by this store.
    pub fn asTransport(self: *@This()) file_transport.FileTransport {
        return .{
            .context = @ptrCast(@alignCast(self)),
            .write = write,
            .readAll = readAll,
            .resolve = resolve,
            .free = free,
        };
    }

    fn asSelf(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }

    fn listed(names: []const []const u8, path: []const u8) bool {
        for (names) |name| if (std.mem.eql(u8, name, std.fs.path.basename(path))) return true;
        return false;
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) file_transport.TransportError!void {
        const self = asSelf(ctx);
        if (listed(self.fail_writes, path)) return file_transport.TransportError.System;
        self.put(path, bytes) catch return file_transport.TransportError.OutOfMemory;
        const logged = self.gpa.dupe(u8, path) catch return file_transport.TransportError.OutOfMemory;
        self.written.append(self.gpa, logged) catch {
            self.gpa.free(logged);
            return file_transport.TransportError.OutOfMemory;
        };
    }

    fn readAll(ctx: *anyopaque, path: []const u8) file_transport.TransportError![]u8 {
        const self = asSelf(ctx);
        const bytes = self.files.get(path) orelse return file_transport.TransportError.FileNotFound;
        if (listed(self.fail_reads, path)) return file_transport.TransportError.System;
        return self.gpa.dupe(u8, bytes) catch return file_transport.TransportError.OutOfMemory;
    }

    fn resolve(ctx: *anyopaque, name: []const u8) file_transport.TransportError![]u8 {
        const self = asSelf(ctx);
        if (std.mem.startsWith(u8, name, "/")) {
            return self.gpa.dupe(u8, name) catch return file_transport.TransportError.OutOfMemory;
        }
        return std.fmt.allocPrint(self.gpa, DIR ++ "/{s}", .{name}) catch return file_transport.TransportError.OutOfMemory;
    }

    fn free(ctx: *anyopaque, buf: []u8) void {
        const self = asSelf(ctx);
        self.gpa.free(buf);
    }
};
