/// Loopback static host for the web app shell (desktop `-r web` and future Android WebView).
const std = @import("std");
const net = std.Io.net;
const logger = @import("../core/logger.zig");
const log = logger.Logger(.web_host);
const config = @import("../core/config.zig");
const startup_config = @import("../core/startup/config.zig");
const config_store = @import("../core/config_store.zig");
const file_transport = @import("../native/shell/file_transport.zig");
const file_path = @import("../native/shell/path.zig");
const save_defaults = @import("../core/save_defaults.zig");
const router_mod = @import("router.zig");
const embed = @import("embed.zig");

/// HTTP path routing and embedded response bodies (see `router.zig`).
pub const Router = router_mod.Router;
/// Discriminant for a known loopback URL the web shell may request.
pub const RouteResult = router_mod.RouteResult;

/// Loopback host failed to start: no free port in the probe range, or an I/O fault.
pub const ServeError = error{ AddressInUse, System };

/// First loopback port tried before `FallbackCount` alternates.
pub const Port: u16 = 8080;
/// Extra ports probed as `Port + n` when the preferred port is taken.
pub const FallbackCount: u16 = 8;

/// Port bind rejected: address in use vs other socket error (see `BindFn`).
pub const BindError = error{ InUse, System };
/// Injectable bind seam — production uses `bindLoopback`; tests use fakes.
pub const BindFn = *const fn (io: std.Io, port: u16) BindError!net.Server;

/// Listen on `127.0.0.1:port` for the static web shell.
pub fn bindLoopback(io: std.Io, port: u16) BindError!net.Server {
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    return net.IpAddress.listen(&addr, io, .{}) catch |err| switch (err) {
        error.AddressInUse => BindError.InUse,
        else => BindError.System,
    };
}

/// Called on the **caller thread** immediately after bind, with the loopback URL (before the accept worker is joined).
/// Desktop registers browser open here; Android WebView loads the URL from Java instead of using this hook.
pub const OnReadyFn = *const fn (io: std.Io, url: []const u8) void;

const Session = struct {
    host_config: config.Config,
    data_dir: []const u8,
    /// User-visible folder for the default autosave file when there is no current file.
    visible_save_dir: []const u8,
    /// Host-computed startup metadata: web restore depends on capability+path.
    has_current_file: bool,
    current_file: ?[]const u8,
    host_config_body_buf: [1024]u8,

    fn hostConfigBody(self: *Session) ServeError![]const u8 {
        const startup_name = startupFilename(self.current_file);
        return startup_config.formatHostStartupJsonWithCurrentFile(self.host_config, self.has_current_file, startup_name, &self.host_config_body_buf) catch return ServeError.System;
    }
};

/// Save file name the web shell is writing (bare name, no folders).
const FILENAME_HEADER = "X-Sudoku-Filename";
/// Set when the user's own file was written elsewhere (picker, file handle, Android bridge):
/// the host copy is only the restore copy and lives in the hidden data dir.
const RESTORE_COPY_HEADER = "X-Sudoku-Restore-Copy";
/// On `DELETE /current-file`: also delete the file itself, not just the restore pointer.
const DELETE_FILE_HEADER = "X-Sudoku-Delete-File";
const CURRENT_FILE_PATH = "/current-file";
const CURRENT_FILE_EXISTS_PATH = "/current-file-exists";

/// The host route that receives core's Config body and stores it in `config.json`.
const CONFIG_PATH = "/config.json";

fn requestBody(request: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return null;
    return request[sep + 4 ..];
}

fn clientLogBody(body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return if (trimmed.len == 0) "<empty>" else trimmed;
}

const ClientLogSeverity = enum { debug, info, warn, err };

fn clientLogSeverity(body: []const u8) ClientLogSeverity {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "\"level\":\"warn\"") != null) return .warn;
    if (std.mem.indexOf(u8, trimmed, "\"level\":\"err\"") != null) return .err;
    if (std.mem.indexOf(u8, trimmed, "\"level\":\"debug\"") != null) return .debug;
    return .info;
}

fn jsonStringField(body: []const u8, key: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch |err| {
        log.err("client-log key {s} too long to look up: {s}", .{ key, @errorName(err) });
        return null;
    };
    const start = std.mem.indexOf(u8, trimmed, needle) orelse return null;
    const value_start = start + needle.len;
    const rest = trimmed[value_start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

fn clientLogScope(body: []const u8) []const u8 {
    return jsonStringField(body, "scope") orelse jsonStringField(body, "lane") orelse "client";
}

fn clientLogEvent(body: []const u8) []const u8 {
    return jsonStringField(body, "event") orelse jsonStringField(body, "stage") orelse "message";
}

fn contentLength(request: []const u8) ?usize {
    const line_end = std.mem.indexOfPos(u8, request, 0, "\r\n") orelse return null;
    const headers = request[line_end + 2 ..];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const raw = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            return std.fmt.parseInt(usize, raw, 10) catch |err| {
                log.warn("bad Content-Length '{s}': {s}", .{ raw, @errorName(err) });
                return null;
            };
        }
    }
    return null;
}

fn headerValue(request: []const u8, key: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOfPos(u8, request, 0, "\r\n") orelse return null;
    const headers = request[line_end + 2 ..];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, key)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

fn startupFilename(current_file: ?[]const u8) []const u8 {
    if (current_file) |p| {
        const base = std.fs.path.basename(p);
        if (base.len > 0) return base;
    }
    return save_defaults.DEFAULT_SAVE_FILE;
}

fn validSaveName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, name, '/')) |_| return false;
    if (std.mem.indexOfScalar(u8, name, '\\')) |_| return false;
    return true;
}

fn headerFlag(request: []const u8, key: []const u8) bool {
    const raw = headerValue(request, key) orelse return false;
    const value = std.mem.trim(u8, raw, " \t");
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1");
}

