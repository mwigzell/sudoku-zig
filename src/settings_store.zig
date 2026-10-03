// Persist nominal `Config` under the platform data directory (native startup).
const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const path = @import("native/shell/path.zig");

const log = logger.Logger(.sudoku);

/// Basename written under the platform data directory.
pub const file_name = "settings.json";

/// On-disk JSON schema — player prefs only (`Config` renderer fields are CLI / in-memory).
const JsonSettingsFile = struct {
    difficulty: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    show_region: ?bool = null,
    warn_solvability: ?bool = null,
    current_file: ?[]const u8 = null,
    session_b64: ?[]const u8 = null,
};

/// Player-editable fields only — matches menubar/menu + ADR-0014 (no renderer choice).
const JsonPlayerSettings = struct {
    difficulty: []const u8,
    log_level: []const u8,
    theme: []const u8,
    show_region: bool,
    warn_solvability: bool,
    current_file: ?[]const u8,
    session_b64: ?[]const u8,
};

pub const SessionMeta = struct {
    current_file: ?[]const u8 = null,
    session_b64: ?[]const u8 = null,
};

/// Errors from load/save/path resolution (invalid disk JSON maps to defaults on load).
pub const Error = error{
    OutOfMemory,
    InvalidJson,
    UnsupportedValue,
    WriteFailed,
    System,
};

/// Best-effort `createDirPath` for settings storage; logs and continues on failure.
pub fn ensureSettingsDir(io: std.Io, dir_path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
        log.warn("could not create settings directory '{s}': {s}", .{ dir_path, @errorName(err) });
    };
}

fn parseDifficulty(name: []const u8) Error!config.Difficulty {
    if (std.mem.eql(u8, name, "easy")) return .easy;
    if (std.mem.eql(u8, name, "medium")) return .medium;
    if (std.mem.eql(u8, name, "hard")) return .hard;
    if (std.mem.eql(u8, name, "default")) return .default;
    return Error.UnsupportedValue;
}

fn parseLogLevel(name: []const u8) Error!logger.Severity {
    if (std.mem.eql(u8, name, "debug")) return .debug;
    if (std.mem.eql(u8, name, "info")) return .info;
    if (std.mem.eql(u8, name, "warn")) return .warn;
    if (std.mem.eql(u8, name, "err")) return .err;
    if (std.mem.eql(u8, name, "fatal")) return .fatal;
    return Error.UnsupportedValue;
}

fn parseTheme(name: []const u8) Error!config.ViewTheme {
    if (std.mem.eql(u8, name, "dark")) return .dark;
    if (std.mem.eql(u8, name, "light")) return .light;
    return Error.UnsupportedValue;
}

fn configFromJsonFile(parsed: JsonSettingsFile) Error!config.Config {
    var cfg = config.Config.default();
    if (parsed.difficulty) |name| cfg.difficulty = try parseDifficulty(name);
    if (parsed.log_level) |name| cfg.log_level = try parseLogLevel(name);
    if (parsed.theme) |name| cfg.theme = try parseTheme(name);
    if (parsed.show_region) |on| cfg.show_region = on;
    if (parsed.warn_solvability) |on| cfg.warn_solvability = on;
    return cfg;
}

fn jsonPlayerFromConfig(cfg: config.Config) JsonPlayerSettings {
    return .{
        .difficulty = @tagName(cfg.difficulty),
        .log_level = @tagName(cfg.log_level),
        .theme = @tagName(cfg.theme),
        .show_region = cfg.show_region,
        .warn_solvability = cfg.warn_solvability,
        .current_file = null,
        .session_b64 = null,
    };
}

fn writeJsonFile(gpa: std.mem.Allocator, payload: JsonPlayerSettings) Error![]u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(payload, .{}, &aw.writer);
    try std.Io.Writer.writeAll(&aw.writer, "\n");
    try std.Io.Writer.flush(&aw.writer);
    return aw.toOwnedSlice() catch return Error.OutOfMemory;
}

const OwnedSessionFields = struct {
    current_file: ?[]u8 = null,
    session_b64: ?[]u8 = null,
};

fn readOwnedSessionFields(gpa: std.mem.Allocator, bytes: []const u8) OwnedSessionFields {
    const parsed = std.json.parseFromSlice(JsonSettingsFile, gpa, bytes, .{}) catch return .{};
    defer parsed.deinit();
    var out: OwnedSessionFields = .{};
    if (parsed.value.current_file) |value| out.current_file = gpa.dupe(u8, value) catch null;
    if (parsed.value.session_b64) |value| out.session_b64 = gpa.dupe(u8, value) catch null;
    return out;
}

fn freeOwnedSessionFields(gpa: std.mem.Allocator, fields: OwnedSessionFields) void {
    if (fields.current_file) |value| gpa.free(value);
    if (fields.session_b64) |value| gpa.free(value);
}

fn mergedJsonFromConfig(cfg: config.Config, existing: OwnedSessionFields) JsonPlayerSettings {
    var payload = jsonPlayerFromConfig(cfg);
    payload.current_file = existing.current_file;
    payload.session_b64 = existing.session_b64;
    return payload;
}

