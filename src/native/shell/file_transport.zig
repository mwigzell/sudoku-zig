// File byte transport behind a vtable seam: write bytes to a named path,
// read a named path into a caller-freed buffer, and resolve a bare name
// against the arm's own file store. Native std.Io byte ops for session handlers.
const std = @import("std");
const mypath = @import("path.zig");

pub const TransportError = error{ OutOfMemory, FileNotFound, AccessDenied, System };

pub const FileTransport = struct {
    context: *anyopaque,
    write: *const fn (ctx: *anyopaque, path: []const u8, bytes: []const u8) TransportError!void,
    readAll: *const fn (ctx: *anyopaque, path: []const u8) TransportError![]u8,
    // Resolve a bare name against this arm's file store; returns an owned name.
    resolve: *const fn (ctx: *anyopaque, name: []const u8) TransportError![]u8,
    // Free a buffer returned by this arm's readAll or resolve; each arm frees with its own allocator.
    free: *const fn (ctx: *anyopaque, buf: []u8) void,
};

test "FileTransport native: write then readAll round-trips bytes" {
    NativeTransport.resetSession();
    defer NativeTransport.deinitSession();

    const transport = NativeTransport.make(std.testing.io);

    const path = "/tmp/sudoku_file_transport_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    const payload = "round-trip payload for the transport seam";
    transport.write(transport.context, path, payload) catch |err| return err;

    const bytes = transport.readAll(transport.context, path) catch |err| return err;
    defer transport.free(transport.context, bytes);
    try std.testing.expectEqualSlices(u8, payload, bytes);
}

test "FileTransport native: readAll of a missing file errors" {
    NativeTransport.resetSession();
    defer NativeTransport.deinitSession();

    const transport = NativeTransport.make(std.testing.io);

    const result = transport.readAll(transport.context, "/tmp/sudoku_file_transport_missing.sud");
    try std.testing.expectError(TransportError.FileNotFound, result);
}

test "FileTransport native: resolve joins a bare name against the data dir" {
    NativeTransport.resetSession();
    defer NativeTransport.deinitSession();

    const transport = NativeTransport.make(std.testing.io);

    const resolved = transport.resolve(transport.context, "game.sud") catch |err| return err;
    defer transport.free(transport.context, resolved);

    const data_dir = @import("path.zig").computeDataDir(std.heap.page_allocator) catch |err| return err;
    defer std.heap.page_allocator.free(data_dir);
    const expected = std.fmt.allocPrint(std.heap.page_allocator, "{s}/game.sud", .{data_dir}) catch |err| return err;
    defer std.heap.page_allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "FileTransport native: resolve passes an absolute path through as an owned copy" {
    NativeTransport.resetSession();
    defer NativeTransport.deinitSession();

    const transport = NativeTransport.make(std.testing.io);

    const resolved = transport.resolve(transport.context, "/abs/save.sud") catch |err| return err;
    defer transport.free(transport.context, resolved);

    try std.testing.expectEqualStrings("/abs/save.sud", resolved);
}

test "FileTransport native: resolve remembers last directory for bare names" {
    NativeTransport.resetSession();
    defer NativeTransport.deinitSession();

    const transport = NativeTransport.make(std.testing.io);

    const first = transport.resolve(transport.context, "/tmp/sudoku_transport_remember/a.sud") catch |err| return err;
    defer transport.free(transport.context, first);

    const second = transport.resolve(transport.context, "b.sud") catch |err| return err;
    defer transport.free(transport.context, second);

    try std.testing.expectEqualStrings("/tmp/sudoku_transport_remember/b.sud", second);
}

// Native arm — std.Io file ops. One process, one io handle; make() stores it
// in a module-level context that the fn pointers borrow through their ctx arg.
const Context = struct {
    io: std.Io,
    data_dir: ?[]u8 = null,
};
var context: Context = .{ .io = undefined };
const gpa = std.heap.page_allocator;

fn asContext(c: *anyopaque) *Context {
    const ctx: *Context = @ptrCast(@alignCast(c));
    return ctx;
}

pub const NativeTransport = struct {
    pub fn make(io: std.Io) FileTransport {
        context.io = io;
        return FileTransport{
            .context = &context,
            .write = write,
            .readAll = readAll,
            .resolve = resolve,
            .free = free,
        };
    }

    pub fn resetSession() void {
        deinitSession();
    }

    pub fn deinitSession() void {
        if (context.data_dir) |dir| gpa.free(dir);
        context.data_dir = null;
    }

    fn ensureDataDir(ctx: *Context) TransportError![]const u8 {
        if (ctx.data_dir) |dir| return dir;
        const dir = mypath.computeDataDir(gpa) catch |err| switch (err) {
            error.OutOfMemory => return TransportError.OutOfMemory,
            else => return TransportError.System,
        };
        ctx.data_dir = dir;
        return dir;
    }

    fn rememberDataDirFromPath(ctx: *Context, resolved_path: []const u8) TransportError!void {
        const parent = mypath.parentDir(gpa, resolved_path) catch return TransportError.OutOfMemory;
        if (ctx.data_dir) |old| {
            if (std.mem.eql(u8, old, parent)) {
                gpa.free(parent);
                return;
            }
            gpa.free(old);
        }
        ctx.data_dir = parent;
    }

    fn free(c: *anyopaque, buf: []u8) void {
        _ = c;
        gpa.free(buf);
    }
    fn write(c: *anyopaque, path: []const u8, bytes: []const u8) TransportError!void {
        const ctx = asContext(c);
        var file = std.Io.Dir.createFileAbsolute(ctx.io, path, .{}) catch return TransportError.System;
        defer file.close(ctx.io);

        std.Io.File.writeStreamingAll(file, ctx.io, bytes) catch return TransportError.System;
    }

    fn readAll(c: *anyopaque, path: []const u8) TransportError![]u8 {
        const ctx = asContext(c);
        var file = std.Io.Dir.openFileAbsolute(ctx.io, path, .{}) catch return TransportError.FileNotFound;
        defer file.close(ctx.io);

        const stat = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return TransportError.System;
        const buf = gpa.alloc(u8, stat.size) catch return TransportError.OutOfMemory;
        errdefer gpa.free(buf);

        _ = std.Io.File.readPositionalAll(file, ctx.io, buf, 0) catch return TransportError.System;
        return buf;
    }

    // Bare names join against the session data dir; absolute paths pass through.
    // Each resolve updates the remembered directory from the resolved path.
    fn resolve(c: *anyopaque, name: []const u8) TransportError![]u8 {
        const ctx = asContext(c);
        const resolved = if (name.len > 0 and name[0] == '/')
            gpa.dupe(u8, name) catch return TransportError.OutOfMemory
        else blk: {
            const data_dir = ensureDataDir(ctx) catch |err| return err;
            break :blk mypath.resolveSavePath(gpa, data_dir, name) catch return TransportError.OutOfMemory;
        };
        rememberDataDirFromPath(ctx, resolved) catch {
            gpa.free(resolved);
            return TransportError.OutOfMemory;
        };
        return resolved;
    }
};