/// Apply core's Config body onto the host Config and store it; config_store logs a body it refuses.
fn applyConfigPost(io: std.Io, session: *Session, body: []const u8) ServeError!void {
    config_store.applyConfigJson(std.heap.page_allocator, &session.host_config, body) catch return ServeError.System;
    const gpa = std.heap.page_allocator;
    if (session.data_dir.len == 0 or std.mem.eql(u8, session.data_dir, ".")) return;
    config_store.ensureConfigDir(io, session.data_dir);
    config_store.save(gpa, io, session.data_dir, session.host_config) catch return ServeError.System;
}

/// Owned write path for a current-file write, and whether it is only the hidden restore copy.
const CurrentFileTarget = struct {
    path: []u8,
    restore_copy: bool,
};

/// No current file: the default visible file. Current file with the same (or no) name: that file
/// in place. A restore copy, or a different name, goes to the hidden data dir.
fn currentFileTarget(io: std.Io, session: *const Session, save_name: ?[]const u8, restore_copy: bool) !CurrentFileTarget {
    const gpa = std.heap.page_allocator;
    const requested: ?[]const u8 = if (save_name) |n| blk: {
        const trimmed = std.mem.trim(u8, n, " \t");
        break :blk if (validSaveName(trimmed)) trimmed else null;
    } else null;
    if (restore_copy) {
        const name = requested orelse startupFilename(session.current_file);
        return .{ .path = try file_path.resolveSavePath(gpa, session.data_dir, name), .restore_copy = true };
    }
    const current = session.current_file orelse {
        std.Io.Dir.cwd().createDirPath(io, session.visible_save_dir) catch |err| {
            log.warn("could not create save folder {s}: {s}", .{ session.visible_save_dir, @errorName(err) });
        };
        return .{ .path = try file_path.resolveSavePath(gpa, session.visible_save_dir, requested orelse save_defaults.DEFAULT_SAVE_FILE), .restore_copy = false };
    };
    const in_place: CurrentFileTarget = .{ .path = try gpa.dupe(u8, current), .restore_copy = isRestoreCopyPath(session, current) };
    const name = requested orelse return in_place;
    if (std.mem.eql(u8, name, std.fs.path.basename(current))) return in_place;
    gpa.free(in_place.path);
    return .{ .path = try file_path.resolveSavePath(gpa, session.data_dir, name), .restore_copy = true };
}

/// A file directly in the hidden data dir, when that dir is not also the visible save folder.
fn isRestoreCopyPath(session: *const Session, path: []const u8) bool {
    if (std.mem.eql(u8, session.data_dir, session.visible_save_dir)) return false;
    return std.mem.eql(u8, std.fs.path.dirname(path) orelse "", session.data_dir);
}

/// True when a write of `save_name` would land on an existing file the user can see.
fn currentFileTargetExists(io: std.Io, session: *const Session, save_name: ?[]const u8) ServeError!bool {
    const target = currentFileTarget(io, session, save_name, false) catch return ServeError.System;
    defer std.heap.page_allocator.free(target.path);
    if (target.restore_copy) return false;
    _ = std.Io.Dir.cwd().statFile(io, target.path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("expected: {s} is not there yet ({s})", .{ target.path, @errorName(err) });
            return false;
        },
        else => {
            log.err("could not check {s}: {s}", .{ target.path, @errorName(err) });
            return ServeError.System;
        },
    };
    return true;
}

fn applyCurrentFilePost(io: std.Io, session: *Session, body: []const u8, save_name: ?[]const u8, restore_copy: bool) ServeError!void {
    if (session.data_dir.len == 0 or std.mem.eql(u8, session.data_dir, ".")) return;

    config_store.ensureConfigDir(io, session.data_dir);
    const target = currentFileTarget(io, session, save_name, restore_copy) catch return ServeError.System;
    defer std.heap.page_allocator.free(target.path);

    const transport = file_transport.NativeTransport.make(io);
    transport.write(transport.context, target.path, body) catch return ServeError.System;

    config_store.setCurrentFile(std.heap.page_allocator, io, session.data_dir, target.path) catch return ServeError.System;

    if (session.current_file) |old| std.heap.page_allocator.free(old);
    session.current_file = std.heap.page_allocator.dupe(u8, target.path) catch return ServeError.System;
    session.has_current_file = true;
    log.info("current-file write: bytes={d} target={s} restore_copy={any}", .{ body.len, target.path, target.restore_copy });
}

/// Stop restoring the current file at startup; with `delete_file`, remove it from disk too.
fn applyCurrentFileForget(io: std.Io, session: *Session, delete_file: bool) ServeError!void {
    const current = session.current_file orelse return;
    if (delete_file) std.Io.Dir.cwd().deleteFile(io, current) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return ServeError.System,
    };
    if (session.data_dir.len != 0 and !std.mem.eql(u8, session.data_dir, ".")) {
        config_store.setCurrentFile(std.heap.page_allocator, io, session.data_dir, null) catch return ServeError.System;
    }
    log.info("current-file forget: path={s} deleted={any}", .{ current, delete_file });
    std.heap.page_allocator.free(current);
    session.current_file = null;
    session.has_current_file = false;
}

var shutdown_requested = std.atomic.Value(bool).init(false);
var listener_guard: std.Io.Mutex = .init;
var active_listener: ?*net.Server = null;

/// Stops the active accept loop by closing the listener; `runBlocking` returns after the worker thread exits.
pub fn requestShutdown(io: std.Io) void {
    shutdown_requested.store(true, .release);
    listener_guard.lockUncancelable(io);
    defer listener_guard.unlock(io);
    if (active_listener) |srv| {
        srv.deinit(io);
        active_listener = null;
    }
}

const ReadyGate = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    done: bool = false,
    err: ?ServeError = null,
    url: [64]u8 = undefined,
    url_len: usize = 0,

    fn signalReady(self: *ReadyGate, io: std.Io, url: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        @memcpy(self.url[0..url.len], url);
        self.url_len = url.len;
        self.done = true;
        self.cond.signal(io);
    }

    fn signalFailed(self: *ReadyGate, io: std.Io, err: ServeError) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.err = err;
        self.done = true;
        self.cond.signal(io);
    }

    fn wait(self: *ReadyGate, io: std.Io) ServeError![]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.done) self.cond.waitUncancelable(io, &self.mutex);
        if (self.err) |e| return e;
        return self.url[0..self.url_len];
    }
};

