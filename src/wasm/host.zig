// WasmHost — the wasm half of Host. Owns the 5 page-supplied capability
// imports (line-in, bytes-out, picker, file_read, file_write) as fn pointers
// and routes calls through them, standing in for the native Host substrate:
// the page owns stdin/stdout/file-store; this struct is the seam the
// WasmRenderer and WasmTransport lean on. Compiles in both deployments
// (never touches std.Io) and is mock-drivable from the native suite.
const std = @import("std");
const wasm_transport = @import("transport.zig");

// Import surface the page supplies; the wasm entry binds the real page imports.
pub const LineIn = *const fn (buf: [*]u8, cap: u32) callconv(.c) u32; // bytes served, 0 = EOF
pub const BytesOut = *const fn (bytes: [*]const u8, len: u32) callconv(.c) void;
pub const Picker = *const fn (buf: [*]u8, cap: u32) callconv(.c) u32; // filename served, 0 = cancelled

pub const WasmHost = struct {
    line_in: LineIn,
    bytes_out: BytesOut,
    picker: Picker,
    file_write: wasm_transport.FileWrite,
    file_read: wasm_transport.FileRead,

    /// Bind the page's 5 imports; the struct is the routing seam for renderer and transport.
    pub fn make(line_in: LineIn, bytes_out: BytesOut, picker: Picker, file_write: wasm_transport.FileWrite, file_read: wasm_transport.FileRead) WasmHost {
        return WasmHost{
            .line_in = line_in,
            .bytes_out = bytes_out,
            .picker = picker,
            .file_write = file_write,
            .file_read = file_read,
        };
    }

    // Result buffers owned by the host: the page fills them, the returned
    // slice is valid until the next call (same lifetime idiom as the
    // WasmTransport arm's static buffer).
    const Results = struct {
        line: [256]u8,
        name: [256]u8,
    };
    var results = Results{ .line = undefined, .name = undefined };

    // One-shot inbound queue: the wasm entry's step export stores the page's
    // command line here and the next readLine serves it before asking the
    // page. Static like `results` — same single-host-per-process idiom.
    var queued: [256]u8 = undefined;
    var queued_len: u32 = 0;
    var queued_set = false;

    /// Pull one command line from the page; null on EOF.
    pub fn readLine(self: *const WasmHost) ?[]u8 {
        if (queued_set) {
            queued_set = false; // one-shot — the page serves what comes next
            return queued[0..queued_len];
        }
        const n = self.line_in(&results.line, results.line.len);
        if (n == 0) return null;
        if (n == results.line.len) return null; // page clipped the line
        return results.line[0..n];
    }

    /// Store a page event line for the next readLine; an empty or over-long
    /// line clears the queue so readLine falls through to the page import.
    pub fn queueLine(line: []const u8) void {
        if (line.len == 0 or line.len >= queued.len) {
            queued_len = 0;
            queued_set = false;
            return;
        }
        @memcpy(queued[0..line.len], line);
        queued_len = @intCast(line.len);
        queued_set = true;
    }

    /// Ask the page to pick a file name; null on cancel.
    pub fn pickName(self: *const WasmHost) ?[]u8 {
        const n = self.picker(&results.name, results.name.len);
        if (n == 0) return null;
        if (n == results.name.len) return null; // page clipped the name
        return results.name[0..n];
    }

    /// Push screen text to the page's sink.
    pub fn writeScreen(self: *const WasmHost, text: []const u8) void {
        self.bytes_out(text.ptr, @intCast(text.len));
    }
};

// Native test mocks: static buffers standing in for the page.
const LineBuf = struct {
    buf: [64]u8,
    len: u32,
};
const OutBuf = struct {
    buf: [128]u8,
    len: u32,
};
const NameBuf = struct {
    buf: [64]u8,
    len: u32,
};
var line_mock = LineBuf{ .len = 9, .buf = pad64("fill A3 4") };
var out_mock = OutBuf{ .len = 0, .buf = undefined };
var name_mock = NameBuf{ .len = 8, .buf = pad64("save.sud") };

fn pad64(s: []const u8) [64]u8 {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..s.len], s);
    return buf;
}

fn mock_line_in(buf: [*]u8, cap: u32) callconv(.c) u32 {
    const n = @min(line_mock.len, cap);
    @memcpy(buf[0..n], line_mock.buf[0..n]);
    line_mock.len = 0; // one line served — a second call reads EOF.
    return n;
}
fn mock_bytes_out(bytes: [*]const u8, len: u32) callconv(.c) void {
    @memcpy(out_mock.buf[0..len], bytes[0..len]);
    out_mock.len = len;
}
fn mock_picker(buf: [*]u8, cap: u32) callconv(.c) u32 {
    const n = @min(name_mock.len, cap);
    @memcpy(buf[0..n], name_mock.buf[0..n]);
    return n;
}

test "WasmHost: picker returns the name the page serves" {
    const host = WasmHost.make(
        mock_line_in,
        mock_bytes_out,
        mock_picker,
        wasm_transport.test_file_write,
        wasm_transport.test_file_read,
    );
    const name = host.pickName() orelse return error.PickerCancelled;
    try std.testing.expectEqualSlices(u8, "save.sud", name);
}

test "WasmHost: line-in serves the line the page supplied" {
    const host = WasmHost.make(
        mock_line_in,
        mock_bytes_out,
        mock_picker,
        wasm_transport.test_file_write,
        wasm_transport.test_file_read,
    );
    const line = host.readLine() orelse return error.ReadEOF;
    try std.testing.expectEqualSlices(u8, "fill A3 4", line);
}

test "WasmHost: bytes-out reaches the page's sink" {
    const host = WasmHost.make(
        mock_line_in,
        mock_bytes_out,
        mock_picker,
        wasm_transport.test_file_write,
        wasm_transport.test_file_read,
    );
    host.writeScreen("screen text across the boundary");
    try std.testing.expectEqualSlices(u8, "screen text across the boundary", out_mock.buf[0..out_mock.len]);
}
test "WasmHost: a queued line is served by the next readLine, exactly once" {
    const host = WasmHost.make(
        mock_line_in,
        mock_bytes_out,
        mock_picker,
        wasm_transport.test_file_write,
        wasm_transport.test_file_read,
    );
    line_mock.len = 0; // page serves EOF — only the queue can answer

    WasmHost.queueLine("quit");
    const first = host.readLine() orelse return error.ReadEOF;
    try std.testing.expectEqualSlices(u8, "quit", first);

    // One-shot: the second read falls through to the page (EOF here).
    try std.testing.expect(host.readLine() == null);

    // An empty or clipped queue clears — readLine still reports the page (EOF).
    WasmHost.queueLine("");
    try std.testing.expect(host.readLine() == null);
}