/// Owned absolute or data-dir-relative path to `settings.json`.
pub fn settingsPath(gpa: std.mem.Allocator, data_dir: []const u8) Error![]u8 {
    return path.resolveSavePath(gpa, data_dir, file_name) catch return Error.OutOfMemory;
}

fn loadBytes(gpa: std.mem.Allocator, bytes: []const u8) Error!config.Config {
    const parsed = std.json.parseFromSlice(JsonSettingsFile, gpa, bytes, .{}) catch return config.Config.default();
    defer parsed.deinit();
    return configFromJsonFile(parsed.value) catch return config.Config.default();
}

fn loadSessionMetaBytes(gpa: std.mem.Allocator, bytes: []const u8) Error!SessionMeta {
    const parsed_doc = std.json.parseFromSlice(JsonSettingsFile, gpa, bytes, .{}) catch return .{};
    defer parsed_doc.deinit();
    const parsed = parsed_doc.value;
    var out: SessionMeta = .{};
    if (parsed.current_file) |value| out.current_file = gpa.dupe(u8, value) catch return Error.OutOfMemory;
    if (parsed.session_b64) |value| out.session_b64 = gpa.dupe(u8, value) catch return Error.OutOfMemory;
    return out;
}

/// Read `file_name` from `dir`; missing or invalid file → `Config.default()`.
pub fn loadOrDefaultInDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) Error!config.Config {
    const bytes = dir.readFileAlloc(io, file_name, gpa, std.Io.Limit.unlimited) catch |err| switch (err) {
        error.FileNotFound => return config.Config.default(),
        else => return config.Config.default(),
    };
    defer gpa.free(bytes);
    return loadBytes(gpa, bytes);
}

/// Read settings from `data_dir` on disk; missing or invalid → `Config.default()`.
pub fn loadOrDefault(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) Error!config.Config {
    const file_path = try settingsPath(gpa, data_dir);
    defer gpa.free(file_path);

    const bytes = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, gpa, std.Io.Limit.unlimited) catch |err| switch (err) {
        error.FileNotFound => return config.Config.default(),
        else => return config.Config.default(),
    };
    defer gpa.free(bytes);
    return loadBytes(gpa, bytes);
}

/// Persist player-editable prefs only (no renderer keys). Used by startup, menu, and web POST.
pub fn saveInDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cfg: config.Config) Error!void {
    const existing = blk: {
        const bytes = dir.readFileAlloc(io, file_name, gpa, std.Io.Limit.unlimited) catch break :blk OwnedSessionFields{};
        defer gpa.free(bytes);
        break :blk readOwnedSessionFields(gpa, bytes);
    };
    defer freeOwnedSessionFields(gpa, existing);
    const text = try writeJsonFile(gpa, mergedJsonFromConfig(cfg, existing));
    defer gpa.free(text);
    dir.writeFile(io, .{ .sub_path = file_name, .data = text, .flags = .{ .truncate = true } }) catch return Error.System;
}

/// Persist player-editable prefs under `data_dir` (no renderer keys).
pub fn save(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, cfg: config.Config) Error!void {
    const file_path = try settingsPath(gpa, data_dir);
    defer gpa.free(file_path);

    const parent = try path.parentDir(gpa, file_path);
    defer gpa.free(parent);
    ensureSettingsDir(io, parent);

    const existing = blk: {
        const bytes = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, gpa, std.Io.Limit.unlimited) catch break :blk OwnedSessionFields{};
        defer gpa.free(bytes);
        break :blk readOwnedSessionFields(gpa, bytes);
    };
    defer freeOwnedSessionFields(gpa, existing);
    const text = try writeJsonFile(gpa, mergedJsonFromConfig(cfg, existing));
    defer gpa.free(text);

    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = file_path,
        .data = text,
        .flags = .{ .truncate = true },
    }) catch return Error.System;
}

pub fn freeSessionMeta(gpa: std.mem.Allocator, meta: SessionMeta) void {
    if (meta.current_file) |value| gpa.free(@constCast(value));
    if (meta.session_b64) |value| gpa.free(@constCast(value));
}

pub fn loadSessionMetaOrNull(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) Error!?SessionMeta {
    const file_path = try settingsPath(gpa, data_dir);
    defer gpa.free(file_path);

    const bytes = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, gpa, std.Io.Limit.unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer gpa.free(bytes);
    return try loadSessionMetaBytes(gpa, bytes);
}

pub fn saveSessionMeta(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, meta: SessionMeta) Error!void {
    const file_path = try settingsPath(gpa, data_dir);
    defer gpa.free(file_path);

    const parent = try path.parentDir(gpa, file_path);
    defer gpa.free(parent);
    ensureSettingsDir(io, parent);

    const cfg = try loadOrDefault(gpa, io, data_dir);
    var payload = jsonPlayerFromConfig(cfg);
    payload.current_file = meta.current_file;
    payload.session_b64 = meta.session_b64;
    const text = try writeJsonFile(gpa, payload);
    defer gpa.free(text);

    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = file_path,
        .data = text,
        .flags = .{ .truncate = true },
    }) catch return Error.System;
}