const WorkerCtx = struct {
    io: std.Io,
    bind: BindFn,
    session: *Session,
    gate: *ReadyGate,
};

fn acceptLoop(io: std.Io, server: *net.Server, session: *Session) ServeError!void {
    var rt_router = Router.init();
    while (!shutdown_requested.load(.acquire)) {
        const client = server.accept(io) catch {
            if (shutdown_requested.load(.acquire)) return;
            return ServeError.System;
        };
        try serveAndClose(io, session, &rt_router, client);
    }
}

/// Serves one accepted connection and closes it; the accept loop owns every accepted stream until here.
fn serveAndClose(io: std.Io, session: *Session, rt_router: *Router, client: net.Stream) ServeError!void {
    defer client.close(io);
    try serveClient(io, session, rt_router, client);
}

fn workerEntry(ctx: *WorkerCtx) void {
    bindProbe(ctx.io, ctx.bind, ctx.gate, ctx.session) catch |err| {
        ctx.gate.signalFailed(ctx.io, err);
    };
}

fn bindProbe(io: std.Io, bind: BindFn, gate: *ReadyGate, session: *Session) ServeError!void {
    var srv: ?net.Server = null;
    var bound_port: ?u16 = null;
    var i: u16 = 0;
    while (i <= FallbackCount and srv == null) : (i += 1) {
        srv = bind(io, Port + i) catch |err| switch (err) {
            BindError.InUse => {
                log.info("expected: port {d} in use, trying the next ({s})", .{ Port + i, @errorName(err) });
                continue;
            },
            else => {
                log.err("could not bind port {d}: {s}", .{ Port + i, @errorName(err) });
                return ServeError.System;
            },
        };
        bound_port = Port + i;
    }
    var server: net.Server = srv orelse return ServeError.AddressInUse;

    listener_guard.lockUncancelable(io);
    active_listener = &server;
    listener_guard.unlock(io);
    defer {
        listener_guard.lockUncancelable(io);
        if (active_listener == &server) active_listener = null;
        listener_guard.unlock(io);
        server.deinit(io);
    }

    log.info("serving sudoku web on http://127.0.0.1:{d}/", .{bound_port.?});
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{bound_port.?}) catch return ServeError.System;
    gate.signalReady(io, url);

    try acceptLoop(io, &server, session);
}

/// Starts the loopback host: worker binds and serves; caller receives `on_ready` then blocks until shutdown.
pub fn runBlocking(io: std.Io, bind: BindFn, host_cfg: config.Config, data_dir: []const u8, visible_save_dir: []const u8, on_ready: OnReadyFn) ServeError!void {
    shutdown_requested.store(false, .release);

    const current_file = config_store.loadCurrentFile(std.heap.page_allocator, io, data_dir) catch |err| blk: {
        log.warn("current file setting unreadable: {s}", .{@errorName(err)});
        break :blk null;
    };
    const startup_name = startupFilename(current_file);
    if (current_file) |path| {
        log.info("startup current file: path={s} name={s}", .{ path, startup_name });
    } else {
        log.info("startup current file: path=<none> name={s}", .{startup_name});
    }
    var session = Session{
        .host_config = host_cfg,
        .data_dir = data_dir,
        .visible_save_dir = visible_save_dir,
        .has_current_file = current_file != null,
        .current_file = current_file,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);
    var gate: ReadyGate = .{};
    var ctx = WorkerCtx{
        .io = io,
        .bind = bind,
        .session = &session,
        .gate = &gate,
    };

    const thread = std.Thread.spawn(.{}, workerEntry, .{&ctx}) catch return ServeError.System;
    const url = gate.wait(io) catch |err| {
        thread.join();
        return err;
    };
    on_ready(io, url);
    thread.join();
}

/// Host-resolved startup config, caller-owned config directory for POST persistence, and the
/// platform's user-visible folder for the default autosave file.
pub fn runWithHostConfig(io: std.Io, bind: BindFn, host_cfg: config.Config, data_dir: []const u8, visible_save_dir: []const u8, on_ready: OnReadyFn) ServeError!void {
    return runBlocking(io, bind, host_cfg, data_dir, visible_save_dir, on_ready);
}

