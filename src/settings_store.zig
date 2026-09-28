// Persist nominal `Config` under the platform data directory (native startup).
const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const path = @import("native/shell/path.zig");

const log = logger.Logger(.sudoku);

/// Basename written under the platform data directory.
pub const file_name = "settings.json";

const JsonSettings = struct {
    difficulty: []const u8,
    log_level: []const u8,
    theme: []const u8,
    show_region: bool,
    preferred_renderer: []const u8,
    fallback_renderer: ?[]const u8 = null,
    warn_solvability: ?bool = null,
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

fn parseRenderer(name: []const u8) Error!config.RendererKind {
    if (std.mem.eql(u8, name, "ansi")) return .ansi;
    if (std.mem.eql(u8, name, "ascii")) return .ascii;
    if (std.mem.eql(u8, name, "tui")) return .tui;
    if (std.mem.eql(u8, name, "web")) return .web;
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

/// Map parsed `settings.json` fields into a `Config` (strict enum strings).
pub fn configFromJson(parsed: JsonSettings) Error!config.Config {
    const fallback: ?config.RendererKind = if (parsed.fallback_renderer) |fb|
        try parseRenderer(fb)
    else
        null;
    return .{
        .difficulty = try parseDifficulty(parsed.difficulty),
        .preferred_renderer = try parseRenderer(parsed.preferred_renderer),
        .fallback_renderer = fallback,
        .log_level = try parseLogLevel(parsed.log_level),
        .theme = try parseTheme(parsed.theme),
        .show_region = parsed.show_region,
        .warn_solvability = parsed.warn_solvability orelse false,
    };
}

fn jsonFromConfig(cfg: config.Config) JsonSettings {
    const fallback_name: ?[]const u8 = if (cfg.fallback_renderer) |fb| @tagName(fb) else null;
    return .{
        .difficulty = @tagName(cfg.difficulty),
        .log_level = @tagName(cfg.log_level),
        .theme = @tagName(cfg.theme),
        .show_region = cfg.show_region,
        .preferred_renderer = @tagName(cfg.preferred_renderer),
        .fallback_renderer = fallback_name,
        .warn_solvability = cfg.warn_solvability,
    };
}

/// Owned absolute or data-dir-relative path to `settings.json`.
pub fn settingsPath(gpa: std.mem.Allocator, data_dir: []const u8) Error![]u8 {
    return path.resolveSavePath(gpa, data_dir, file_name) catch return Error.OutOfMemory;
}

fn loadBytes(gpa: std.mem.Allocator, bytes: []const u8) Error!config.Config {
    const parsed = std.json.parseFromSlice(JsonSettings, gpa, bytes, .{}) catch return config.Config.default();
    defer parsed.deinit();
    return configFromJson(parsed.value) catch return config.Config.default();
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

/// Write `cfg` as JSON to `dir/file_name` (truncate).
pub fn saveInDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cfg: config.Config) Error!void {
    const payload = jsonFromConfig(cfg);
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(payload, .{}, &aw.writer);
    try std.Io.Writer.writeAll(&aw.writer, "\n");
    try std.Io.Writer.flush(&aw.writer);
    const text = aw.toOwnedSlice() catch return Error.OutOfMemory;
    defer gpa.free(text);
    dir.writeFile(io, .{ .sub_path = file_name, .data = text, .flags = .{ .truncate = true } }) catch return Error.System;
}

/// Write `cfg` under `data_dir`, creating parent directories when needed.
pub fn save(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, cfg: config.Config) Error!void {
    const file_path = try settingsPath(gpa, data_dir);
    defer gpa.free(file_path);

    const parent = try path.parentDir(gpa, file_path);
    defer gpa.free(parent);
    ensureSettingsDir(io, parent);

    const payload = jsonFromConfig(cfg);
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(payload, .{}, &aw.writer);
    try std.Io.Writer.writeAll(&aw.writer, "\n");
    try std.Io.Writer.flush(&aw.writer);
    const text = aw.toOwnedSlice() catch return Error.OutOfMemory;
    defer gpa.free(text);

    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = file_path,
        .data = text,
        .flags = .{ .truncate = true },
    }) catch return Error.System;
}

test "settings round-trip preserves Config fields" {
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
    };

    try saveInDir(std.testing.allocator, io, tmp.dir, original);
    const restored = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(original.difficulty, restored.difficulty);
    try std.testing.expectEqual(original.preferred_renderer, restored.preferred_renderer);
    try std.testing.expectEqual(original.fallback_renderer, restored.fallback_renderer);
    try std.testing.expectEqual(original.log_level, restored.log_level);
    try std.testing.expectEqual(original.theme, restored.theme);
    try std.testing.expectEqual(original.show_region, restored.show_region);
    try std.testing.expectEqual(original.warn_solvability, restored.warn_solvability);
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
