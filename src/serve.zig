/// Routes request paths to the served asset. Pure: no sockets, no std.Io —
/// the socket layer lives elsewhere and drives this through Router.route().
const std = @import("std");
const net = std.Io.net;
const logger = @import("logger.zig");
const log = logger.Logger(.serve);
const wasm_bytes = @import("wasm/wasm_bytes.zig");

pub const RouteResult = enum { page, glue, artifact };

/// The three known routes and the delivered-once set.
pub const Router = struct {
    /// Three known routes: page, glue, artifact — one bool each.
    delivered: [3]bool,

    pub const Error = error{NotFound};

    pub fn init() Router {
        return .{ .delivered = [_]bool{ false, false, false } };
    }

    /// Maps a request path to its asset; anything else is a router-level 404.
    pub fn route(path: []const u8) Error!RouteResult {
        if (std.mem.eql(u8, path, "/")) return .page;
        if (std.mem.eql(u8, path, "/glue.js")) return .glue;
        if (std.mem.eql(u8, path, "/artifact.wasm")) return .artifact;
        return Error.NotFound;
    }

    /// Records that an asset has been served at least once.
    pub fn markDelivered(self: *Router, result: RouteResult) void {
        self.delivered[@intFromEnum(result)] = true;
    }

    /// The exit condition: every known route has been served at least once.
    pub fn allDelivered(self: *const Router) bool {
        for (self.delivered) |d| {
            if (!d) return false;
        }
        return true;
    }
};
/// Errors surfacing from serve(): the port is already owned, or any socket
/// fault — mapped to System so only AddressInUse needs caller-specific handling.
pub const ServeError = error{ AddressInUse, System };

/// Loopback endpoint the web renderer is served from.
pub const Port: u16 = 8080;
/// Fallback ports probed in order when Port is already taken.
pub const FallbackCount: u16 = 8;

/// Bind failure: the port is owned by someone else, or a socket-level fault.
pub const BindError = error{ InUse, System };
/// Port-binding seam: attempt to bind one loopback port; report why not.
/// Prod wires in `bindLoopback`; tests wire in a fake (same pattern as the
/// MockSource seam in host/input_source.zig).
pub const BindFn = *const fn (io: std.Io, port: u16) BindError!net.Server;
pub fn bindLoopback(io: std.Io, port: u16) BindError!net.Server {
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    return net.IpAddress.listen(&addr, io, .{}) catch |err| switch (err) {
        error.AddressInUse => BindError.InUse,
        else => BindError.System,
    };
}
/// Serves the embedded web assets to loopback clients and returns once every
/// known route has been served at least once — no lingering server process.
pub fn serve(io: std.Io) ServeError!void {
    return serveWith(io, bindLoopback);
}
/// Core probe loop: try each port in order until one binds.
fn serveWith(io: std.Io, bind: BindFn) ServeError!void {
    // The preferred port may be owned by another service; probe the fallback
    // range so serving never fails just because the preferred one is taken.
    var srv: ?net.Server = null;
    var bound_port: ?u16 = null;
    var i: u16 = 0;
    while (i <= FallbackCount and srv == null) : (i += 1) {
        srv = bind(io, Port + i) catch |err| switch (err) {
            BindError.InUse => continue,
            else => return ServeError.System,
        };
        bound_port = Port + i;
    }
    var server: net.Server = srv orelse return ServeError.AddressInUse;
    defer server.deinit(io);
    log.info("serving sudoku web on http://127.0.0.1:{d}/", .{bound_port.?});
    var router = Router.init();
    while (!router.allDelivered()) {
        const client = server.accept(io) catch return ServeError.System;
        errdefer client.close(io);
        try serveClient(io, &router, client);
    }
}