fn serveClient(io: std.Io, session: *Session, rt_router: *Router, client: net.Stream) ServeError!void {
    var in_buf: [8192]u8 = undefined;
    var used: usize = 0;
    while (used < in_buf.len) {
        var data: [1][]u8 = .{in_buf[used..]};
        const read_result = client.readWithControl(io, &data, &.{}) catch return ServeError.System;
        const n = read_result.data_len;
        if (n == 0) break;
        used += n;
        const header_end = std.mem.indexOfPos(u8, in_buf[0..used], 0, "\r\n\r\n") orelse continue;
        const header_bytes = in_buf[0 .. header_end + 4];
        const body_len = contentLength(header_bytes) orelse 0;
        if (used >= header_end + 4 + body_len) break;
    }

    const request = in_buf[0..used];
    const line_end = std.mem.indexOfPos(u8, request, 0, "\r\n") orelse return ServeError.System;
    var fields = std.mem.splitScalar(u8, request[0..line_end], ' ');
    const method = fields.next() orelse return ServeError.System;
    const req_path = fields.next() orelse return ServeError.System;
    log.debug("request {s} {s}", .{ method, req_path });

    var w_buf: [4096]u8 = undefined;
    var w = client.writer(io, w_buf[0..]);

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, req_path, CONFIG_PATH)) {
        const body = requestBody(request) orelse return ServeError.System;
        try applyConfigPost(io, session, body);
        try writeFull(&w.interface, "204 No Content", "application/json", "");
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, req_path, CURRENT_FILE_PATH)) {
        const body = requestBody(request) orelse return ServeError.System;
        try applyCurrentFilePost(io, session, body, headerValue(request, FILENAME_HEADER), headerFlag(request, RESTORE_COPY_HEADER));
        try writeFull(&w.interface, "204 No Content", "application/octet-stream", "");
        return;
    }
    if (std.mem.eql(u8, method, "DELETE") and std.mem.eql(u8, req_path, CURRENT_FILE_PATH)) {
        try applyCurrentFileForget(io, session, headerFlag(request, DELETE_FILE_HEADER));
        try writeFull(&w.interface, "204 No Content", "application/octet-stream", "");
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, req_path, CURRENT_FILE_EXISTS_PATH)) {
        const exists = try currentFileTargetExists(io, session, headerValue(request, FILENAME_HEADER));
        try writeFull(&w.interface, "200 OK", "application/json", if (exists) "{\"exists\":true}" else "{\"exists\":false}");
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, req_path, "/client-log")) {
        const body = requestBody(request) orelse return ServeError.System;
        const trimmed = clientLogBody(body);
        const scope = clientLogScope(trimmed);
        const event = clientLogEvent(trimmed);
        switch (clientLogSeverity(trimmed)) {
            .debug => log.debug("client-log [{s}] {s} {s}", .{ scope, event, trimmed }),
            .info => log.info("client-log [{s}] {s} {s}", .{ scope, event, trimmed }),
            .warn => log.warn("client-log [{s}] {s} {s}", .{ scope, event, trimmed }),
            .err => log.err("client-log [{s}] {s} {s}", .{ scope, event, trimmed }),
        }
        try writeFull(&w.interface, "204 No Content", "application/json", "");
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, req_path, CURRENT_FILE_PATH)) {
        const current_file = session.current_file orelse {
            try writeFull(&w.interface, "404 Not Found", "text/plain", "startup save not configured\n");
            return;
        };
        const transport = file_transport.NativeTransport.make(io);
        const resolved = transport.resolve(transport.context, current_file) catch {
            try writeFull(&w.interface, "404 Not Found", "text/plain", "startup save not found\n");
            return;
        };
        defer transport.free(transport.context, resolved);
        const bytes = transport.readAll(transport.context, resolved) catch {
            try writeFull(&w.interface, "404 Not Found", "text/plain", "startup save not found\n");
            return;
        };
        defer transport.free(transport.context, bytes);
        try writeFull(&w.interface, "200 OK", "application/octet-stream", bytes);
        return;
    }

    const res = Router.route(req_path);
    if (res) |result| {
        const body: []const u8 = if (result == .host_config)
            try session.hostConfigBody()
        else
            Router.body(result);
        try writeFull(&w.interface, "200 OK", Router.contentType(result), body);
        rt_router.markDelivered(result);
    } else |_| {
        try writeFull(&w.interface, "404 Not Found", "text/plain", "not found\n");
    }
}

fn writeFull(w: *std.Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) ServeError!void {
    std.Io.Writer.print(
        w,
        // Local loopback host must always reflect live policy/state and fresh JS.
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nCache-Control: no-store\r\nPragma: no-cache\r\nExpires: 0\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return ServeError.System;
    std.Io.Writer.writeAll(w, body) catch return ServeError.System;
    std.Io.Writer.flush(w) catch return ServeError.System;
}

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

var ready_count: usize = 0;
var ready_last_url: [64]u8 = undefined;

fn recordReady(io: std.Io, url: []const u8) void {
    _ = io;
    ready_count += 1;
    @memcpy(ready_last_url[0..url.len], url);
}

fn runBlockingForTest(io: std.Io, bind: BindFn) ServeError!void {
    return runBlocking(io, bind, config.Config.default(), ".", ".", recordReady);
}

/// Resolves a relative import `spec` against the served URL of the importing module; `..` stops at the root.
fn resolveImportUrl(buf: []u8, base_path: []const u8, spec: []const u8) ![]const u8 {
    var segs: [16][]const u8 = undefined;
    var n: usize = 0;
    var base_it = std.mem.splitScalar(u8, base_path, '/');
    while (base_it.next()) |seg| {
        if (base_it.peek() == null) break;
        segs[n] = seg;
        n += 1;
    }
    var spec_it = std.mem.splitScalar(u8, spec, '/');
    while (spec_it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            n -|= 1;
            continue;
        }
        segs[n] = seg;
        n += 1;
    }
    var w: std.Io.Writer = .fixed(buf);
    for (segs[0..n]) |seg| try w.print("/{s}", .{seg});
    return w.buffered();
}

test "web_host: resolveImportUrl resolves from the importing module's folder" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/flows/session.js", try resolveImportUrl(&buf, "menus/file_menu.js", "../flows/session.js"));
    try std.testing.expectEqualStrings("/menus/menu.js", try resolveImportUrl(&buf, "menus/file_menu.js", "./menu.js"));
    try std.testing.expectEqualStrings("/app_boot.js", try resolveImportUrl(&buf, "page.html", "../app_boot.js"));
}

fn expectJsImportsServed(source: []const u8, base_path: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "from \"")) |start| {
        const spec_start = start + 6;
        const spec_end = std.mem.indexOfPos(u8, source, spec_start, "\"") orelse break;
        const spec = source[spec_start..spec_end];
        if (!std.mem.endsWith(u8, spec, ".js")) {
            i = spec_end + 1;
            continue;
        }
        var buf: [128]u8 = undefined;
        const path = try resolveImportUrl(&buf, base_path, spec);
        const route = Router.route(path) catch {
            std.debug.print("{s} import {s} -> {s} is not served\n", .{ base_path, spec, path });
            return error.TestFailed;
        };
        try std.testing.expect(Router.body(route).len > 0);
        i = spec_end + 1;
    }
}

test "web_host: page.html module imports resolve to embedded routes" {
    try expectJsImportsServed(embed.page_html, "page.html");
}

