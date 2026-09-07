// wasm arm of the FileTransport vtable — (name, bytes) across the browser
// boundary. The page supplies file_write / file_read JS imports; this arm
// holds them as fn pointers and speaks only the vtable, so it compiles in
// both deployments (never touches std.Io) and is drivable from the native
// suite with plain mock fns. WasmHost binds the real page imports for the wasm build.

const std = @import("std");
const file_transport = @import("file_transport.zig");
const TransportError = file_transport.TransportError;

// Import surface the page supplies; WasmHost binds it for the wasm build.
// Names and byte slices cross the
// boundary as pointers into wasm memory; the page owns the actual file store.
pub const FileWrite = *const fn (name: [*]const u8, name_len: u32, bytes: [*]const u8, bytes_len: u32) callconv(.c) void;
pub const FileRead = *const fn (name: [*]const u8, name_len: u32, buf: [*]u8, cap: u32) callconv(.c) u32; // bytes placed, 0 = missing
// readAll cap. Saves are far smaller; cap-sized reads are treated as truncated.
const ReadCap = 65536;
// The arm owns one static buffer — readAll returns a slice of it, so free is
// a no-op (mirrors the vtable contract: each arm frees with its own allocator).
const Context = struct {
    file_write: FileWrite,
    file_read: FileRead,
    buf: [ReadCap]u8,
};
var context: Context = .{ .file_write = undefined, .file_read = undefined, .buf = undefined };

pub const WasmTransport = struct {
    /// Bind the page's file imports; returns the plain FileTransport vtable.
    pub fn make(file_write: FileWrite, file_read: FileRead) file_transport.FileTransport {
        context.file_write = file_write;
        context.file_read = file_read;
        return file_transport.FileTransport{
            .context = &context,
            .write = write,
            .readAll = readAll,
            .free = free,
        };
    }

    fn asContext(c: *anyopaque) *Context {
        const ctx: *Context = @ptrCast(@alignCast(c));
        return ctx;
    }

    fn free(c: *anyopaque, buf: []u8) void {
        _ = c;
        _ = buf; // arm-owned static buffer; nothing to release.
    }

    fn write(c: *anyopaque, path: []const u8, bytes: []const u8) TransportError!void {
        const ctx = asContext(c);
        ctx.file_write(path.ptr, @intCast(path.len), bytes.ptr, @intCast(bytes.len));
    }
    // 0 bytes placed means the page could not serve the name (missing/unreadable).
    fn readAll(c: *anyopaque, path: []const u8) TransportError![]u8 {
        const ctx = asContext(c);
        const len = ctx.file_read(path.ptr, @intCast(path.len), &ctx.buf, ctx.buf.len);
        if (len == 0) return TransportError.FileNotFound;
        if (len == ctx.buf.len) return TransportError.System; // page clipped the file
        return ctx.buf[0..len];
    }
};

// Native test mocks: one in-memory "file" the write import records and the
// read import serves back — standing in for the browser's file store.
const Store = struct {
    name: [64]u8,
    name_len: u32,
    bytes: [256]u8,
    byte_len: u32,
};
var store = Store{
    .name = undefined,
    .name_len = 0,
    .bytes = undefined,
    .byte_len = 0,
};

pub fn test_file_write(name: [*]const u8, name_len: u32, bytes: [*]const u8, bytes_len: u32) callconv(.c) void {
    @memcpy(store.name[0..name_len], name[0..name_len]);
    store.name_len = name_len;
    @memcpy(store.bytes[0..bytes_len], bytes[0..bytes_len]);
    store.byte_len = bytes_len;
}
pub fn test_file_read(name: [*]const u8, name_len: u32, buf: [*]u8, cap: u32) callconv(.c) u32 {
    if (name_len != store.name_len or !std.mem.eql(u8, name[0..name_len], store.name[0..store.name_len])) return 0;
    const n = @min(store.byte_len, cap);
    @memcpy(buf[0..n], store.bytes[0..n]);
    return n;
}

test "FileTransport wasm arm: write then readAll round-trips bytes through the vtable" {
    const transport = WasmTransport.make(test_file_write, test_file_read);

    const payload = "wasm arm payload across the browser boundary";
    transport.write(transport.context, "save.sud", payload) catch |err| return err;

    const bytes = transport.readAll(transport.context, "save.sud") catch |err| return err;
    defer transport.free(transport.context, bytes);
    try std.testing.expectEqualSlices(u8, payload, bytes);
}

test "FileTransport wasm arm: readAll of a missing name yields FileNotFound" {
    const transport = WasmTransport.make(test_file_write, test_file_read);
    store.byte_len = 0;
    store.name_len = 0;

    const result = transport.readAll(transport.context, "missing.sud");
    try std.testing.expectError(TransportError.FileNotFound, result);
}
