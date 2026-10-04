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
    auto_restore: ?bool = null,
    auto_new: ?bool = null,
    auto_save: ?bool = null,
    current_file: ?[]const u8 = null,
};

/// Player-editable fields only — matches menubar/menu + ADR-0014 (no renderer choice).
const JsonPlayerSettings = struct {
    difficulty: []const u8,
    log_level: []const u8,
    theme: []const u8,
    show_region: bool,
    warn_solvability: bool,
    auto_restore: bool,
    auto_new: bool,
    auto_save: bool,
    current_file: ?[]const u8 = null,
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
    if (parsed.auto_restore) |on| cfg.auto_restore = on;
    if (parsed.auto_new) |on| cfg.auto_new = on;
    if (parsed.auto_save) |on| cfg.auto_save = on;
    return cfg;
}

fn jsonPlayerFromConfig(cfg: config.Config) JsonPlayerSettings {
    return .{
        .difficulty = @tagName(cfg.difficulty),
        .log_level = @tagName(cfg.log_level),
        .theme = @tagName(cfg.theme),
        .show_region = cfg.show_region,
        .warn_solvability = cfg.warn_solvability,
        .auto_restore = cfg.auto_restore,
        .auto_new = cfg.auto_new,
        .auto_save = cfg.auto_save,
    };
}

fn writePlayerJson(gpa: std.mem.Allocator, cfg: config.Config, current_file: ?[]const u8) Error![]u8 {
    var payload = jsonPlayerFromConfig(cfg);
    payload.current_file = current_file;
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(payload, .{}, &aw.writer);
    try std.Io.Writer.writeAll(&aw.writer, "\n");
    try std.Io.Writer.flush(&aw.writer);
    return aw.toOwnedSlice() catch return Error.OutOfMemory;
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

fn loadCurrentFileBytes(gpa: std.mem.Allocator, bytes: []const u8) Error!?[]u8 {
    const parsed = std.json.parseFromSlice(JsonSettingsFile, gpa, bytes, .{}) catch return null;
    defer parsed.deinit();
    const file_path = parsed.value.current_file orelse return null;
    return gpa.dupe(u8, file_path) catch return Error.OutOfMemory;
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

/// Loads the optional current-file pointer metadata used by startup restore
/// policy; returns null when unset/missing/unreadable.
pub fn loadCurrentFile(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) Error!?[]u8 {
    const file_path = try settingsPath(gpa, data_dir);
    defer gpa.free(file_path);

    const bytes = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, gpa, std.Io.Limit.unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer gpa.free(bytes);
    return loadCurrentFileBytes(gpa, bytes);
}

/// Updates only the startup restore pointer metadata while preserving current
/// player settings fields in `settings.json`.
pub fn setCurrentFile(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, current_file: ?[]const u8) Error!void {
    const cfg = try loadOrDefault(gpa, io, data_dir);

    const file_path = try settingsPath(gpa, data_dir);
    defer gpa.free(file_path);

    const parent = try path.parentDir(gpa, file_path);
    defer gpa.free(parent);
    ensureSettingsDir(io, parent);

    const text = try writePlayerJson(gpa, cfg, current_file);
    defer gpa.free(text);

    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = file_path,
        .data = text,
        .flags = .{ .truncate = true },
    }) catch return Error.System;
}

/// Persist player-editable prefs only (no renderer keys). Used by startup, menu, and web POST.
pub fn saveInDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cfg: config.Config) Error!void {
    const bytes = dir.readFileAlloc(io, file_name, gpa, std.Io.Limit.unlimited) catch null;
    defer if (bytes) |b| gpa.free(b);
    const current_file = if (bytes) |b| try loadCurrentFileBytes(gpa, b) else null;
    defer if (current_file) |p| gpa.free(p);

    const text = try writePlayerJson(gpa, cfg, current_file);
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

    const existing = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, gpa, std.Io.Limit.unlimited) catch null;
    defer if (existing) |b| gpa.free(b);
    const current_file = if (existing) |b| try loadCurrentFileBytes(gpa, b) else null;
    defer if (current_file) |p| gpa.free(p);

    const text = try writePlayerJson(gpa, cfg, current_file);
    defer gpa.free(text);

    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = file_path,
        .data = text,
        .flags = .{ .truncate = true },
    }) catch return Error.System;
}

test "save omits renderer keys; load uses code default for renderer" {
    const test_defaults = @import("test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = test_defaults.testConfigDefaults();
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
        .auto_restore = true,
        .auto_new = true,
        .auto_save = true,
    };

    try saveInDir(std.testing.allocator, io, tmp.dir, original);
    const restored = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(original.difficulty, restored.difficulty);
    try std.testing.expectEqual(original.log_level, restored.log_level);
    try std.testing.expectEqual(original.theme, restored.theme);
    try std.testing.expectEqual(original.show_region, restored.show_region);
    try std.testing.expectEqual(original.warn_solvability, restored.warn_solvability);
    try std.testing.expectEqual(original.auto_restore, restored.auto_restore);
    try std.testing.expectEqual(original.auto_new, restored.auto_new);
    try std.testing.expectEqual(original.auto_save, restored.auto_save);
    try std.testing.expectEqual(config.RendererKind.ansi, restored.preferred_renderer);
}

test "settings round-trip preserves warn_solvability" {
    const test_defaults = @import("test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original = test_defaults.testConfigDefaults();
    original.warn_solvability = true;
    try saveInDir(std.testing.allocator, io, tmp.dir, original);
    const restored = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expect(restored.warn_solvability);
}

test "missing settings file yields Config.default()" {
    const test_defaults = @import("test/config_defaults.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try loadOrDefaultInDir(std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqual(test_defaults.testConfigDefaults().difficulty, cfg.difficulty);
}

test "loadOrDefaultInDir reads view prefs from settings.json on disk" {
    const test_defaults = @import("test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var on_disk = test_defaults.testConfigDefaults();
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

test "load missing behavior flags defaults them to false" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const legacy =
        \\{"difficulty":"easy","log_level":"info","theme":"dark","show_region":false,"warn_solvability":false}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = legacy, .flags = .{ .truncate = true } });

    const loaded = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try std.testing.expect(!loaded.auto_restore);
    try std.testing.expect(!loaded.auto_new);
    try std.testing.expect(!loaded.auto_save);
}

test "setCurrentFile persists pointer and loadCurrentFile returns it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    try setCurrentFile(std.testing.allocator, io, data_path, "/tmp/sudoku_restore_step2.sud");
    const current = try loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings("/tmp/sudoku_restore_step2.sud", current.?);
}

test "save preserves existing current_file pointer" {
    const test_defaults = @import("test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    try setCurrentFile(std.testing.allocator, io, data_path, "/tmp/sudoku_restore_preserve.sud");

    var cfg = test_defaults.testConfigDefaults();
    cfg.theme = .light;
    try save(std.testing.allocator, io, data_path, cfg);

    const current = try loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings("/tmp/sudoku_restore_preserve.sud", current.?);
}