test "web_host: embedded JS transitive imports resolve to embedded routes" {
    const modules = [_]struct { name: []const u8, body: []const u8 }{
        .{ .name = "app_boot.js", .body = embed.app_boot_js },
        .{ .name = "app_wire.js", .body = embed.app_wire_js },
        .{ .name = "status_bar.js", .body = embed.status_bar_js },
        .{ .name = "play_pad.js", .body = embed.play_pad_js },
        .{ .name = "dialogs/prompt_dialog.js", .body = embed.prompt_dialog_js },
        .{ .name = "client_log.js", .body = embed.client_log_js },
        .{ .name = "flows/session.js", .body = embed.session_js },
        .{ .name = "host_api.js", .body = embed.host_api_js },
        .{ .name = "gen/generate.js", .body = embed.generate_js },
        .{ .name = "clipboard.js", .body = embed.clipboard_js },
        .{ .name = "flows/autosave.js", .body = embed.autosave_js },
        .{ .name = "files.js", .body = embed.files_js },
        .{ .name = "flows/steps.js", .body = embed.steps_js },
        .{ .name = "flows/web_steps.js", .body = embed.web_steps_js },
        .{ .name = "flows/android_steps.js", .body = embed.android_steps_js },
        .{ .name = "flows/startup.js", .body = embed.startup_js },
        .{ .name = "board.js", .body = embed.board_js },
        .{ .name = "menus/menu.js", .body = embed.menu_js },
        .{ .name = "menus/file_menu.js", .body = embed.file_menu_js },
        .{ .name = "flows/step_runner.js", .body = embed.step_runner_js },
        .{ .name = "gen_worker.js", .body = embed.gen_worker_js },
        .{ .name = "dialogs/generating.js", .body = embed.generating_js },
        .{ .name = "gen/gen_progress_rows.js", .body = embed.gen_progress_rows_js },
        .{ .name = "gen/gen_client.js", .body = embed.gen_client_js },
        .{ .name = "menus/menu_bar.js", .body = embed.menu_bar_js },
        .{ .name = "menus/theme.js", .body = embed.theme_js },
        .{ .name = "menus/region.js", .body = embed.region_js },
        .{ .name = "menus/marks.js", .body = embed.marks_js },
        .{ .name = "menus/shortcuts.js", .body = embed.shortcuts_js },
        .{ .name = "menus/help.js", .body = embed.help_js },
        .{ .name = "menus/settings.js", .body = embed.settings_js },
        .{ .name = "android_bridge.js", .body = embed.android_bridge_js },
    };
    for (modules) |m| {
        try expectJsImportsServed(m.body, m.name);
    }
}

test "web_host: page.html loads the Android bridge in its head, before the app module" {
    const bridge = std.mem.indexOf(u8, embed.page_html, "<script src=\"/android_bridge.js\"></script>") orelse return error.TestUnexpectedResult;
    const head_end = std.mem.indexOf(u8, embed.page_html, "</head>") orelse return error.TestUnexpectedResult;
    const app = std.mem.indexOf(u8, embed.page_html, "<script type=\"module\">") orelse return error.TestUnexpectedResult;
    try std.testing.expect(bridge < head_end and bridge < app);
    const route = try Router.route("/android_bridge.js");
    try std.testing.expect(Router.body(route).len > 0);
}

test "web_host: page.html wasm fetch path is served" {
    try std.testing.expect(std.mem.indexOf(u8, embed.app_boot_js, "fetch(\"./artifact.wasm\")") != null);
    const route = try Router.route("/artifact.wasm");
    try std.testing.expect(Router.body(route).len > 0);
}

test "web_host: page.html links branding icons and web manifest routes" {
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "href=\"/branding/favicon-32x32.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "href=\"/branding/apple-touch-icon.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "href=\"/site.webmanifest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "id=\"boot-splash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "id=\"about-artwork\"") != null);
}

test "web_host: board digit font-size keeps a minimum floor" {
    // Guard the layout invariant: board digits do not shrink below 0.75rem.
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "font-size: clamp(0.75rem, 45cqmin, 2rem);") != null);
}

test "web_host: compact layout contract uses group-fit trigger and zero outer shell spacing" {
    // Compact mode is driven by a group-fit threshold and removes
    // outer/page + inner/shell spacing to reclaim board area.
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "@media (max-width: calc(26rem + 2px))") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "padding: 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "justify-content: flex-start;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "width: 100dvw;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "position: sticky;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "top: env(safe-area-inset-top, 0px);") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "z-index: 9;") != null);
}

test "web_host: current file visibility contract exposes menu-bar filename slot" {
    // Filename-only label lives in menu bar and stays right aligned.
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "id=\"current-file-desktop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "margin-left: auto;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "min-width: 8ch;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "#current-file-desktop {\n        display: none;") == null);
}

