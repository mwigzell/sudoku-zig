/// Loopback static host for the web app shell (desktop `-r web` and future Android WebView).
const std = @import("std");
const net = std.Io.net;
const logger = @import("../logger.zig");
const log = logger.Logger(.web_host);
const config = @import("../config.zig");
const startup_config = @import("../startup/config.zig");
const settings_store = @import("../settings_store.zig");
const file_transport = @import("../native/shell/file_transport.zig");
const file_path = @import("../native/shell/path.zig");
const save_defaults = @import("../save_defaults.zig");
const file_policy = @import("../file_policy.zig");
const router_mod = @import("router.zig");
const embed = @import("embed.zig");

/// HTTP path routing and embedded response bodies (see `router.zig`).
pub const Router = router_mod.Router;
/// Discriminant for a known loopback URL the web shell may request.
pub const RouteResult = router_mod.RouteResult;

/// Loopback host failed to start: no free port in the probe range, or an I/O fault.
pub const ServeError = error{ AddressInUse, Conflict, System };

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
    /// Host-computed startup metadata: web restore depends on capability+path.
    has_current_file: bool,
    current_file: ?[]const u8,
    write_context: file_policy.WriteContext,
    host_config_body_buf: [384]u8,

    fn hostConfigBody(self: *Session) ServeError![]const u8 {
        const startup_name = startupFilename(self.current_file);
        return startup_config.formatHostStartupJsonWithPolicy(self.host_config, self.has_current_file, startup_name, &self.host_config_body_buf) catch return ServeError.System;
    }
};

const SettingsPostBody = struct {
    difficulty: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    show_region: ?bool = null,
    warn_solvability: ?bool = null,
    auto_restore: ?bool = null,
    auto_new: ?bool = null,
    auto_save: ?bool = null,
};

fn mergeDifficultyPatch(cfg: *config.Config, name: []const u8) void {
    if (std.mem.eql(u8, name, "easy")) cfg.difficulty = .easy else if (std.mem.eql(u8, name, "medium")) cfg.difficulty = .medium else if (std.mem.eql(u8, name, "hard")) cfg.difficulty = .hard;
}

fn mergeLogLevelPatch(cfg: *config.Config, name: []const u8) void {
    if (std.mem.eql(u8, name, "debug")) cfg.log_level = .debug else if (std.mem.eql(u8, name, "info")) cfg.log_level = .info else if (std.mem.eql(u8, name, "warn")) cfg.log_level = .warn else if (std.mem.eql(u8, name, "err")) cfg.log_level = .err else if (std.mem.eql(u8, name, "fatal")) cfg.log_level = .fatal;
}

/// Applies partial fields from a `POST /settings.json` body onto host `Config` (shared with the HTTP handler).
pub fn mergeSettingsPostPatch(cfg: *config.Config, patch: SettingsPostBody) void {
    if (patch.difficulty) |name| mergeDifficultyPatch(cfg, name);
    if (patch.log_level) |name| mergeLogLevelPatch(cfg, name);
    if (patch.theme) |name| {
        cfg.theme = if (std.mem.eql(u8, name, "light")) .light else .dark;
    }
    if (patch.show_region) |enabled| cfg.show_region = enabled;
    if (patch.warn_solvability) |enabled| cfg.warn_solvability = enabled;
    if (patch.auto_restore) |enabled| cfg.auto_restore = enabled;
    if (patch.auto_new) |enabled| cfg.auto_new = enabled;
    if (patch.auto_save) |enabled| cfg.auto_save = enabled;
}

fn requestBody(request: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return null;
    return request[sep + 4 ..];
}

