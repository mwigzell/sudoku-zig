// Persist `Config` and the current-file pointer in `config.json` under the platform data directory.
const std = @import("std");
const config = @import("config.zig");
const config_table = @import("config_table.zig");
const logger = @import("logger.zig");
const path = @import("path.zig");

const log = logger.Logger(.sudoku);

/// Basename written under the platform data directory.
pub const file_name = "config.json";

/// Keys of the file's top-level object: `{"config": {…}, "current_file": …}`.
const CONFIG_KEY = "config";
const CURRENT_FILE_KEY = "current_file";

/// Errors from load/save/path resolution. A file the store will not use answers `System` and a write
/// the system refused answers `WriteFailed`, each with its own log line naming the reason, so a
/// caller never reports one as the other.
pub const Error = error{
    OutOfMemory,
    InvalidJson,
    UnsupportedValue,
    WriteFailed,
    System,
};

const CONFIG_PART = "config";
const CURRENT_FILE_PART = "current file";

/// A config file that is not there yet is normal; any other read failure is logged as a problem.
/// `what` names the part being read, so two reads of one file log two distinct lines.
fn noteReadFailure(what: []const u8, file: []const u8, err: anyerror) void {
    if (err == error.FileNotFound) {
        log.info("expected: no config file at {s} yet, {s} not read ({s})", .{ file, what, @errorName(err) });
    } else {
        log.warn("config file {s} unreadable, {s} not read: {s}", .{ file, what, @errorName(err) });
    }
}

/// What a file no read can use means to the call that asked: a Config read refuses it, a save
/// replaces it, and a pointer-only read leaves it alone.
const Unusable = enum { refuse, repair, ignore };

/// A file that cannot be used: `line` names the defect, `unusable` says what happens next, and
/// the caller gets `error.System` carrying this line as its reason.
fn noteUnusable(comptime line: []const u8, err: anyerror, unusable: Unusable) error{System} {
    switch (unusable) {
        .refuse => log.warn(line ++ ": {s}", .{@errorName(err)}),
        .repair => log.warn(line ++ ", repairing: {s}", .{@errorName(err)}),
        .ignore => log.warn(line ++ ", current file not read: {s}", .{@errorName(err)}),
    }
    return error.System;
}

/// Config write failure: the system reason is logged here, the caller gets `Error.WriteFailed` so a
/// settings file that cannot be written is never reported as a file that cannot be read.
fn writeFailed(file: []const u8, err: anyerror) Error {
    log.err("config write {s} failed: {s}", .{ file, @errorName(err) });
    return Error.WriteFailed;
}

/// Best-effort `createDirPath` for config storage; logs and continues on failure.
pub fn ensureConfigDir(io: std.Io, dir_path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
        log.err("could not create config directory '{s}': {s}", .{ dir_path, @errorName(err) });
    };
}

/// Write every saved Config field as one JSON object member each (bools as bools, choices by name).
fn writeConfigObject(s: *std.json.Stringify, cfg: config.Config) std.Io.Writer.Error!void {
    try s.beginObject();
    inline for (@typeInfo(config.Config).@"struct".field_names) |name| {
        if (comptime config.Config.isSaved(name)) {
            try s.objectField(name);
            try s.write(@field(cfg, name));
        }
    }
    try s.endObject();
}

/// Set each saved Config field present in `object`; absent and unknown members are left alone.
/// Each table row present in `object` goes through the table's check, so the file takes only values Settings offers.
/// A field this app does not know (written by a newer app) is ignored; a missing one keeps its value.
fn applyObject(cfg: *config.Config, object: std.json.ObjectMap) Error!void {
    for (config_table.rows) |r| {
        const json = object.get(r.field) orelse continue;
        const value = config_table.valueFromJson(json) orelse return Error.UnsupportedValue;
        config_table.apply(cfg, .{ .field = r.field, .value = value }) catch return Error.UnsupportedValue;
    }
}

/// The Config as one JSON object (the web host's `POST /config.json` body and the file's `config` member).
pub fn writeConfigJson(w: *std.Io.Writer, cfg: config.Config) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try writeConfigObject(&s, cfg);
}