test "save omits renderer keys; load uses code default for renderer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config.Config.default();
    cfg.preferred_renderer = .web;
    cfg.fallback_renderer = .ascii;
    cfg.theme = .light;
    try saveInDir(std.testing.allocator, io, tmp.dir, cfg);

    const bytes = tmp.dir.readFileAlloc(io, file_name, std.testing.allocator, std.Io.Limit.unlimited) catch unreachable;
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "preferred_renderer") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme\":\"light\"") != null);

    const restored = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(config.RendererKind.ansi, restored.preferred_renderer);
    try std.testing.expectEqual(config.ViewTheme.light, restored.theme);
}

test "load ignores stale renderer keys on disk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const legacy =
        \\{"difficulty":"easy","log_level":"info","theme":"dark","show_region":false,"preferred_renderer":"web","fallback_renderer":"ansi","warn_solvability":false}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = legacy, .flags = .{ .truncate = true } });

    const loaded = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(config.Difficulty.easy, loaded.difficulty);
    try std.testing.expectEqual(config.RendererKind.ansi, loaded.preferred_renderer);
    try std.testing.expectEqual(config.RendererKind.ansi, loaded.fallback_renderer.?);
}

test "settings round-trip preserves player fields" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = config.Config{
        .difficulty = .hard,
        .preferred_renderer = .web,
        .fallback_renderer = .ansi,
        .log_level = .warn,
        .theme = .light,
        .show_region = true,
        .warn_solvability = true,
    };

    try saveInDir(std.testing.allocator, io, tmp.dir, original);
    const restored = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(original.difficulty, restored.difficulty);
    try std.testing.expectEqual(original.log_level, restored.log_level);
    try std.testing.expectEqual(original.theme, restored.theme);
    try std.testing.expectEqual(original.show_region, restored.show_region);
    try std.testing.expectEqual(original.warn_solvability, restored.warn_solvability);
    try std.testing.expectEqual(config.RendererKind.ansi, restored.preferred_renderer);
}

test "settings round-trip preserves warn_solvability" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original = config.Config.default();
    original.warn_solvability = true;
    try saveInDir(std.testing.allocator, io, tmp.dir, original);
    const restored = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expect(restored.warn_solvability);
}

test "missing settings file yields Config.default()" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try loadOrDefaultInDir(std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqual(config.Config.default().difficulty, cfg.difficulty);
}

test "loadOrDefaultInDir reads view prefs from settings.json on disk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var on_disk = config.Config.default();
    on_disk.theme = .light;
    on_disk.show_region = true;
    on_disk.warn_solvability = true;
    try saveInDir(std.testing.allocator, io, tmp.dir, on_disk);

    const loaded = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(config.ViewTheme.light, loaded.theme);
    try std.testing.expect(loaded.show_region);
    try std.testing.expect(loaded.warn_solvability);

    const bytes = tmp.dir.readFileAlloc(io, file_name, std.testing.allocator, std.Io.Limit.unlimited) catch unreachable;
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"show_region\":true") != null);
}

test "save preserves existing session metadata fields" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config.Config.default();
    try saveInDir(std.testing.allocator, io, tmp.dir, cfg);
    try tmp.dir.writeFile(io, .{
        .sub_path = file_name,
        .data = "{\"difficulty\":\"easy\",\"log_level\":\"info\",\"theme\":\"dark\",\"show_region\":false,\"warn_solvability\":false,\"current_file\":\"opened.sud\",\"session_b64\":\"AQID\"}\n",
        .flags = .{ .truncate = true },
    });

    cfg.theme = .light;
    try saveInDir(std.testing.allocator, io, tmp.dir, cfg);
    const bytes = tmp.dir.readFileAlloc(io, file_name, std.testing.allocator, std.Io.Limit.unlimited) catch unreachable;
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"current_file\":\"opened.sud\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"session_b64\":\"AQID\"") != null);
}

test "saveSessionMeta preserves player settings fields" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/sudoku-settings-{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    var cfg = config.Config.default();
    cfg.theme = .light;
    cfg.show_region = true;
    try save(std.testing.allocator, io, data_path, cfg);

    try saveSessionMeta(std.testing.allocator, io, data_path, .{
        .current_file = "saved.sud",
        .session_b64 = "AQI=",
    });
    const loaded_cfg = try loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expectEqual(config.ViewTheme.light, loaded_cfg.theme);
    try std.testing.expect(loaded_cfg.show_region);
    const meta = try loadSessionMetaOrNull(std.testing.allocator, io, data_path);
    try std.testing.expect(meta != null);
    defer if (meta) |value| freeSessionMeta(std.testing.allocator, value);
    try std.testing.expectEqualStrings("saved.sud", meta.?.current_file.?);
}