fn contentLength(request: []const u8) ?usize {
    const line_end = std.mem.indexOfPos(u8, request, 0, "\r\n") orelse return null;
    const headers = request[line_end + 2 ..];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const raw = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            return std.fmt.parseInt(usize, raw, 10) catch null;
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

fn allowsReplace(request: []const u8) bool {
    const raw = headerValue(request, "X-Sudoku-Replace") orelse return false;
    const value = std.mem.trim(u8, raw, " \t");
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1");
}

fn applySettingsPost(io: std.Io, session: *Session, body: []const u8) ServeError!void {
    const parsed = std.json.parseFromSlice(SettingsPostBody, std.heap.page_allocator, body, .{}) catch return ServeError.System;
    defer parsed.deinit();
    mergeSettingsPostPatch(&session.host_config, parsed.value);
    const gpa = std.heap.page_allocator;
    if (session.data_dir.len == 0 or std.mem.eql(u8, session.data_dir, ".")) return;
    settings_store.ensureSettingsDir(io, session.data_dir);
    settings_store.save(gpa, io, session.data_dir, session.host_config) catch return ServeError.System;
}

fn applyCurrentFilePost(io: std.Io, session: *Session, body: []const u8, save_name: ?[]const u8, allow_replace: bool) ServeError!void {
    if (session.data_dir.len == 0 or std.mem.eql(u8, session.data_dir, ".")) return;

    settings_store.ensureSettingsDir(io, session.data_dir);
    const target_name = blk: {
        if (save_name) |n| {
            const trimmed = std.mem.trim(u8, n, " \t");
            if (validSaveName(trimmed)) break :blk trimmed;
        }
        if (session.current_file) |existing| {
            const base = std.fs.path.basename(existing);
            if (validSaveName(base)) break :blk base;
        }
        break :blk save_defaults.DEFAULT_SAVE_FILE;
    };
    const resolved = file_path.resolveSavePath(std.heap.page_allocator, session.data_dir, target_name) catch return ServeError.System;
    defer std.heap.page_allocator.free(resolved);

    const stat = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return ServeError.System,
    };
    const decision = file_policy.evaluateOverwritePolicy(.{
        .intent = .auto_save,
        .target_exists = stat != null,
        .write_context = session.write_context,
    });
    if (decision == .require_replace_confirm and !allow_replace) return ServeError.Conflict;

    const transport = file_transport.NativeTransport.make(io);
    transport.write(transport.context, resolved, body) catch return ServeError.System;

    settings_store.setCurrentFile(std.heap.page_allocator, io, session.data_dir, resolved) catch return ServeError.System;

    if (session.current_file) |old| std.heap.page_allocator.free(old);
    session.current_file = std.heap.page_allocator.dupe(u8, resolved) catch return ServeError.System;
    session.has_current_file = true;
    session.write_context = file_policy.nextWriteContext(session.write_context, .auto_save_success);
}