/// Apply a JSON object of Config fields onto `cfg` (a partial patch: absent fields keep their value).
/// A body that does not parse, or a bad value, is logged and leaves `cfg` unchanged.
pub fn applyConfigJson(gpa: std.mem.Allocator, cfg: *config.Config, bytes: []const u8) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| {
        log.warn("config body does not parse: {s}", .{@errorName(err)});
        return Error.InvalidJson;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        log.warn("config body is not an object: {s}", .{@tagName(parsed.value)});
        return Error.InvalidJson;
    }
    var patched = cfg.*;
    applyObject(&patched, parsed.value.object) catch |err| {
        log.warn("config body has a bad value: {s}", .{@errorName(err)});
        return err;
    };
    cfg.* = patched;
}

/// The whole file: `{"config": {…}, "current_file": …}`, newline-terminated.
fn writeFileJson(gpa: std.mem.Allocator, cfg: config.Config, current_file: ?[]const u8) Error![]u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField(CONFIG_KEY);
    try writeConfigObject(&s, cfg);
    try s.objectField(CURRENT_FILE_KEY);
    try s.write(current_file);
    try s.endObject();
    try aw.writer.writeAll("\n");
    return aw.toOwnedSlice() catch return Error.OutOfMemory;
}

/// Owned absolute or data-dir-relative path to `config.json`; a path this cannot build is refused.
fn configPath(gpa: std.mem.Allocator, data_dir: []const u8) Error![]u8 {
    return path.resolveSavePath(gpa, data_dir, file_name) catch |err| {
        log.err("config file path in {s} could not be resolved: {s}", .{ data_dir, @errorName(err) });
        return Error.System;
    };
}

/// The file's top-level object; bytes that do not parse into one are logged and become
/// `error.System`. `unusable` decides how that one line reads in this caller's lane.
/// Returns: `error.System` only — the reason is on the log line `noteUnusable` wrote.
fn parseFile(gpa: std.mem.Allocator, bytes: []const u8, unusable: Unusable) error{System}!std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| {
        return noteUnusable("config file does not parse", err, unusable);
    };
    if (parsed.value != .object) {
        parsed.deinit();
        return noteUnusable("config file is not a JSON object", Error.InvalidJson, unusable);
    }
    return parsed;
}

/// The Config the file's bytes hold; bytes that cannot be used are refused instead of becoming
/// the defaults, so a bad file never looks like a first start.
fn loadBytes(gpa: std.mem.Allocator, bytes: []const u8) Error!config.Config {
    const parsed = try parseFile(gpa, bytes, .refuse);
    defer parsed.deinit();
    var cfg = config.Config.default();
    const stored = parsed.value.object.get(CONFIG_KEY) orelse return cfg;
    if (stored != .object) return noteUnusable("config member is not a JSON object", Error.InvalidJson, .refuse);
    applyObject(&cfg, stored.object) catch |err| {
        return noteUnusable("config holds a value the config table rejects", err, .refuse);
    };
    return cfg;
}

/// The file's `current_file` pointer, or null when the file or the member is unusable.
/// Lenient by design: the caller holds the Config already and repairs such a file on its next write,
/// so a file this cannot parse is null here rather than a refusal. `unusable` words the one line
/// for this lane: a save repairs the file, a pointer-only read leaves it.
fn loadCurrentFileBytes(gpa: std.mem.Allocator, bytes: []const u8, unusable: Unusable) Error!?[]u8 {
    // `System` is the only way `parseFile` fails, and here it means "no pointer", not "refuse".
    const parsed = parseFile(gpa, bytes, unusable) catch |err| switch (err) {
        error.System => return null,
    };
    defer parsed.deinit();
    const stored = parsed.value.object.get(CURRENT_FILE_KEY) orelse return null;
    if (stored != .string) return null;
    return gpa.dupe(u8, stored.string) catch return Error.OutOfMemory;
}

/// Read the config file's bytes for a caller that must have a Config.
/// `null` when there is no file yet — a first start is normal; every other failure is logged and
/// refused, because a file that exists and cannot be read is not a first start.
fn readConfigBytes(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    file_label: []const u8,
) Error!?[]u8 {
    return dir.readFileAlloc(io, sub_path, gpa, std.Io.Limit.unlimited) catch |err| {
        noteReadFailure(CONFIG_PART, file_label, err);
        if (err == error.FileNotFound) return null;
        return Error.System;
    };
}

