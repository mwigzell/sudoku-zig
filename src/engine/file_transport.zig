// File byte transport behind a vtable seam: write bytes to a named path,
// read a named path into a caller-freed buffer, and resolve a bare name
// against the arm's own file store. The native arm uses std.Io byte ops;
// the wasm arm (wasm_transport.zig) uses the page's file_write / file_read imports.
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
    const transport = NativeTransport.make(std.testing.io);

    const result = transport.readAll(transport.context, "/tmp/sudoku_file_transport_missing.sud");
    try std.testing.expectError(TransportError.FileNotFound, result);
}

test "FileTransport native: resolve joins a bare name against the data dir" {
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
    const transport = NativeTransport.make(std.testing.io);

    const resolved = transport.resolve(transport.context, "/abs/save.sud") catch |err| return err;
    defer transport.free(transport.context, resolved);

    try std.testing.expectEqualStrings("/abs/save.sud", resolved);
}

// Native arm — std.Io file ops. One process, one io handle; make() stores it
// in a module-level context that the fn pointers borrow through their ctx arg.
const Context = struct {
    io: std.Io,
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

    // Bare names join against the platform data dir; absolute paths pass straight through as owned copies.
    fn resolve(c: *anyopaque, name: []const u8) TransportError![]u8 {
        _ = asContext(c);
        const data_dir = mypath.computeDataDir(gpa) catch |err| switch (err) {
            error.OutOfMemory => return TransportError.OutOfMemory,
            else => return TransportError.System,
        };
        errdefer gpa.free(data_dir);
        return mypath.resolveSavePath(gpa, data_dir, name) catch return TransportError.OutOfMemory;
    }
};