fn applyCurrentFileContextEvent(io: std.Io, session: *Session, event_name: []const u8) ServeError!void {
    _ = io;
    const event = file_policy.parseWriteContextEvent(event_name) orelse return ServeError.System;
    session.write_context = file_policy.nextWriteContext(session.write_context, event);
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
        errdefer client.close(io);
        try serveClient(io, session, &rt_router, client);
    }
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
            BindError.InUse => continue,
            else => return ServeError.System,
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
pub fn runBlocking(io: std.Io, bind: BindFn, host_cfg: config.Config, data_dir: []const u8, on_ready: OnReadyFn) ServeError!void {
    shutdown_requested.store(false, .release);

    const current_file = settings_store.loadCurrentFile(std.heap.page_allocator, io, data_dir) catch null;
    var session = Session{
        .host_config = host_cfg,
        .data_dir = data_dir,
        .has_current_file = current_file != null,
        .current_file = current_file,
        .write_context = .detached,
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

/// Host-resolved startup config and caller-owned settings directory for POST persistence.
pub fn runWithHostConfig(io: std.Io, bind: BindFn, host_cfg: config.Config, data_dir: []const u8, on_ready: OnReadyFn) ServeError!void {
    return runBlocking(io, bind, host_cfg, data_dir, on_ready);
}

fn serveClient(io: std.Io, session: *Session, rt_router: *Router, client: net.Stream) ServeError!void {
    var in_buf: [8192]u8 = undefined;
    var used: usize = 0;
    while (used < in_buf.len) {
        var data: [1][]u8 = .{in_buf[used..]};
        const n = client.read(io, &data) catch return ServeError.System;
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

    var w_buf: [4096]u8 = undefined;
    var w = client.writer(io, w_buf[0..]);

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, req_path, "/settings.json")) {
        const body = requestBody(request) orelse return ServeError.System;
        try applySettingsPost(io, session, body);
        try writeFull(&w.interface, "204 No Content", "application/json", "");
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, req_path, "/current-file")) {
        const body = requestBody(request) orelse return ServeError.System;
        const save_name = headerValue(request, "X-Sudoku-Filename");
        applyCurrentFilePost(io, session, body, save_name, allowsReplace(request)) catch |err| switch (err) {
            ServeError.Conflict => {
                try writeFull(&w.interface, "409 Conflict", "text/plain", file_policy.REPLACE_CONFIRM_MSG);
                return;
            },
            else => return err,
        };
        try writeFull(&w.interface, "204 No Content", "application/octet-stream", "");
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, req_path, "/current-file-context")) {
        const body = requestBody(request) orelse return ServeError.System;
        const event_name = std.mem.trim(u8, body, " \t\r\n");
        if (event_name.len == 0) return ServeError.System;
        try applyCurrentFileContextEvent(io, session, event_name);
        try writeFull(&w.interface, "204 No Content", "application/octet-stream", "");
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, req_path, "/current-file")) {
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
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
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
    return runBlocking(io, bind, config.Config.default(), ".", recordReady);
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
        const path = if (std.mem.startsWith(u8, spec, "./"))
            spec[1..]
        else if (std.mem.startsWith(u8, spec, "../"))
            spec[2..]
        else
            spec;
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
        .{ .name = "shell.js", .body = embed.shell_js },
        .{ .name = "board.js", .body = embed.board_js },
        .{ .name = "menu.js", .body = embed.menu_js },
        .{ .name = "file_menu.js", .body = embed.file_menu_js },
        .{ .name = "gen_worker.js", .body = embed.gen_worker_js },
        .{ .name = "generating.js", .body = embed.generating_js },
        .{ .name = "gen_progress_rows.js", .body = embed.gen_progress_rows_js },
        .{ .name = "gen_progress_format.js", .body = embed.gen_progress_format_js },
    };
    for (modules) |m| {
        try expectJsImportsServed(m.body, m.name);
    }
}

test "web_host: page.html wasm fetch path is served" {
    try std.testing.expect(std.mem.indexOf(u8, embed.page_html, "fetch(\"./artifact.wasm\")") != null);
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

test "web_host: route map resolves every served path" {
    const cases = [_]struct { path: []const u8, expected: RouteResult }{
        .{ .path = "/", .expected = .page },
        .{ .path = "/glue.js", .expected = .glue },
        .{ .path = "/gen_client.js", .expected = .gen_client },
        .{ .path = "/gen_worker.js", .expected = .gen_worker },
        .{ .path = "/shell.js", .expected = .shell },
        .{ .path = "/board.js", .expected = .board },
        .{ .path = "/menu.js", .expected = .menu },
        .{ .path = "/menu_bar.js", .expected = .menu_bar },
        .{ .path = "/theme.js", .expected = .theme },
        .{ .path = "/file_menu.js", .expected = .file_menu },
        .{ .path = "/generating.js", .expected = .generating },
        .{ .path = "/gen_progress_rows.js", .expected = .gen_progress_rows },
        .{ .path = "/gen_progress_format.js", .expected = .gen_progress_format },
        .{ .path = "/region.js", .expected = .region },
        .{ .path = "/help.js", .expected = .help },
        .{ .path = "/settings.js", .expected = .settings },
        .{ .path = "/site.webmanifest", .expected = .site_webmanifest },
        .{ .path = "/branding/favicon-16x16.png", .expected = .brand_favicon_16 },
        .{ .path = "/branding/favicon-32x32.png", .expected = .brand_favicon_32 },
        .{ .path = "/branding/apple-touch-icon.png", .expected = .brand_apple_touch_icon },
        .{ .path = "/branding/android-chrome-192x192.png", .expected = .brand_android_chrome_192 },
        .{ .path = "/branding/android-chrome-512x512.png", .expected = .brand_android_chrome_512 },
        .{ .path = "/branding/splash-mark-256.png", .expected = .brand_splash_mark_256 },
        .{ .path = "/branding/about-variant-96.png", .expected = .brand_about_variant_96 },
        .{ .path = "/host-config.json", .expected = .host_config },
        .{ .path = "/artifact.wasm", .expected = .artifact },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, try Router.route(case.path));
    }
}

