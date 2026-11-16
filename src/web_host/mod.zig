/// Loopback static host for the web app shell (desktop `-r web` and future Android WebView).
const std = @import("std");
const net = std.Io.net;
const logger = @import("../core/logger.zig");
const log = logger.Logger(.web_host);
const config = @import("../core/config.zig");
const startup_config = @import("../core/startup/config.zig");
const config_store = @import("../core/config_store.zig");
const file_transport = @import("../native/shell/file_transport.zig");
const file_path = @import("../core/path.zig");
const forget_mod = @import("../core/flow/forget.zig");
const save_mod = @import("../core/flow/save.zig");
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
    /// Allocator for per-request paths and `current_file`; tests pass a leak-checking one.
    gpa: std.mem.Allocator = std.heap.page_allocator,

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
    config_store.applyConfigJson(session.gpa, &session.host_config, body) catch return ServeError.System;
    if (session.data_dir.len == 0 or std.mem.eql(u8, session.data_dir, ".")) return;
    config_store.ensureConfigDir(io, session.data_dir);
    config_store.save(session.gpa, io, session.data_dir, session.host_config) catch return ServeError.System;
}

/// Owned write path for a current-file write, and whether it is only the hidden restore copy.
const CurrentFileTarget = struct {
    path: []u8,
    restore_copy: bool,
};