test "web_host: every dialog is titled by an h2 heading" {
    const marker = "aria-labelledby=\"";
    var dialogs: usize = 0;
    var rest: []const u8 = embed.page_html;
    while (std.mem.indexOf(u8, rest, marker)) |at| {
        rest = rest[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.TestUnexpectedResult;
        var heading_buf: [96]u8 = undefined;
        const heading = try std.fmt.bufPrint(&heading_buf, "<h2 id=\"{s}\"", .{rest[0..end]});
        if (std.mem.indexOf(u8, embed.page_html, heading) == null) {
            std.debug.print("dialog labelled by '{s}' has no <h2> title\n", .{rest[0..end]});
            return error.TestUnexpectedResult;
        }
        dialogs += 1;
    }
    try std.testing.expect(dialogs >= 5);
}

test "web_host: route map resolves every served path" {
    const cases = [_]struct { path: []const u8, expected: RouteResult }{
        .{ .path = "/", .expected = .page },
        .{ .path = "/glue.js", .expected = .glue },
        .{ .path = "/gen/gen_client.js", .expected = .gen_client },
        .{ .path = "/gen_worker.js", .expected = .gen_worker },
        .{ .path = "/app_boot.js", .expected = .app_boot },
        .{ .path = "/app_wire.js", .expected = .app_wire },
        .{ .path = "/status_bar.js", .expected = .status_bar },
        .{ .path = "/play_pad.js", .expected = .play_pad },
        .{ .path = "/dialogs/prompt_dialog.js", .expected = .prompt_dialog },
        .{ .path = "/client_log.js", .expected = .client_log },
        .{ .path = "/flows/session.js", .expected = .session },
        .{ .path = "/host_api.js", .expected = .host_api },
        .{ .path = "/gen/generate.js", .expected = .generate },
        .{ .path = "/clipboard.js", .expected = .clipboard },
        .{ .path = "/flows/autosave.js", .expected = .autosave },
        .{ .path = "/files.js", .expected = .files },
        .{ .path = "/flows/steps.js", .expected = .steps },
        .{ .path = "/flows/web_steps.js", .expected = .web_steps },
        .{ .path = "/flows/android_steps.js", .expected = .android_steps },
        .{ .path = "/flows/startup.js", .expected = .startup },
        .{ .path = "/board.js", .expected = .board },
        .{ .path = "/menus/menu.js", .expected = .menu },
        .{ .path = "/menus/menu_bar.js", .expected = .menu_bar },
        .{ .path = "/menus/theme.js", .expected = .theme },
        .{ .path = "/menus/file_menu.js", .expected = .file_menu },
        .{ .path = "/flows/step_runner.js", .expected = .step_runner },
        .{ .path = "/android_bridge.js", .expected = .android_bridge },
        .{ .path = "/dialogs/generating.js", .expected = .generating },
        .{ .path = "/gen/gen_progress_rows.js", .expected = .gen_progress_rows },
        .{ .path = "/menus/region.js", .expected = .region },
        .{ .path = "/menus/marks.js", .expected = .marks },
        .{ .path = "/menus/shortcuts.js", .expected = .shortcuts },
        .{ .path = "/menus/help.js", .expected = .help },
        .{ .path = "/menus/settings.js", .expected = .settings },
        .{ .path = "/site.webmanifest", .expected = .site_webmanifest },
        .{ .path = "/branding/favicon-16x16.png", .expected = .brand_favicon_16 },
        .{ .path = "/branding/favicon-32x32.png", .expected = .brand_favicon_32 },
        .{ .path = "/branding/apple-touch-icon.png", .expected = .brand_apple_touch_icon },
        .{ .path = "/branding/android-chrome-192x192.png", .expected = .brand_android_chrome_192 },
        .{ .path = "/branding/android-chrome-512x512.png", .expected = .brand_android_chrome_512 },
        .{ .path = "/branding/splash-mark-256.png", .expected = .brand_splash_mark_256 },
        .{ .path = "/branding/about-variant-96.png", .expected = .brand_about_variant_96 },
        .{ .path = "/build-info.json", .expected = .build_info },
        .{ .path = "/host-config.json", .expected = .host_config },
        .{ .path = "/artifact.wasm", .expected = .artifact },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, try Router.route(case.path));
    }
}

test "web_host: build-info body carries this host's build mode, apart from config" {
    const build_info = @import("../build_info.zig");
    const Info = struct { debug_build: bool };
    const parsed = try std.json.parseFromSlice(Info, std.testing.allocator, Router.body(.build_info), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(build_info.debug_build, parsed.value.debug_build);
    try std.testing.expectEqualStrings("application/json", Router.contentType(.build_info));
}

test "requestBody returns null when header separator is missing" {
    try std.testing.expect(requestBody("GET / HTTP/1.1\r\nHost: localhost\r\n") == null);
}

test "requestBody returns payload bytes after header separator" {
    const req =
        "POST /config.json HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\n\r\n{\"theme\":1}";
    const body = requestBody(req).?;
    try std.testing.expectEqualStrings("{\"theme\":1}", body);
}

test "client-log extracts scope/event from modern keys with legacy fallback" {
    const modern = "{\"scope\":\"autosave\",\"event\":\"persist_ok\",\"level\":\"info\"}";
    try std.testing.expectEqualStrings("autosave", clientLogScope(modern));
    try std.testing.expectEqualStrings("persist_ok", clientLogEvent(modern));

    const legacy = "{\"lane\":\"autosave\",\"stage\":\"persist_ok\",\"level\":\"info\"}";
    try std.testing.expectEqualStrings("autosave", clientLogScope(legacy));
    try std.testing.expectEqualStrings("persist_ok", clientLogEvent(legacy));
}

test "client-log scope/event defaults when payload omits fields" {
    const body = "{\"level\":\"info\"}";
    try std.testing.expectEqualStrings("client", clientLogScope(body));
    try std.testing.expectEqualStrings("message", clientLogEvent(body));
}

test "contentLength parses header value case-insensitively" {
    const req =
        "POST /current-file HTTP/1.1\r\nHost: localhost\r\ncontent-length: 12\r\n\r\nhello world!";
    const len = contentLength(req).?;
    try std.testing.expectEqual(@as(usize, 12), len);
}

test "applyConfigPost returns System on invalid JSON" {
    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = ".",
        .visible_save_dir = ".",
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    try std.testing.expectError(ServeError.System, applyConfigPost(std.testing.io, &session, "{\"theme\":"));
}

test "applyConfigPost updates in-memory host config even when disk persistence is disabled" {
    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = ".",
        .visible_save_dir = ".",
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    const body = "{\"difficulty\":\"hard\",\"log_level\":\"debug\",\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":true,\"auto_restore\":true,\"auto_new\":true,\"auto_save\":true}";
    try applyConfigPost(std.testing.io, &session, body);
    try std.testing.expectEqual(config.Difficulty.hard, session.host_config.difficulty);
    try std.testing.expectEqual(logger.Severity.debug, session.host_config.log_level);
    try std.testing.expectEqual(config.ViewTheme.light, session.host_config.theme);
    try std.testing.expect(session.host_config.show_region);
    try std.testing.expect(session.host_config.warn_solvability);
    try std.testing.expect(session.host_config.auto_restore);
    try std.testing.expect(session.host_config.auto_new);
    try std.testing.expect(session.host_config.auto_save);
}

test "a config POST body is written to config.json on disk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config.Config.default();
    const body = "{\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":false,\"auto_restore\":true,\"auto_new\":true,\"auto_save\":true}";
    try config_store.applyConfigJson(std.testing.allocator, &cfg, body);
    try config_store.saveInDir(std.testing.allocator, io, tmp.dir, cfg);

    const bytes = tmp.dir.readFileAlloc(io, config_store.file_name, std.testing.allocator, std.Io.Limit.unlimited) catch unreachable;
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"show_region\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"warn_solvability\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"auto_restore\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"auto_new\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"auto_save\":true") != null);

    const loaded = try config_store.loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(config.ViewTheme.light, loaded.theme);
    try std.testing.expect(loaded.show_region);
    try std.testing.expect(!loaded.warn_solvability);
    try std.testing.expect(loaded.auto_restore);
    try std.testing.expect(loaded.auto_new);
    try std.testing.expect(loaded.auto_save);
}