test "mergeSettingsPostPatch updates view prefs on Config" {
    var cfg = config.Config.default();
    mergeSettingsPostPatch(&cfg, .{
        .difficulty = "hard",
        .log_level = "debug",
        .theme = "light",
        .show_region = true,
        .warn_solvability = true,
        .auto_restore = true,
        .auto_new = true,
        .auto_save = true,
    });
    try std.testing.expectEqual(config.Difficulty.hard, cfg.difficulty);
    try std.testing.expectEqual(logger.Severity.debug, cfg.log_level);
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);
    try std.testing.expect(cfg.show_region);
    try std.testing.expect(cfg.warn_solvability);
    try std.testing.expect(cfg.auto_restore);
    try std.testing.expect(cfg.auto_new);
    try std.testing.expect(cfg.auto_save);
}

test "mergeSettingsPostPatch ignores unknown difficulty/log level and defaults non-light theme to dark" {
    var cfg = config.Config.default();
    cfg.difficulty = .medium;
    cfg.log_level = .warn;
    cfg.theme = .light;

    mergeSettingsPostPatch(&cfg, .{
        .difficulty = "legendary",
        .log_level = "trace",
        .theme = "sepia",
    });

    try std.testing.expectEqual(config.Difficulty.medium, cfg.difficulty);
    try std.testing.expectEqual(logger.Severity.warn, cfg.log_level);
    try std.testing.expectEqual(config.ViewTheme.dark, cfg.theme);
}

test "requestBody returns null when header separator is missing" {
    try std.testing.expect(requestBody("GET / HTTP/1.1\r\nHost: localhost\r\n") == null);
}

test "requestBody returns payload bytes after header separator" {
    const req =
        "POST /settings.json HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\n\r\n{\"theme\":1}";
    const body = requestBody(req).?;
    try std.testing.expectEqualStrings("{\"theme\":1}", body);
}

test "contentLength parses header value case-insensitively" {
    const req =
        "POST /current-file HTTP/1.1\r\nHost: localhost\r\ncontent-length: 12\r\n\r\nhello world!";
    const len = contentLength(req).?;
    try std.testing.expectEqual(@as(usize, 12), len);
}

test "applySettingsPost returns System on invalid JSON" {
    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = ".",
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
        .host_config_body_buf = undefined,
    };
    try std.testing.expectError(ServeError.System, applySettingsPost(std.testing.io, &session, "{\"theme\":"));
}

test "applySettingsPost updates in-memory host config even when disk persistence is disabled" {
    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = ".",
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
        .host_config_body_buf = undefined,
    };
    const body = "{\"difficulty\":\"hard\",\"log_level\":\"debug\",\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":true,\"auto_restore\":true,\"auto_new\":true,\"auto_save\":true}";
    try applySettingsPost(std.testing.io, &session, body);
    try std.testing.expectEqual(config.Difficulty.hard, session.host_config.difficulty);
    try std.testing.expectEqual(logger.Severity.debug, session.host_config.log_level);
    try std.testing.expectEqual(config.ViewTheme.light, session.host_config.theme);
    try std.testing.expect(session.host_config.show_region);
    try std.testing.expect(session.host_config.warn_solvability);
    try std.testing.expect(session.host_config.auto_restore);
    try std.testing.expect(session.host_config.auto_new);
    try std.testing.expect(session.host_config.auto_save);
}

test "settings POST JSON patch is written to settings.json on disk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config.Config.default();
    const body = "{\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":false,\"auto_restore\":true,\"auto_new\":true,\"auto_save\":true}";
    const parsed = std.json.parseFromSlice(SettingsPostBody, std.testing.allocator, body, .{}) catch unreachable;
    defer parsed.deinit();
    mergeSettingsPostPatch(&cfg, parsed.value);
    try settings_store.saveInDir(std.testing.allocator, io, tmp.dir, cfg);

    const bytes = tmp.dir.readFileAlloc(io, settings_store.file_name, std.testing.allocator, std.Io.Limit.unlimited) catch unreachable;
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"show_region\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"warn_solvability\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"auto_restore\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"auto_new\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"auto_save\":true") != null);

    const loaded = try settings_store.loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
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
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
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

    const loaded_ptr = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
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