/// No current file: the default visible file. Current file with the same (or no) name: that file
/// in place. A restore copy, or a different name, goes to the hidden data dir.
fn currentFileTarget(io: std.Io, session: *const Session, save_name: ?[]const u8, restore_copy: bool) !CurrentFileTarget {
    const gpa = session.gpa;
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
    defer session.gpa.free(target.path);
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

/// What a current-file write reports to the page: a settings file the store refused to read, one it
/// refused to write (the file is sound; the disk or the permission is not), a store failure that is
/// neither, or the host hit a fault on the way. They are kept apart so only a refusal is answered in
/// core's repair words, instead of closing the connection.
const PointerWrite = error{ SettingsRefused, SettingsWriteFailed, StoreFailed, System };
/// The pointer-write error a core refusal means: both `/current-file` arms map a store error through
/// core's `refusalFor`, so the kind is decided once.
fn refusalError(reason: forget_mod.Refusal) PointerWrite {
    return switch (reason) {
        .settings_unreadable => PointerWrite.SettingsRefused,
        .settings_unwritable => PointerWrite.SettingsWriteFailed,
    };
}

/// A pointer write that failed for a reason this app cannot repair: the reason is logged here, once
/// for both arms, because no store line carried it and the body can only say the generic failure.
fn pointerFailure(reason: []const u8) PointerWrite {
    log.err("current-file pointer write failed: {s}", .{reason});
    return PointerWrite.StoreFailed;
}

/// A store error as the page's answer: its refusal when core knows that cause, else the store's own
/// error name on the log and core's generic failure.
fn pointerError(err: config_store.Error) PointerWrite {
    return if (forget_mod.refusalFor(err)) |reason| refusalError(reason) else pointerFailure(@errorName(err));
}

/// Write `body` to the file a save lands on, then record it as the current file. A settings file
/// the store refuses to read or to write makes the pointer update impossible, so the page is told
/// core's sentence rather than left with a save it cannot explain.
fn applyCurrentFilePost(io: std.Io, session: *Session, body: []const u8, save_name: ?[]const u8, restore_copy: bool) PointerWrite!void {
    if (session.data_dir.len == 0 or std.mem.eql(u8, session.data_dir, ".")) return;

    config_store.ensureConfigDir(io, session.data_dir);
    const target = currentFileTarget(io, session, save_name, restore_copy) catch return error.System;
    defer session.gpa.free(target.path);

    const transport = file_transport.NativeTransport.make(io);
    transport.write(transport.context, target.path, body) catch return error.System;

    config_store.setCurrentFile(session.gpa, io, session.data_dir, target.path) catch |err| return pointerError(err);

    if (session.current_file) |old| session.gpa.free(old);
    session.current_file = session.gpa.dupe(u8, target.path) catch return error.System;
    session.has_current_file = true;
    log.info("current-file write: bytes={d} target={s} restore_copy={any}", .{ body.len, target.path, target.restore_copy });
}

/// The host's delete for core's forget: the file the current pointer names, removed with the host's io.
const CurrentFileDelete = struct {
    io: std.Io,

    fn deleter(self: *@This()) forget_mod.Deleter {
        return forget_mod.Deleter.make(self, remove);
    }

    fn remove(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

/// Stop restoring the current file at startup; with `delete_file`, remove it from disk too. The
/// order of the two writes is core's (pointer first), so a refused clear leaves the save untouched
/// and the page is told the same cause the startup flow words. A delete that fails after the clear
/// is logged by core and still answers success: the requested state was reached.
fn applyCurrentFileForget(io: std.Io, session: *Session, delete_file: bool) PointerWrite!void {
    const current = session.current_file orelse return;
    const settings: ?forget_mod.Settings = if (session.data_dir.len == 0 or std.mem.eql(u8, session.data_dir, "."))
        null
    else
        .{ .gpa = session.gpa, .io = io, .data_dir = session.data_dir };
    var delete = CurrentFileDelete{ .io = io };
    switch (forget_mod.forget(settings, current, delete_file, delete.deleter())) {
        .refused => |reason| return refusalError(reason),
        .failed => |reason| return pointerFailure(reason),
        .forgotten => {},
    }
    log.info("current-file forget: path={s} delete_requested={any}", .{ current, delete_file });
    session.gpa.free(current);
    session.current_file = null;
    session.has_current_file = false;
}

/// Header naming which refusal stopped a pointer write, so the page answers core with the same
/// reason instead of reading core's sentence back out of the body.
const REFUSAL_HEADER = "X-Sudoku-Refusal";

/// Which `/current-file` arm is answering: a refused forget touched nothing, while a refused save
/// has already put the game file on disk, so each asks core for its own step's words.
const PointerStep = enum { save, forget };

/// Answer a pointer write to the page: `204` when it landed, core's sentence in the body and the
/// refusal kind in the header when a settings store refused it, core's generic failure when the
/// store failed for any other reason, and the connection closed on a host fault. Both arms of
/// `/current-file` answer through here, so a refusal is mapped once.
fn answerPointerWrite(w: *std.Io.Writer, step: PointerStep, result: PointerWrite!void) ServeError!void {
    result catch |err| switch (err) {
        error.SettingsRefused => return answerRefusal(w, step, .settings_unreadable),
        error.SettingsWriteFailed => return answerRefusal(w, step, .settings_unwritable),
        error.StoreFailed => return answerFailure(w, step),
        error.System => return ServeError.System,
    };
    try writeFull(w, "204 No Content", "application/octet-stream", "");
}

/// A refusal's answer: core's sentence for the step that was refused, and the kind the page hands
/// back to core so it words the outcome itself.
fn answerRefusal(w: *std.Io.Writer, step: PointerStep, reason: forget_mod.Refusal) ServeError!void {
    const words = switch (step) {
        .save => save_mod.writtenNotCurrentMsg(reason),
        .forget => reason.sentence(),
    };
    return writeFullWithHeader(w, "500 Internal Server Error", "text/plain", REFUSAL_HEADER, @tagName(reason), words);
}

/// A failure's answer: core's generic sentence for the step, and no refusal header, so the page
/// answers core with a failure rather than a settings repair that does not apply.
fn answerFailure(w: *std.Io.Writer, step: PointerStep) ServeError!void {
    const words = switch (step) {
        .save => save_mod.SAVE_FAILED_MSG,
        .forget => forget_mod.FAILED_MSG,
    };
    return writeFull(w, "500 Internal Server Error", "text/plain", words);
}

var shutdown_requested = std.atomic.Value(bool).init(false);
var listener_guard: std.Io.Mutex = .init;
/// Port the accept loop listens on while it runs, so shutdown can reach it.
var active_port: ?u16 = null;

/// Stops the accept loop: sets the flag, then connects once so a blocked `accept` returns (on Linux, closing
/// the listener from another thread does not wake it). The host thread closes the listener; `runBlocking` then returns.
pub fn requestShutdown(io: std.Io) void {
    shutdown_requested.store(true, .release);
    listener_guard.lockUncancelable(io);
    defer listener_guard.unlock(io);
    const port = active_port orelse return;
    const addr = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    const wake = addr.connect(io, .{ .mode = .stream }) catch |err| {
        log.warn("could not wake the accept loop on port {d}: {s}", .{ port, @errorName(err) });
        return;
    };
    wake.close(io);
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
        // The connection that woke us for shutdown carries no request.
        if (shutdown_requested.load(.acquire)) {
            client.close(io);
            return;
        }
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
    active_port = bound_port;
    listener_guard.unlock(io);
    defer {
        listener_guard.lockUncancelable(io);
        active_port = null;
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
    defer if (session.current_file) |p| session.gpa.free(p);
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
        try answerPointerWrite(&w.interface, .save, applyCurrentFilePost(io, session, body, headerValue(request, FILENAME_HEADER), headerFlag(request, RESTORE_COPY_HEADER)));
        return;
    }
    if (std.mem.eql(u8, method, "DELETE") and std.mem.eql(u8, req_path, CURRENT_FILE_PATH)) {
        try answerPointerWrite(&w.interface, .forget, applyCurrentFileForget(io, session, headerFlag(request, DELETE_FILE_HEADER)));
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
    return writeFullWithHeader(w, status, content_type, "", "", body);
}

/// `writeFull` plus one header line; an empty `header_name` writes none.
/// `header_name`/`header_value`: the extra response header, e.g. which refusal this answer reports.
fn writeFullWithHeader(
    w: *std.Io.Writer,
    status: []const u8,
    content_type: []const u8,
    header_name: []const u8,
    header_value: []const u8,
    body: []const u8,
) ServeError!void {
    std.Io.Writer.print(
        w,
        // Local loopback host must always reflect live policy/state and fresh JS.
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nCache-Control: no-store\r\nPragma: no-cache\r\nExpires: 0\r\nContent-Length: {d}\r\nConnection: close\r\n",
        .{ status, content_type, body.len },
    ) catch return ServeError.System;
    if (header_name.len != 0) std.Io.Writer.print(w, "{s}: {s}\r\n", .{ header_name, header_value }) catch return ServeError.System;
    std.Io.Writer.writeAll(w, "\r\n") catch return ServeError.System;
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
}

test "web_host: the shell is pinned to the viewport and the board is sized from its area" {
    // The document cannot scroll and the menubar never needs to stay pinned by sticky:
    // the play area takes the space the fixed chrome leaves, and one measurement sizes the board from it.
    // The measured-layout gate proves the result; these checks keep the mechanism from drifting.
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "id=\"play-area\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "#play-area {") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "flex: 1 1 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "overflow: hidden;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "ResizeObserver") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "position: sticky;") == null);
}

test "web_host: the status bar hangs off the board's bottom edge" {
    // The bar is attached to the board by a small gutter and owns no air of its own above.
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "margin-top: var(--pad-gap);") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "margin-bottom: 0;") != null);
}

test "web_host: board, status bar and pad form one fixture" {
    // The pad hangs off the status bar, and nothing is pinned to the screen floor any more.
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "<div id=\"play-area\">") != null);
    const area_at = std.mem.indexOf(u8, embed.page_html, "<div id=\"play-area\">").?;
    const pad_at = std.mem.indexOf(u8, embed.page_html, "<div id=\"play-pad\"").?;
    try std.testing.expect(pad_at > area_at);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "margin-top: auto;") == null);
}