/// Read `file_name` from `dir`: a missing file plays on `Config.default()`; one that exists and
/// cannot be read is refused after its one log line.
pub fn loadOrDefaultInDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) Error!config.Config {
    const bytes = (try readConfigBytes(gpa, io, dir, file_name, file_name)) orelse return config.Config.default();
    defer gpa.free(bytes);
    return loadBytes(gpa, bytes);
}

/// Read the Config from `data_dir` on disk: a missing file plays on `Config.default()`; one that
/// exists and cannot be read is refused after its one log line.
pub fn loadOrDefault(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) Error!config.Config {
    const file_path = try configPath(gpa, data_dir);
    defer gpa.free(file_path);

    const bytes = (try readConfigBytes(gpa, io, std.Io.Dir.cwd(), file_path, file_path)) orelse return config.Config.default();
    defer gpa.free(bytes);
    return loadBytes(gpa, bytes);
}

/// Loads the optional current-file pointer used by startup restore; null when unset/missing/unreadable.
pub fn loadCurrentFile(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8) Error!?[]u8 {
    const file_path = try configPath(gpa, data_dir);
    defer gpa.free(file_path);

    const bytes = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, gpa, std.Io.Limit.unlimited) catch |err| {
        noteReadFailure(CURRENT_FILE_PART, file_path, err);
        return null;
    };
    defer gpa.free(bytes);
    return loadCurrentFileBytes(gpa, bytes, .ignore);
}

/// Updates only the current-file pointer, keeping the stored Config; a stored Config the read refuses
/// is refused too, not replaced by defaults.
pub fn setCurrentFile(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, current_file: ?[]const u8) Error!void {
    const cfg = try loadOrDefault(gpa, io, data_dir);

    const file_path = try configPath(gpa, data_dir);
    defer gpa.free(file_path);

    const parent = try path.parentDir(gpa, file_path);
    defer gpa.free(parent);
    ensureConfigDir(io, parent);

    const text = try writeFileJson(gpa, cfg, current_file);
    defer gpa.free(text);

    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = file_path,
        .data = text,
        .flags = .{ .truncate = true },
    }) catch |err| return writeFailed(file_path, err);
}

/// Persist the Config into `dir`, keeping the stored current-file pointer.
/// The pointer's read is lenient: the Config is already in hand, so a file this cannot read is
/// repaired by the write below instead of refusing the save.
pub fn saveInDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cfg: config.Config) Error!void {
    const bytes = dir.readFileAlloc(io, file_name, gpa, std.Io.Limit.unlimited) catch |err| blk: {
        noteReadFailure(CURRENT_FILE_PART, file_name, err);
        break :blk null;
    };
    defer if (bytes) |b| gpa.free(b);
    const current_file = if (bytes) |b| try loadCurrentFileBytes(gpa, b, .repair) else null;
    defer if (current_file) |p| gpa.free(p);

    const text = try writeFileJson(gpa, cfg, current_file);
    defer gpa.free(text);
    dir.writeFile(io, .{ .sub_path = file_name, .data = text, .flags = .{ .truncate = true } }) catch |err| return writeFailed(file_name, err);
}

/// Persist the Config under `data_dir`, keeping the stored current-file pointer.
/// Lenient like `saveInDir`: an unreadable file is repaired by this write, not refused.
pub fn save(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, cfg: config.Config) Error!void {
    const file_path = try configPath(gpa, data_dir);
    defer gpa.free(file_path);

    const parent = try path.parentDir(gpa, file_path);
    defer gpa.free(parent);
    ensureConfigDir(io, parent);

    const existing = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, gpa, std.Io.Limit.unlimited) catch |err| blk: {
        noteReadFailure(CURRENT_FILE_PART, file_path, err);
        break :blk null;
    };
    defer if (existing) |b| gpa.free(b);
    const current_file = if (existing) |b| try loadCurrentFileBytes(gpa, b, .repair) else null;
    defer if (current_file) |p| gpa.free(p);

    const text = try writeFileJson(gpa, cfg, current_file);
    defer gpa.free(text);

    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = file_path,
        .data = text,
        .flags = .{ .truncate = true },
    }) catch |err| return writeFailed(file_path, err);
}

