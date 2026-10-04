/// Loopback static host for the web app shell (desktop `-r web` and future Android WebView).
const std = @import("std");
const net = std.Io.net;
const logger = @import("../logger.zig");
const log = logger.Logger(.web_host);
const config = @import("../config.zig");
const startup_config = @import("../startup_config.zig");
const settings_store = @import("../settings_store.zig");
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
    /// Host-computed startup metadata: web restore depends on capability+path.
    has_current_file: bool,
    host_config_body_buf: [256]u8,

    fn hostConfigBody(self: *Session) ServeError![]const u8 {
        return startup_config.formatHostStartupJsonWithPolicy(self.host_config, self.has_current_file, false, &self.host_config_body_buf) catch return ServeError.System;
    }
};

const SettingsPostBody = struct {
    difficulty: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    show_region: ?bool = null,
    warn_solvability: ?bool = null,
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
}

fn requestBody(request: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return null;
    return request[sep + 4 ..];
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
    defer if (current_file) |p| std.heap.page_allocator.free(p);
    var session = Session{
        .host_config = host_cfg,
        .data_dir = data_dir,
        .has_current_file = current_file != null,
        .host_config_body_buf = undefined,
    };
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
    outer: while (used < in_buf.len) {
        var data: [1][]u8 = .{in_buf[used..]};
        const n = client.read(io, &data) catch return ServeError.System;
        if (n == 0) break;
        used += n;
        if (std.mem.indexOfPos(u8, in_buf[0..used], 0, "\r\n\r\n") != null) break :outer;
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

test "web_host: route \"/\" to the page" {
    try std.testing.expectEqual(RouteResult.page, try Router.route("/"));
}

test "web_host: route \"/glue.js\" to the glue" {
    try std.testing.expectEqual(RouteResult.glue, try Router.route("/glue.js"));
}

test "web_host: route \"/gen_client.js\" to the gen client module" {
    try std.testing.expectEqual(RouteResult.gen_client, try Router.route("/gen_client.js"));
}

test "web_host: route \"/gen_worker.js\" to the gen worker module" {
    try std.testing.expectEqual(RouteResult.gen_worker, try Router.route("/gen_worker.js"));
}

test "web_host: route \"/shell.js\" to the shell" {
    try std.testing.expectEqual(RouteResult.shell, try Router.route("/shell.js"));
}

test "web_host: route \"/board.js\" to the board module" {
    try std.testing.expectEqual(RouteResult.board, try Router.route("/board.js"));
}

test "web_host: route \"/menu.js\" to the menu module" {
    try std.testing.expectEqual(RouteResult.menu, try Router.route("/menu.js"));
}

test "web_host: route \"/menu_bar.js\" to the menu bar module" {
    try std.testing.expectEqual(RouteResult.menu_bar, try Router.route("/menu_bar.js"));
}

test "web_host: route \"/theme.js\" to the theme module" {
    try std.testing.expectEqual(RouteResult.theme, try Router.route("/theme.js"));
}

test "web_host: route \"/file_menu.js\" to the file menu module" {
    try std.testing.expectEqual(RouteResult.file_menu, try Router.route("/file_menu.js"));
}

test "web_host: route \"/generating.js\" to the generating modal module" {
    try std.testing.expectEqual(RouteResult.generating, try Router.route("/generating.js"));
}

test "web_host: route \"/gen_progress_rows.js\" to the progress row module" {
    try std.testing.expectEqual(RouteResult.gen_progress_rows, try Router.route("/gen_progress_rows.js"));
}

test "web_host: route \"/gen_progress_format.js\" to the progress format module" {
    try std.testing.expectEqual(RouteResult.gen_progress_format, try Router.route("/gen_progress_format.js"));
}

test "web_host: route \"/region.js\" to the region module" {
    try std.testing.expectEqual(RouteResult.region, try Router.route("/region.js"));
}

test "web_host: route \"/help.js\" to the help module" {
    try std.testing.expectEqual(RouteResult.help, try Router.route("/help.js"));
}

test "web_host: route \"/settings.js\" to the settings module" {
    try std.testing.expectEqual(RouteResult.settings, try Router.route("/settings.js"));
}

test "mergeSettingsPostPatch updates view prefs on Config" {
    var cfg = config.Config.default();
    mergeSettingsPostPatch(&cfg, .{
        .difficulty = "hard",
        .log_level = "debug",
        .theme = "light",
        .show_region = true,
        .warn_solvability = true,
    });
    try std.testing.expectEqual(config.Difficulty.hard, cfg.difficulty);
    try std.testing.expectEqual(logger.Severity.debug, cfg.log_level);
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);
    try std.testing.expect(cfg.show_region);
    try std.testing.expect(cfg.warn_solvability);
}

test "settings POST JSON patch is written to settings.json on disk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config.Config.default();
    const body = "{\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":false}";
    const parsed = std.json.parseFromSlice(SettingsPostBody, std.testing.allocator, body, .{}) catch unreachable;
    defer parsed.deinit();
    mergeSettingsPostPatch(&cfg, parsed.value);
    try settings_store.saveInDir(std.testing.allocator, io, tmp.dir, cfg);

    const bytes = tmp.dir.readFileAlloc(io, settings_store.file_name, std.testing.allocator, std.Io.Limit.unlimited) catch unreachable;
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"show_region\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"warn_solvability\":false") != null);

    const loaded = try settings_store.loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(config.ViewTheme.light, loaded.theme);
    try std.testing.expect(loaded.show_region);
    try std.testing.expect(!loaded.warn_solvability);
}

test "web_host: route \"/host-config.json\" to host startup config" {
    try std.testing.expectEqual(RouteResult.host_config, try Router.route("/host-config.json"));
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
        .host_config_body_buf = undefined,
    };
    const body = try session.hostConfigBody();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"difficulty\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"log_level\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"theme\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "true") != null);
}

test "web_host: route \"/artifact.wasm\" to the artifact" {
    try std.testing.expectEqual(RouteResult.artifact, try Router.route("/artifact.wasm"));
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