/// Reads one request head, routes the path, writes the asset and marks it
/// delivered; unknown paths get a 404 and no mark.
fn serveClient(io: std.Io, router: *Router, client: net.Stream) ServeError!void {
    var in_buf: [8192]u8 = undefined;
    var used: usize = 0;
    outer: while (used < in_buf.len) {
        var data: [1][]u8 = .{in_buf[used..]};
        const n = client.read(io, &data) catch return ServeError.System;
        if (n == 0) break;
        used += n;
        if (std.mem.indexOfPos(u8, in_buf[0..used], 0, "\r\n\r\n") != null) break :outer;
    }

    const line_end = std.mem.indexOfPos(u8, in_buf[0..used], 0, "\r\n") orelse return ServeError.System;
    var fields = std.mem.splitScalar(u8, in_buf[0..line_end], ' ');
    _ = fields.next() orelse return ServeError.System; // method
    const path = fields.next() orelse return ServeError.System;

    const res = Router.route(path);
    var w_buf: [4096]u8 = undefined;
    var w = client.writer(io, w_buf[0..]);
    if (res) |result| {
        const body: []const u8 = switch (result) {
            .page => wasm_bytes.page_html,
            .glue => wasm_bytes.glue_js,
            .artifact => wasm_bytes.wasm_bytes,
        };
        const content_type: []const u8 = switch (result) {
            .page => "text/html",
            .glue => "text/javascript",
            .artifact => "application/wasm",
        };
        try writeFull(&w.interface, "200 OK", content_type, body);
        router.markDelivered(result);
    } else |_| {
        try writeFull(&w.interface, "404 Not Found", "text/plain", "not found\n");
    }
}

/// One HTTP response over a buffered stream writer: status line, Content-Type,
/// Content-Length, then body. The tail still sitting in the writer's buffer
/// only reaches the socket once the writer is drained.
fn writeFull(w: *std.Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) ServeError!void {
    std.Io.Writer.print(
        w,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return ServeError.System;
    std.Io.Writer.writeAll(w, body) catch return ServeError.System;
    std.Io.Writer.flush(w) catch return ServeError.System;
}
// Test doubles for the bind seam — no live sockets.
fn bindInUse(io: std.Io, port: u16) BindError!net.Server {
    _ = io;
    _ = port;
    return BindError.InUse;
}
fn bindFault(io: std.Io, port: u16) BindError!net.Server {
    _ = io;
    _ = port;
    return BindError.System;
}
// Stream-like drain double: bytes reach the sink only when the writer
// drains them, exactly like the real socket writer.
var capture_len: usize = 0;
var capture_sink: [1024]u8 = undefined;

fn captureDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const buffered = w.buffered();
    var data_bytes: usize = 0;
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |s| data_bytes += s.len;
        data_bytes += data[data.len - 1].len * splat;
    }
    if (capture_sink.len < capture_len + buffered.len + data_bytes) return error.WriteFailed;
    var off = capture_len;
    @memcpy(capture_sink[off .. off + buffered.len], buffered);
    off += buffered.len;
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |s| {
            @memcpy(capture_sink[off .. off + s.len], s);
            off += s.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            @memcpy(capture_sink[off .. off + pattern.len], pattern);
            off += pattern.len;
        }
    }
    capture_len = off;
    w.end = 0;
    return data_bytes;
}

test "serve: route \"/\" to the page" {
    try std.testing.expectEqual(RouteResult.page, Router.route("/"));
}

test "serve: route \"/glue.js\" to the glue" {
    try std.testing.expectEqual(RouteResult.glue, Router.route("/glue.js"));
}

test "serve: route \"/artifact.wasm\" to the artifact" {
    try std.testing.expectEqual(RouteResult.artifact, Router.route("/artifact.wasm"));
}

test "serve: unknown path is NotFound" {
    try std.testing.expectError(Router.Error.NotFound, Router.route("/nope.txt"));
}

test "serve: allDelivered false until each route marked, true after; re-marking one does not satisfy the rest" {
    var r = Router.init();
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.page);
    r.markDelivered(.page); // second mark must not advance the set
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.glue);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.artifact);
    try std.testing.expect(r.allDelivered());
}

test "serve: reports AddressInUse when every probed port is in use" {
    try std.testing.expectError(
        ServeError.AddressInUse,
        serveWith(std.testing.io, bindInUse),
    );
}
test "serve: a socket fault while probing is System, not AddressInUse" {
    try std.testing.expectError(
        ServeError.System,
        serveWith(std.testing.io, bindFault),
    );
}
test "serve: writeFull flushes what the buffer still holds (short response must not sit undelivered)" {
    capture_len = 0;
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer{
        .vtable = &.{ .drain = captureDrain },
        .buffer = buf[0..],
    };
    try writeFull(&w, "200 OK", "text/plain", "hello world");
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world",
        capture_sink[0..capture_len],
    );
}