test "web_host: the board has a floor so it cannot shrink into nothing" {
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "--board-floor:") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "min-width: var(--board-floor);") != null);
}

test "web_host: phones keep a side gutter under a full-width menubar" {
    // The gutter is a shell side padding, so the menubar above it still spans the screen.
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "--shell-gutter-x: 0.5rem;") != null);
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "padding: 0 var(--shell-gutter-x);") != null);
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

/// The bytes a pointer write's page reads, produced by the one answer helper both arms end at.
fn pointerWriteAnswer(step: PointerStep, result: PointerWrite!void) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    try answerPointerWrite(&aw.writer, step, result);
    return aw.toOwnedSlice();
}

test "one answer serves both pointer writes: core's words for a refusal, one 204 for a success" {
    const refused = try pointerWriteAnswer(.forget, error.SettingsRefused);
    defer std.testing.allocator.free(refused);
    try std.testing.expect(std.mem.endsWith(u8, refused, startup_config.SETTINGS_REFUSED_MSG));
    try std.testing.expect(std.mem.indexOf(u8, refused, "X-Sudoku-Refusal: settings_unreadable\r\n") != null);

    const write_failed = try pointerWriteAnswer(.forget, error.SettingsWriteFailed);
    defer std.testing.allocator.free(write_failed);
    try std.testing.expect(std.mem.endsWith(u8, write_failed, startup_config.SETTINGS_WRITE_FAILED_MSG));
    try std.testing.expect(std.mem.indexOf(u8, write_failed, "X-Sudoku-Refusal: settings_unwritable\r\n") != null);
    // The read refusal's sentence would send the player to repair a file that is sound.
    try std.testing.expect(std.mem.indexOf(u8, write_failed, startup_config.SETTINGS_REFUSED_MSG) == null);

    // The save arm answers with the sentence that says the game file was written, same causes.
    const written = try pointerWriteAnswer(.save, error.SettingsRefused);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.endsWith(u8, written, save_mod.WRITTEN_SETTINGS_REFUSED_MSG));
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Sudoku-Refusal: settings_unreadable\r\n") != null);
    const written_failed = try pointerWriteAnswer(.save, error.SettingsWriteFailed);
    defer std.testing.allocator.free(written_failed);
    try std.testing.expect(std.mem.endsWith(u8, written_failed, save_mod.WRITTEN_SETTINGS_WRITE_FAILED_MSG));
    try std.testing.expect(std.mem.indexOf(u8, written_failed, "X-Sudoku-Refusal: settings_unwritable\r\n") != null);

    const saved = try pointerWriteAnswer(.save, {});
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.startsWith(u8, saved, "HTTP/1.1 204 No Content"));

    // A host fault has no sentence for the player: the connection is closed, not answered.
    try std.testing.expectError(ServeError.System, pointerWriteAnswer(.save, error.System));
}