/// A Config with every saved field off its default, so a round trip proves each one.
fn nonDefaultConfig() config.Config {
    return .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .web, .fallback = null },
        .log_level = .warn,
        .theme = .light,
        .show_region = true,
        .warn_solvability = true,
        .auto_restore = true,
        .auto_new = true,
        .auto_save = true,
        .auto_pencil = true,
        .show_marks = false,
        .test_probe = true,
    };
}

/// Every saved field of `a` equals that field of `b`.
fn expectSavedFieldsEqual(a: config.Config, b: config.Config) !void {
    inline for (@typeInfo(config.Config).@"struct".field_names) |name| {
        if (comptime config.Config.isSaved(name)) {
            try std.testing.expectEqual(@field(a, name), @field(b, name));
        }
    }
}

/// A `config.json` no read can succeed on: a directory stands where the file would be, so the read
/// fails with the platform's own error for root and an ordinary user alike. Taking read permission
/// away proves nothing when the suite runs as root, which reads such a file anyway.
fn makeConfigUnreadable(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDir(io, file_name, .default_dir);
}

/// The error name a read of `sub_path` in `dir` produces, so a test names the reason without
/// hard-coding a platform's error. A readable file means the test set itself up wrong.
fn readFailureReason(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) ![]const u8 {
    const bytes = dir.readFileAlloc(io, sub_path, std.testing.allocator, std.Io.Limit.unlimited) catch |err| return @errorName(err);
    std.testing.allocator.free(bytes);
    return error.TestUnexpectedResult;
}

/// Emitted log lines in `text`, so a test counts them without pinning wording it does not own.
fn loggedLines(text: []const u8) usize {
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len != 0) lines += 1;
    }
    return lines;
}

/// The rule a refused read must satisfy: exactly one line, and it carries the reason.
fn expectOneLineCarrying(text: []const u8, reason: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), loggedLines(text));
    try std.testing.expect(std.mem.indexOf(u8, text, reason) != null);
}

/// The error name `bytes` produce when parsed, so a test names the reason without hard-coding it.
/// Bytes that do parse mean the test set itself up wrong.
fn jsonFailureReason(bytes: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{}) catch |err| return @errorName(err);
    parsed.deinit();
    return error.TestUnexpectedResult;
}

test "the file is {config, current_file}; every saved field round-trips; renderers are never written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = nonDefaultConfig();
    try saveInDir(std.testing.allocator, io, tmp.dir, original);

    const bytes = tmp.dir.readFileAlloc(io, file_name, std.testing.allocator, std.Io.Limit.unlimited) catch unreachable;
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "{\"config\":{"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"current_file\":null}") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "renderers") == null);

    const restored = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    try expectSavedFieldsEqual(original, restored);
    try std.testing.expectEqual(config.Config.default().renderers.preferred, restored.renderers.preferred);
}

test "the config object writes bools as bools and choices by name" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeConfigJson(&w, nonDefaultConfig());
    try std.testing.expectEqualStrings(
        "{\"difficulty\":\"hard\",\"log_level\":\"warn\",\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":true,\"auto_restore\":true,\"auto_new\":true,\"auto_save\":true,\"auto_pencil\":true,\"show_marks\":false,\"test_probe\":true}",
        w.buffered(),
    );
}

test "a field this app does not know is ignored; the known fields and the current file still load" {
    const newer =
        \\{"config":{"difficulty":"hard","log_level":"warn","theme":"light","show_region":true,"warn_solvability":true,
        \\"auto_restore":true,"auto_new":true,"auto_save":true,"auto_pencil":true,"show_marks":false,"test_probe":true,"from_a_newer_app":{"x":[1,2]}},
        \\"also_newer":1,"current_file":"/games/a.sud"}
    ;
    try expectSavedFieldsEqual(nonDefaultConfig(), try loadBytes(std.testing.allocator, newer));

    const current = (try loadCurrentFileBytes(std.testing.allocator, newer, .ignore)) orelse return error.TestFailed;
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings("/games/a.sud", current);
}

test "a missing field keeps its default" {
    const older =
        \\{"config":{"theme":"dark","show_region":true},"current_file":null}
    ;
    const cfg = try loadBytes(std.testing.allocator, older);
    const defaults = config.Config.default();
    try std.testing.expectEqual(defaults.show_marks, cfg.show_marks);
    try std.testing.expectEqual(defaults.auto_save, cfg.auto_save);
    try std.testing.expectEqual(defaults.auto_pencil, cfg.auto_pencil);
    try std.testing.expectEqual(config.ViewTheme.dark, cfg.theme);
    try std.testing.expect(cfg.show_region);
}