test "current-file POST supports explicit save name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
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
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
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
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", "chosen-name.sud", false);
    const first = try std.heap.page_allocator.dupe(u8, session.current_file.?);
    defer std.heap.page_allocator.free(first);

    try applyCurrentFilePost(io, &session, "SUD0 second", null, true);
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
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", "replace-me.sud", false);
    try applyCurrentFilePost(io, &session, "SUD0 second", "replace-me.sud", false);
}

test "current-file POST rejects unbound existing target without replace header" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", "bound.sud", false);
    const unbound_path = try file_path.resolveSavePath(std.testing.allocator, data_path, "other-existing.sud");
    defer std.testing.allocator.free(unbound_path);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = unbound_path,
        .data = "legacy",
        .flags = .{ .truncate = true },
    });
    try applyCurrentFileContextEvent(io, &session, "new_game_success");
    try std.testing.expectError(ServeError.Conflict, applyCurrentFilePost(io, &session, "SUD0 second", "other-existing.sud", false));
}

test "current-file POST allows overwrite with replace header" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", "replace-ok.sud", false);
    try applyCurrentFilePost(io, &session, "SUD0 second", "replace-ok.sud", true);
}

test "current-file context event can detach lane without clearing save target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 first", "bound.sud", false);
    try std.testing.expect(session.current_file != null);
    try std.testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);

    try applyCurrentFileContextEvent(io, &session, "new_game_success");
    try std.testing.expect(session.has_current_file);
    try std.testing.expect(session.current_file != null);
    try std.testing.expectEqual(file_policy.WriteContext.detached, session.write_context);

    const persisted = try settings_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (persisted) |p| std.testing.allocator.free(p);
    try std.testing.expect(persisted != null);
    try std.testing.expect(std.mem.endsWith(u8, persisted.?, "/bound.sud"));
}

test "restore then new makes first write to same existing target require replace confirm" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var session = Session{
        .host_config = config.Config.default(),
        .data_dir = data_path,
        .has_current_file = true,
        .current_file = try file_path.resolveSavePath(std.heap.page_allocator, data_path, "sudoku.sud"),
        .write_context = file_policy.nextWriteContext(.detached, .startup_restore),
        .host_config_body_buf = undefined,
    };
    defer if (session.current_file) |p| std.heap.page_allocator.free(p);

    try applyCurrentFilePost(io, &session, "SUD0 restored", "sudoku.sud", false);
    try std.testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);

    try applyCurrentFileContextEvent(io, &session, "new_game_success");
    try std.testing.expectEqual(file_policy.WriteContext.detached, session.write_context);

    try std.testing.expectError(ServeError.Conflict, applyCurrentFilePost(io, &session, "SUD0 first-mutation", "sudoku.sud", false));
}

test "web_host: host-config body reflects active host Config" {
    var session = Session{
        .host_config = .{
            .difficulty = .medium,
            .preferred_renderer = .web,
            .fallback_renderer = .ansi,
            .log_level = .debug,
            .theme = .light,
            .show_region = true,
        },
        .data_dir = ".",
        .has_current_file = false,
        .current_file = null,
        .write_context = .detached,
        .host_config_body_buf = undefined,
    };
    const body = try session.hostConfigBody();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"difficulty\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"log_level\":0") != null);
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

    r.markDelivered(.shell);
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

    r.markDelivered(.generating);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.gen_progress_rows);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.gen_progress_format);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.region);
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
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world",
        capture_sink[0..capture_len],
    );
}

test "web_host: on_ready runs once with the bound url" {
    ready_count = 0;
    recordReady(std.testing.io, "http://127.0.0.1:8137/");
    try std.testing.expectEqual(1, ready_count);
    try std.testing.expectEqualStrings("http://127.0.0.1:8137/", ready_last_url[0..22]);
}