test "a store error that is no refusal is logged once and answered with core's generic failure" {
    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;
    logger.min_level = .err;
    defer logger.min_level = .info;

    // The two causes core knows keep their refusal, and the store words them on its own line.
    try std.testing.expectEqual(PointerWrite.SettingsRefused, pointerError(config_store.Error.System));
    try std.testing.expectEqual(PointerWrite.SettingsWriteFailed, pointerError(config_store.Error.WriteFailed));
    try std.testing.expectEqual(@as(usize, 0), sink.buffered().len);

    // Any other store error is nobody's repair: it is logged here once, with the system message.
    try std.testing.expectEqual(PointerWrite.StoreFailed, pointerError(config_store.Error.OutOfMemory));
    try std.testing.expectEqualStrings("err [web_host] current-file pointer write failed: OutOfMemory\n", sink.buffered());

    // A failure is answered with core's generic sentence and no refusal header, so the page hands
    // core a failure instead of a settings repair that does not apply.
    const save_reply = try pointerWriteAnswer(.save, error.StoreFailed);
    defer std.testing.allocator.free(save_reply);
    try std.testing.expect(std.mem.startsWith(u8, save_reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, save_reply, save_mod.SAVE_FAILED_MSG));
    try std.testing.expect(std.mem.indexOf(u8, save_reply, REFUSAL_HEADER) == null);

    const forget_reply = try pointerWriteAnswer(.forget, error.StoreFailed);
    defer std.testing.allocator.free(forget_reply);
    try std.testing.expect(std.mem.startsWith(u8, forget_reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, forget_reply, forget_mod.FAILED_MSG));
    try std.testing.expect(std.mem.indexOf(u8, forget_reply, REFUSAL_HEADER) == null);
}

/// A data directory under the test's temp dir, with `config.json` taken by a directory so no read
/// can succeed on it — the fixture fails for root and an ordinary user alike.
fn scenarioDataPathWithUnreadableSettings(tmp: *std.testing.TmpDir, io: std.Io) ![]const u8 {
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    errdefer std.testing.allocator.free(data_path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, config_store.file_name });
    defer std.testing.allocator.free(config_path);
    try std.Io.Dir.cwd().createDirPath(io, config_path);
    return data_path;
}

