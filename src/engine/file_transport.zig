// File byte transport behind a vtable seam: write bytes to a named path,
// read a named path into a caller-freed buffer. The native arm uses std.Io
// file ops; the wasm arm (later step) will use WasmHost imports.
const std = @import("std");

pub const TransportError = error{ OutOfMemory, FileNotFound, AccessDenied, System };

pub const FileTransport = struct {
    context: *anyopaque,
    write: *const fn (ctx: *anyopaque, path: []const u8, bytes: []const u8) TransportError!void,
    readAll: *const fn (ctx: *anyopaque, path: []const u8) TransportError![]u8, // caller frees
};

test "FileTransport native: write then readAll round-trips bytes" {
    const transport = NativeTransport.make(std.testing.io);

    const path = "/tmp/sudoku_file_transport_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    const payload = "round-trip payload for the transport seam";
    transport.write(transport.context, path, payload) catch |err| return err;

    const bytes = transport.readAll(transport.context, path) catch |err| return err;
    defer std.heap.page_allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, payload, bytes);
}

test "FileTransport native: readAll of a missing file errors" {
    const transport = NativeTransport.make(std.testing.io);

    const result = transport.readAll(transport.context, "/tmp/sudoku_file_transport_missing.sud");
    try std.testing.expectError(TransportError.FileNotFound, result);
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
        };
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
};