test "current-file POST writes startup snapshot and updates current_file pointer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    const body = "SUD0 v1 sample";
    try applyCurrentFilePost(io, &session, body, null, false);
    try std.testing.expect(session.has_current_file);
    try std.testing.expect(session.current_file != null);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, save_defaults.DEFAULT_SAVE_FILE });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session.current_file.?);

    const loaded_ptr = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (loaded_ptr) |p| std.testing.allocator.free(p);
    try std.testing.expect(loaded_ptr != null);
    try std.testing.expectEqualStrings(expected, loaded_ptr.?);

    const bytes = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        loaded_ptr.?,
        std.testing.allocator,
        std.Io.Limit.unlimited,
    ) catch return error.TestFailed;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, body, bytes);
}

fn forgetScenario(delete_file: bool) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);
    try applyCurrentFilePost(io, &session, "broken", null, false);
    const written = try std.testing.allocator.dupe(u8, session.current_file.?);
    defer std.testing.allocator.free(written);

    try applyCurrentFileForget(io, &session, delete_file);

    try std.testing.expect(session.current_file == null);
    try std.testing.expect(!session.has_current_file);
    const pointer = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (pointer) |p| std.testing.allocator.free(p);
    try std.testing.expect(pointer == null);
    const still_there = if (std.Io.Dir.cwd().statFile(io, written, .{})) |_| true else |_| false;
    try std.testing.expectEqual(!delete_file, still_there);
}

test "current-file DELETE forgets the pointer and deletes the file when asked" {
    try forgetScenario(true);
}

test "current-file DELETE without the delete flag forgets the pointer and keeps the file" {
    try forgetScenario(false);
}

test "current-file POST with no current file writes the visible save folder and makes it the current file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const visible_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/Documents/Sudoku", .{tmp.sub_path});
    defer std.testing.allocator.free(visible_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = visible_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first autosave", save_defaults.DEFAULT_SAVE_FILE, false);

    const expected = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/Documents/Sudoku/sudoku.sud", .{tmp.sub_path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session.current_file orelse return error.TestFailed);
    const bytes = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, expected, std.testing.allocator, std.Io.Limit.unlimited) catch return error.TestFailed;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "SUD0 first autosave", bytes);
}

test "current-file POST keeps writing a visible current file in place" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const visible_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/Documents/Sudoku", .{tmp.sub_path});
    defer std.testing.allocator.free(visible_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = visible_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", save_defaults.DEFAULT_SAVE_FILE, false);
    try applyCurrentFilePost(io, &session, "SUD0 second", save_defaults.DEFAULT_SAVE_FILE, false);

    const expected = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/Documents/Sudoku/sudoku.sud", .{tmp.sub_path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session.current_file orelse return error.TestFailed);
    const bytes = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, expected, std.testing.allocator, std.Io.Limit.unlimited) catch return error.TestFailed;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "SUD0 second", bytes);
}

test "current-file POST with a new name keeps the restore copy in the hidden data dir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const visible_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/Documents/Sudoku", .{tmp.sub_path});
    defer std.testing.allocator.free(visible_path);
    try std.Io.Dir.cwd().createDirPath(io, data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = visible_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", save_defaults.DEFAULT_SAVE_FILE, false);
    try applyCurrentFilePost(io, &session, "SUD0 renamed", "picked.sud", false);

    const expected = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data/picked.sud", .{tmp.sub_path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session.current_file orelse return error.TestFailed);
}

test "current-file POST supports explicit save name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 named", "custom-save.sud", false);
    try std.testing.expect(session.current_file != null);
    try std.testing.expect(std.mem.endsWith(u8, session.current_file.?, "/custom-save.sud"));
}

test "host-config default_save_filename follows persisted current_file basename" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 named", "my-save.sud", false);
    const body = try session.hostConfigBody();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"default_save_filename\":\"my-save.sud\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"startup_save_path\":\"/current-file\"") != null);
}

test "current-file POST without explicit name reuses existing current_file basename" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", "chosen-name.sud", false);
    const first = try std.heap.page_allocator.dupe(u8, session.current_file.?);
    defer std.heap.page_allocator.free(first);

    try applyCurrentFilePost(io, &session, "SUD0 second", null, false);
    try std.testing.expectEqualStrings(first, session.current_file.?);
}

test "current-file POST bound target overwrite does not require replace header" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", "replace-me.sud", false);
    try applyCurrentFilePost(io, &session, "SUD0 second", "replace-me.sud", false);
}