test "current-file POST on an unreadable settings file answers with core's written sentence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try scenarioDataPathWithUnreadableSettings(&tmp, io);
    defer std.testing.allocator.free(data_path);

    var session = testSession(data_path, data_path);
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "POST", "SUD0 v1 refused", "", &reply_buf);

    // The page gets an answer with words in it, not a closed connection with no explanation.
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, reply, save_mod.WRITTEN_SETTINGS_REFUSED_MSG));
    // The bytes landed before the pointer write was refused, so the save is on disk as written.
    const saved = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, save_defaults.DEFAULT_SAVE_FILE });
    defer std.testing.allocator.free(saved);
    const written = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, saved, std.testing.allocator, std.Io.Limit.unlimited) catch return error.TestFailed;
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, "SUD0 v1 refused", written);
}

/// A data directory under the test's temp dir holding a sound `config.json` that carries no write
/// permission: the read succeeds where the write is refused, the shape a full disk or a permission
/// failure leaves behind. Root writes into such a file anyway, so the scenario says it could not set
/// itself up rather than assert a refusal it never earned.
fn scenarioDataPathWithReadOnlySettings(tmp: *std.testing.TmpDir, io: std.Io) ![]const u8 {
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    errdefer std.testing.allocator.free(data_path);
    try config_store.save(std.testing.allocator, io, data_path, config.Config.default());
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, config_store.file_name });
    defer std.testing.allocator.free(config_path);
    try std.Io.Dir.cwd().setFilePermissions(io, config_path, .fromMode(0o444), .{});
    return data_path;
}

/// Puts write permission back on the settings file the scenario above took it off, so the temp tree
/// can be removed after the test.
fn restoreSettingsWritePermission(io: std.Io, data_path: []const u8) void {
    const config_path = std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, config_store.file_name }) catch |err| {
        log.err("could not name the scenario settings file in {s}: {s}", .{ data_path, @errorName(err) });
        return;
    };
    defer std.testing.allocator.free(config_path);
    std.Io.Dir.cwd().setFilePermissions(io, config_path, .fromMode(0o644), .{}) catch |err| {
        log.err("could not restore write permission on the scenario settings file {s}: {s}", .{ config_path, @errorName(err) });
    };
}

/// Whether the settings file accepts a write, so a scenario that needs it refused knows it can. The
/// probe opens the file for writing without truncating it, leaving its bytes as they were.
fn settingsFileAcceptsWrites(io: std.Io, data_path: []const u8) !bool {
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, config_store.file_name });
    defer std.testing.allocator.free(config_path);
    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = config_path, .data = "", .flags = .{ .truncate = false } }) catch |err| {
        log.info("expected: the scenario settings file {s} refuses a write ({s})", .{ config_path, @errorName(err) });
        return false;
    };
    return true;
}

test "current-file POST on a settings file the store cannot write answers with core's written sentence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try scenarioDataPathWithReadOnlySettings(&tmp, io);
    defer std.testing.allocator.free(data_path);
    defer restoreSettingsWritePermission(io, data_path);

    // Root writes into a read-only file anyway, so this scenario has nothing to show.
    if (try settingsFileAcceptsWrites(io, data_path)) return error.SkipZigTest;

    // The save itself lands in a writable folder; only the settings write is refused.
    const save_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/saves", .{tmp.sub_path});
    defer std.testing.allocator.free(save_path);

    var session = testSession(data_path, save_path);
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "POST", "SUD0 v1 refused", "", &reply_buf);

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, reply, save_mod.WRITTEN_SETTINGS_WRITE_FAILED_MSG));
    // The read refusal's sentence would send the player to repair a file that is sound.
    try std.testing.expect(std.mem.indexOf(u8, reply, startup_config.SETTINGS_REFUSED_MSG) == null);
    // The write that was refused is the pointer; the bytes it follows are on disk.
    const saved = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ save_path, save_defaults.DEFAULT_SAVE_FILE });
    defer std.testing.allocator.free(saved);
    const written = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, saved, std.testing.allocator, std.Io.Limit.unlimited) catch return error.TestFailed;
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, "SUD0 v1 refused", written);
}