test "unparsable bytes are refused, with one line carrying the reason" {
    const bytes = "{\"config\":{";

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, loadBytes(std.testing.allocator, bytes));
    try expectOneLineCarrying(sink.buffered(), try jsonFailureReason(bytes));
}

test "a config file whose top level is not an object is refused, with one line carrying the reason" {
    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    // Valid JSON, but an array: the file's shape is `{config, current_file}`, so this is no file at all.
    try std.testing.expectError(Error.System, loadBytes(std.testing.allocator, "[{\"config\":{}}]"));
    try expectOneLineCarrying(sink.buffered(), @errorName(Error.InvalidJson));
}

test "a value the config table rejects is refused, with one line carrying the reason" {
    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, loadBytes(std.testing.allocator, "{\"config\":{\"theme\":\"plaid\"}}"));
    try expectOneLineCarrying(sink.buffered(), @errorName(Error.UnsupportedValue));
}

test "a config member that is not an object is refused, with one line carrying the reason" {
    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, loadBytes(std.testing.allocator, "{\"config\":[1]}"));
    try expectOneLineCarrying(sink.buffered(), @errorName(Error.InvalidJson));
}

test "a missing config file plays on the defaults and logs one info line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    const cfg = try loadOrDefaultInDir(std.testing.allocator, std.testing.io, tmp.dir);
    try expectSavedFieldsEqual(config.Config.default(), cfg);
    try std.testing.expectEqualStrings(
        "info [sudoku] expected: no config file at config.json yet, config not read (FileNotFound)\n",
        sink.buffered(),
    );
}

test "a config file it cannot read is refused, with one line carrying the reason" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeConfigUnreadable(io, tmp.dir);

    // The reason is the platform's, so the test reads the same unreadable path itself to name it.
    const reason = try readFailureReason(tmp.dir, io, file_name);

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, loadOrDefaultInDir(std.testing.allocator, io, tmp.dir));
    var want: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&want, "warn [sudoku] config file config.json unreadable, config not read: {s}\n", .{reason}),
        sink.buffered(),
    );
}

test "loadOrDefault's refusal names the full resolved path, not the bare file name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(rel_path);
    // An absolute data directory, the way a host resolves one: the refusal's path is the joined
    // `config.json` under it, a different string from `loadOrDefaultInDir`'s bare file name.
    const data_path = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_path, gpa);
    defer gpa.free(data_path);
    const file_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ data_path, file_name });
    defer gpa.free(file_path);

    try makeConfigUnreadable(io, tmp.dir);
    const reason = try readFailureReason(std.Io.Dir.cwd(), io, file_path);

    var logged: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, loadOrDefault(gpa, io, data_path));
    var want: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&want, "warn [sudoku] config file {s} unreadable, config not read: {s}\n", .{ file_path, reason }),
        sink.buffered(),
    );
}

test "a config file it can read wins over the defaults, and the read says nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{\"config\":{\"difficulty\":\"hard\",\"theme\":\"light\"}}" });

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    const cfg = try loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    // Both differ from the code defaults, so the file is the only source of these two values.
    try std.testing.expectEqual(config.Difficulty.hard, cfg.difficulty);
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);
    try std.testing.expectEqualStrings("", sink.buffered());
}

test "a config file that does not parse is refused, with one line carrying the reason" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "{\"config\":{\"theme\":\"light\"},";
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = bytes });

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, loadOrDefaultInDir(std.testing.allocator, io, tmp.dir));
    try expectOneLineCarrying(sink.buffered(), try jsonFailureReason(bytes));
}

test "a config file holding a value the table rejects is refused, with one line carrying the reason" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{\"config\":{\"theme\":\"plaid\"}}" });

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, loadOrDefaultInDir(std.testing.allocator, io, tmp.dir));
    try expectOneLineCarrying(sink.buffered(), @errorName(Error.UnsupportedValue));
}