fn testSession(data_path: []const u8, visible_path: []const u8) Session {
    return .{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .visible_save_dir = visible_path,
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
}

/// How long a test waits for the host's end of a connection before calling it left open.
const CLOSE_WAIT_MS: i32 = 2000;

/// Reads `client` to end of stream, failing if the peer keeps the connection open past `CLOSE_WAIT_MS`.
fn expectStreamEnds(io: std.Io, client: net.Stream) !void {
    var buf: [512]u8 = undefined;
    while (true) {
        var fds = [_]std.posix.pollfd{.{ .fd = client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&fds, CLOSE_WAIT_MS);
        if (ready == 0) return error.ConnectionLeftOpen;
        var data: [1][]u8 = .{buf[0..]};
        const result = try client.readWithControl(io, &data, &.{});
        if (result.data_len == 0) return;
    }
}

test "web_host: the host closes a connection once it has served the request" {
    const io = std.testing.io;
    var server = try bindLoopback(io, 0);
    defer server.deinit(io);
    const client = try server.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);

    var w_buf: [64]u8 = undefined;
    var w = client.writer(io, &w_buf);
    try w.interface.writeAll("GET /nope HTTP/1.1\r\n\r\n");
    try w.interface.flush();

    var session = testSession(".", ".");
    var router = Router.init();
    const accepted = try server.accept(io);
    try serveAndClose(io, &session, &router, accepted);

    try expectStreamEnds(io, client);
}

test "current-file exists reports the visible target the next write lands on" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const visible_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/Documents/Sudoku", .{tmp.sub_path});
    defer std.testing.allocator.free(visible_path);

    var session = testSession(data_path, visible_path);
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try std.testing.expect(!try currentFileTargetExists(io, &session, save_defaults.DEFAULT_SAVE_FILE));
    try applyCurrentFilePost(io, &session, "SUD0 first", save_defaults.DEFAULT_SAVE_FILE, false);
    try std.testing.expect(try currentFileTargetExists(io, &session, save_defaults.DEFAULT_SAVE_FILE));
}

test "current-file exists never reports the hidden restore copy" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const visible_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/Documents/Sudoku", .{tmp.sub_path});
    defer std.testing.allocator.free(visible_path);
    try std.Io.Dir.cwd().createDirPath(io, data_path);

    var session = testSession(data_path, visible_path);
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", save_defaults.DEFAULT_SAVE_FILE, false);
    try applyCurrentFilePost(io, &session, "SUD0 renamed", "picked.sud", false);
    try std.testing.expect(!try currentFileTargetExists(io, &session, "picked.sud"));
}

test "restore-copy POST writes the hidden data dir and leaves the visible current file alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const visible_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/Documents/Sudoku", .{tmp.sub_path});
    defer std.testing.allocator.free(visible_path);
    try std.Io.Dir.cwd().createDirPath(io, data_path);

    var session = testSession(data_path, visible_path);
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 visible", save_defaults.DEFAULT_SAVE_FILE, false);
    try applyCurrentFilePost(io, &session, "SUD0 picked", save_defaults.DEFAULT_SAVE_FILE, true);

    const visible_file = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ visible_path, save_defaults.DEFAULT_SAVE_FILE });
    defer std.testing.allocator.free(visible_file);
    const visible_bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, visible_file, std.testing.allocator, std.Io.Limit.unlimited);
    defer std.testing.allocator.free(visible_bytes);
    try std.testing.expectEqualSlices(u8, "SUD0 visible", visible_bytes);

    const hidden_file = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, save_defaults.DEFAULT_SAVE_FILE });
    defer std.testing.allocator.free(hidden_file);
    try std.testing.expectEqualStrings(hidden_file, session.current_file orelse return error.TestFailed);
}

test "web_host: host-config body reflects active host Config" {
    var session = Session{
        .host_config = .{
            .difficulty = .medium,
            .renderers = .{ .preferred = .web, .fallback = .ansi },
            .log_level = .debug,
            .theme = .light,
            .show_region = true,
        },
        .data_dir = ".",
        .visible_save_dir = ".",
        .has_current_file = false,
        .current_file = null,
        .host_config_body_buf = undefined,
    };
    const body = try session.hostConfigBody();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"difficulty\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"log_level\":\"debug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"theme\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "true") != null);
}

test "web_host: unknown path is NotFound" {
    try std.testing.expectError(Router.Error.NotFound, Router.route("/nope.txt"));
}

test "web_host: allDelivered false until each route marked, true after; re-marking one does not satisfy the rest" {
    var r = Router.init();
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.page);
    r.markDelivered(.page);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.glue);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.gen_client);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.gen_worker);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.app_boot);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.app_wire);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.status_bar);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.play_pad);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.prompt_dialog);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.client_log);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.session);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.host_api);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.generate);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.clipboard);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.autosave);
    try std.testing.expect(!r.allDelivered());

    for ([_]router_mod.RouteResult{ .files, .steps, .web_steps, .android_steps }) |route| {
        r.markDelivered(route);
        try std.testing.expect(!r.allDelivered());
    }

    r.markDelivered(.startup);
    try std.testing.expect(!r.allDelivered());

    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.board);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.menu);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.menu_bar);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.theme);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.file_menu);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.step_runner);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.android_bridge);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.generating);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.gen_progress_rows);
    try std.testing.expect(!r.allDelivered());

    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.region);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.marks);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.shortcuts);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.help);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.settings);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.site_webmanifest);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.brand_favicon_16);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.brand_favicon_32);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.brand_apple_touch_icon);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.brand_android_chrome_192);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.brand_android_chrome_512);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.brand_splash_mark_256);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.brand_about_variant_96);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.build_info);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.host_config);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.artifact);
    try std.testing.expect(r.allDelivered());
}

test "web_host: reports AddressInUse when every probed port is in use" {
    ready_count = 0;
    try std.testing.expectError(ServeError.AddressInUse, runBlockingForTest(std.testing.io, bindInUse));
    try std.testing.expectEqual(0, ready_count);
}

test "web_host: a socket fault while probing is System, not AddressInUse" {
    ready_count = 0;
    try std.testing.expectError(ServeError.System, runBlockingForTest(std.testing.io, bindFault));
    try std.testing.expectEqual(0, ready_count);
}

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

test "web_host: writeFull flushes what the buffer still holds (short response must not sit undelivered)" {
    capture_len = 0;
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer{
        .vtable = &.{ .drain = captureDrain },
        .buffer = buf[0..],
    };
    try writeFull(&w, "200 OK", "text/plain", "hello world");
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nPragma: no-cache\r\nExpires: 0\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world",
        capture_sink[0..capture_len],
    );
}

test "web_host: on_ready runs once with the bound url" {
    ready_count = 0;
    recordReady(std.testing.io, "http://127.0.0.1:8137/");
    try std.testing.expectEqual(1, ready_count);
    try std.testing.expectEqualStrings("http://127.0.0.1:8137/", ready_last_url[0..22]);
}