test "current-file DELETE on a settings file the store cannot write answers with core's write sentence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try scenarioDataPathWithReadOnlySettings(&tmp, io);
    defer std.testing.allocator.free(data_path);
    defer restoreSettingsWritePermission(io, data_path);

    // Root writes into a read-only file anyway, so this scenario has nothing to show.
    if (try settingsFileAcceptsWrites(io, data_path)) return error.SkipZigTest;

    // Clearing the pointer needs a current file, so the session already points at a save.
    const saved_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/saved.sud", .{tmp.sub_path});
    defer std.testing.allocator.free(saved_path);
    var session = testSession(data_path, data_path);
    session.current_file = try std.heap.page_allocator.dupe(u8, saved_path);
    session.has_current_file = true;
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "DELETE", "", "", &reply_buf);

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, reply, startup_config.SETTINGS_WRITE_FAILED_MSG));
    // The read refusal's sentence would send the player to repair a file that is sound.
    try std.testing.expect(std.mem.indexOf(u8, reply, startup_config.SETTINGS_REFUSED_MSG) == null);
}

test "current-file POST on a writable settings file saves, records the pointer and answers 204" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = testSession(data_path, data_path);
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    const body = "SUD0 v1 saved";
    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "POST", body, "", &reply_buf);

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 204"));
    try std.testing.expect(std.mem.indexOf(u8, reply, startup_config.SETTINGS_REFUSED_MSG) == null);

    const pointer = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (pointer) |p| std.testing.allocator.free(p);
    try std.testing.expectEqualStrings(session.current_file.?, pointer.?);
    const written = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, pointer.?, std.testing.allocator, std.Io.Limit.unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(body, written);
}

test "current-file DELETE on an unreadable settings file answers with core's sentence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try scenarioDataPathWithUnreadableSettings(&tmp, io);
    defer std.testing.allocator.free(data_path);
    const saved_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/saved.sud", .{tmp.sub_path});
    defer std.testing.allocator.free(saved_path);

    // Clearing the pointer needs a current file, so the session already points at a save.
    var session = testSession(data_path, data_path);
    session.current_file = try std.heap.page_allocator.dupe(u8, saved_path);
    session.has_current_file = true;
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "DELETE", "", "", &reply_buf);

    // The page gets an answer with words in it, not a closed connection with no explanation.
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, reply, startup_config.SETTINGS_REFUSED_MSG));
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

/// Writes `bytes` to `path` and makes `session` name it as the current file; the caller owns the
/// session's path and frees it with the page allocator.
fn pointSessionAtSave(session: *Session, io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse ".");
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = path, .data = bytes });
    session.current_file = try std.heap.page_allocator.dupe(u8, path);
    session.has_current_file = true;
}

test "a refused forget with the delete flag leaves the save on disk and the session naming it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try scenarioDataPathWithUnreadableSettings(&tmp, io);
    defer std.testing.allocator.free(data_path);
    const save_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/saves/game.sud", .{tmp.sub_path});
    defer std.testing.allocator.free(save_path);

    var session = testSession(data_path, data_path);
    try pointSessionAtSave(&session, io, save_path, "SUD0 v1 refused forget");
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "DELETE", "", "X-Sudoku-Delete-File: true\r\n", &reply_buf);

    // The clear is the write that can be refused, so it goes first: the player's save is untouched.
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, reply, startup_config.SETTINGS_REFUSED_MSG));
    _ = try std.Io.Dir.cwd().statFile(io, save_path, .{});
    try std.testing.expectEqualStrings(save_path, session.current_file.?);
    try std.testing.expect(session.has_current_file);
}

test "a refused forget without the delete flag changes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try scenarioDataPathWithUnreadableSettings(&tmp, io);
    defer std.testing.allocator.free(data_path);
    const save_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/saves/game.sud", .{tmp.sub_path});
    defer std.testing.allocator.free(save_path);

    var session = testSession(data_path, data_path);
    try pointSessionAtSave(&session, io, save_path, "SUD0 v1 kept");
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "DELETE", "", "", &reply_buf);

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, reply, startup_config.SETTINGS_REFUSED_MSG));
    _ = try std.Io.Dir.cwd().statFile(io, save_path, .{});
    try std.testing.expectEqualStrings(save_path, session.current_file.?);
}