test "setCurrentFile refuses a config file it cannot read instead of rewriting it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    try makeConfigUnreadable(io, tmp.dir);

    var logged: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, setCurrentFile(std.testing.allocator, io, data_path, "/games/new.sud"));

    // Refused, not repaired: the path still holds the directory this test put there.
    const after = try tmp.dir.statFile(io, file_name, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, after.kind);

    // The refusal is the READ's. A lenient read would fall back to the defaults and fail later at
    // the write instead, which logs a second line — the directory alone cannot tell the two apart,
    // because neither reading can write over it.
    const logged_text = sink.buffered();
    try std.testing.expect(std.mem.indexOf(u8, logged_text, "unreadable, config not read") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged_text, "config write") == null);
}

test "save repairs a config file whose pointer it cannot parse" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{\"config\":{\"theme\":\"light\"},\"current_file\":\"/games/old.sud\"" });

    // A file that does not parse is one more file the pointer's reader cannot use: the Config is
    // already in hand, so save repairs it rather than refusing.
    try save(std.testing.allocator, io, data_path, nonDefaultConfig());

    const after = try tmp.dir.readFileAlloc(io, file_name, std.testing.allocator, std.Io.Limit.unlimited);
    defer std.testing.allocator.free(after);
    try expectSavedFieldsEqual(nonDefaultConfig(), try loadBytes(std.testing.allocator, after));
    // The pointer it could not read is gone, so the file is usable again rather than left as it was.
    try std.testing.expect(std.mem.indexOf(u8, after, "\"current_file\":null") != null);
}

test "save's repair of a file it cannot parse logs that it is repairing, not refusing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const bytes = "{\"config\":{\"theme\":\"light\"},\"current_file\":\"/games/old.sud\"";
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = bytes });

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try save(std.testing.allocator, io, data_path, nonDefaultConfig());

    // The store is rewriting this file, so its one line says repair rather than refusal.
    var want: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&want, "warn [sudoku] config file does not parse, repairing: {s}\n", .{try jsonFailureReason(bytes)}),
        sink.buffered(),
    );
}

test "an unresolvable config path is refused, with one line carrying the reason" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;

    try std.testing.expectError(Error.System, configPath(failing.allocator(), ".zig-cache/tmp"));
    try std.testing.expectEqualStrings(
        "err [sudoku] config file path in .zig-cache/tmp could not be resolved: OutOfMemory\n",
        sink.buffered(),
    );
}

test "applyConfigJson patches only the fields it carries; a bad value changes nothing" {
    var cfg = config.Config.default();
    try applyConfigJson(std.testing.allocator, &cfg, "{\"theme\":\"light\",\"auto_save\":true}");
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);
    try std.testing.expect(cfg.auto_save);
    try std.testing.expectEqual(config.Config.default().difficulty, cfg.difficulty);

    const before = cfg;
    try std.testing.expectError(Error.UnsupportedValue, applyConfigJson(std.testing.allocator, &cfg, "{\"show_region\":true,\"difficulty\":\"brutal\"}"));
    try std.testing.expectError(Error.InvalidJson, applyConfigJson(std.testing.allocator, &cfg, "{\"theme\":"));
    try expectSavedFieldsEqual(before, cfg);
}

test "applyConfigJson takes only values Settings offers: difficulty default and a numeric level are refused" {
    var cfg = config.Config.default();
    const before = cfg;
    try std.testing.expectError(Error.UnsupportedValue, applyConfigJson(std.testing.allocator, &cfg, "{\"difficulty\":\"default\"}"));
    try std.testing.expectError(Error.UnsupportedValue, applyConfigJson(std.testing.allocator, &cfg, "{\"log_level\":1}"));
    try expectSavedFieldsEqual(before, cfg);
}

test "setCurrentFile persists the pointer and keeps the stored Config" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    try save(std.testing.allocator, io, data_path, nonDefaultConfig());
    try setCurrentFile(std.testing.allocator, io, data_path, "/tmp/sudoku_restore_step2.sud");
    const current = try loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("/tmp/sudoku_restore_step2.sud", current.?);
    try expectSavedFieldsEqual(nonDefaultConfig(), try loadOrDefault(std.testing.allocator, io, data_path));
}

test "save keeps the stored current_file pointer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    try setCurrentFile(std.testing.allocator, io, data_path, "/tmp/sudoku_restore_preserve.sud");
    var cfg = config.Config.default();
    cfg.theme = .light;
    try save(std.testing.allocator, io, data_path, cfg);

    const current = try loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("/tmp/sudoku_restore_preserve.sud", current.?);
}