test "a refused forget leaves the pointer in the settings file naming the save" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const save_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/saves/game.sud", .{tmp.sub_path});
    defer std.testing.allocator.free(save_path);

    var session = testSession(data_path, data_path);
    try pointSessionAtSave(&session, io, save_path, "SUD0 v1 pointed");
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    // A settings file that reads and refuses writes: the pointer is readable, the clear is not.
    try config_store.save(std.testing.allocator, io, data_path, config.Config.default());
    try config_store.setCurrentFile(std.testing.allocator, io, data_path, save_path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_path, config_store.file_name });
    defer std.testing.allocator.free(config_path);
    try std.Io.Dir.cwd().setFilePermissions(io, config_path, .fromMode(0o444), .{});
    defer restoreSettingsWritePermission(io, data_path);
    if (try settingsFileAcceptsWrites(io, data_path)) return error.SkipZigTest;

    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "DELETE", "", "X-Sudoku-Delete-File: true\r\n", &reply_buf);

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.endsWith(u8, reply, startup_config.SETTINGS_WRITE_FAILED_MSG));
    _ = try std.Io.Dir.cwd().statFile(io, save_path, .{});
    const pointer = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (pointer) |p| std.testing.allocator.free(p);
    try std.testing.expectEqualStrings(save_path, pointer orelse return error.TestFailed);
}

test "a delete that fails after the clear answers 204 and logs the file it could not delete" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const save_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/readonly", .{tmp.sub_path});
    defer std.testing.allocator.free(save_dir);
    const save_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/game.sud", .{save_dir});
    defer std.testing.allocator.free(save_path);
    const probe_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/probe.sud", .{save_dir});
    defer std.testing.allocator.free(probe_path);

    var session = testSession(data_path, data_path);
    try pointSessionAtSave(&session, io, save_path, "SUD0 v1 undeletable");
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = probe_path, .data = "probe" });
    try config_store.save(std.testing.allocator, io, data_path, config.Config.default());
    try config_store.setCurrentFile(std.testing.allocator, io, data_path, save_path);
    try std.Io.Dir.cwd().setFilePermissions(io, save_dir, .fromMode(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io, save_dir, .fromMode(0o755), .{}) catch {};

    // Root deletes inside a read-only folder anyway, so this scenario has nothing to show.
    const probe_deleted = if (std.Io.Dir.cwd().deleteFile(io, probe_path)) |_| true else |_| false;
    if (probe_deleted) return error.SkipZigTest;

    var logged: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;
    logger.min_level = .warn;
    defer logger.min_level = .info;

    var reply_buf: [512]u8 = undefined;
    const reply = try pointerRequestReply(io, &session, "DELETE", "", "X-Sudoku-Delete-File: true\r\n", &reply_buf);

    // The pointer is clear, so the requested state is reached even though the file stayed.
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 204"));
    try std.testing.expect(session.current_file == null);
    try std.testing.expect(!session.has_current_file);
    const pointer = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (pointer) |p| std.testing.allocator.free(p);
    try std.testing.expect(pointer == null);
    _ = try std.Io.Dir.cwd().statFile(io, save_path, .{});

    // One line, naming what was not deleted and why; the request itself stays a success.
    const said = sink.buffered();
    try std.testing.expect(std.mem.indexOf(u8, said, "could not delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, save_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "AccessDenied") != null);
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

/// Sends `request` over a fresh loopback connection, serves it the way the accept loop does, and drains the reply.
fn serveOneRequest(io: std.Io, server: *net.Server, session: *Session, router: *Router, request: []const u8) !void {
    const client = try server.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var w_buf: [256]u8 = undefined;
    var w = client.writer(io, &w_buf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    try serveAndClose(io, session, router, try server.accept(io));
    try expectStreamEnds(io, client);
}

/// Serves one `method` on `/current-file` carrying `body` and `headers` the way the accept loop
/// does, and returns the page's reply — status line, headers and body — so a test can read what the
/// browser receives. `session` supplies the data directory whose settings file the request's
/// pointer write must be able to preserve.
fn pointerRequestReply(io: std.Io, session: *Session, method: []const u8, body: []const u8, headers: []const u8, reply_buf: []u8) ![]const u8 {
    var server = try bindLoopback(io, 0);
    defer server.deinit(io);
    var request_buf: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buf, "{s} {s} HTTP/1.1\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ method, CURRENT_FILE_PATH, headers, body.len, body });

    const client = try server.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var w_buf: [256]u8 = undefined;
    var w = client.writer(io, &w_buf);
    try w.interface.writeAll(request);
    try w.interface.flush();

    var router = Router.init();
    try serveAndClose(io, session, &router, try server.accept(io));

    var used: usize = 0;
    while (used < reply_buf.len) {
        var data: [1][]u8 = .{reply_buf[used..]};
        const result = try client.readWithControl(io, &data, &.{});
        if (result.data_len == 0) break;
        used += result.data_len;
    }
    return reply_buf[0..used];
}

/// How long a test waits for the host to stop after `requestShutdown`.
const SHUTDOWN_WAIT_MS = 2000;
const POLL_MS = 10;

var host_stopped = std.atomic.Value(bool).init(false);

fn runHostUntilStopped(io: std.Io) void {
    runBlockingForTest(io, bindLoopback) catch |err| log.warn("test host ended with {s}", .{@errorName(err)});
    host_stopped.store(true, .release);
}

/// Sleeps one poll interval; tests have no reason to be cancelled mid-wait.
fn pollSleep(io: std.Io) void {
    io.sleep(.fromMilliseconds(POLL_MS), .awake) catch |err| log.info("expected: poll sleep cut short ({s})", .{@errorName(err)});
}

test "web_host: requestShutdown wakes the blocked accept loop and the host stops" {
    const io = std.testing.io;
    ready_count = 0;
    host_stopped.store(false, .release);
    const host = try std.Thread.spawn(.{}, runHostUntilStopped, .{io});

    var waited: u32 = 0;
    while (@atomicLoad(usize, &ready_count, .acquire) == 0 and waited < SHUTDOWN_WAIT_MS) : (waited += POLL_MS) pollSleep(io);
    try std.testing.expect(@atomicLoad(usize, &ready_count, .acquire) == 1);

    requestShutdown(io);
    waited = 0;
    while (!host_stopped.load(.acquire) and waited < SHUTDOWN_WAIT_MS) : (waited += POLL_MS) pollSleep(io);
    // A host still blocked in accept is left behind rather than joined, so the failure reports instead of hanging.
    try std.testing.expect(host_stopped.load(.acquire));
    host.join();
}

/// Requests per round in the long-session leak test; each round is what one autosaved move can send.
const LEAK_ROUNDS = 50;

test "web_host: a long session of moves, config changes and restores leaks nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    var session = testSession(data_path, data_path);
    session.gpa = std.testing.allocator;
    defer if (session.current_file) |p| std.testing.allocator.free(p);

    var config_buf: [1024]u8 = undefined;
    var config_w: std.Io.Writer = .fixed(&config_buf);
    try config_store.writeConfigJson(&config_w, config.Config.default());
    const config_body = config_w.buffered();
    const game = "SUD0 v1 sample";

    var request_buf: [2048]u8 = undefined;
    const requests = [_][]const u8{
        try std.fmt.bufPrint(request_buf[0..1024], "POST {s} HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ CONFIG_PATH, config_body.len, config_body }),
        try std.fmt.bufPrint(request_buf[1024..1280], "POST {s} HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ CURRENT_FILE_PATH, game.len, game }),
        try std.fmt.bufPrint(request_buf[1280..1536], "POST {s} HTTP/1.1\r\n{s}: true\r\nContent-Length: {d}\r\n\r\n{s}", .{ CURRENT_FILE_PATH, RESTORE_COPY_HEADER, game.len, game }),
        try std.fmt.bufPrint(request_buf[1536..1792], "GET {s} HTTP/1.1\r\n\r\n", .{CURRENT_FILE_EXISTS_PATH}),
        try std.fmt.bufPrint(request_buf[1792..2048], "GET {s} HTTP/1.1\r\n\r\n", .{CURRENT_FILE_PATH}),
    };

    var server = try bindLoopback(io, 0);
    defer server.deinit(io);
    var router = Router.init();
    for (0..LEAK_ROUNDS) |_| {
        for (requests) |request| try serveOneRequest(io, &server, &session, &router, request);
    }
    try std.testing.expect(session.current_file != null);
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
