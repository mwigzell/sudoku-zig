// Startup config contract: host-resolved Config (disk + host-parsed CLI overrides) is what native
// Sudoku and wasm GameEngine must use — not JS literals or a second default path.
const std = @import("std");
const config = @import("../config.zig");
const logger = @import("../logger.zig");
const config_store = @import("../config_store.zig");
const save_defaults = @import("../save_defaults.zig");

const log = logger.Logger(.startup);

/// Directory settings and save files live in when the platform could not resolve a data directory.
const WORKING_DIR = ".";

/// The platform's data directory as the host entry resolved it: the path, or why there is none.
/// The absence travels with the platform's reason so the fall-back and its one log line stay in core.
pub const DataDir = union(enum) {
    /// The platform resolved a directory; settings and save files live there.
    resolved: []const u8,
    /// The platform could not resolve one; `reason` is its error name (`@errorName`), for the log.
    unavailable: []const u8,
};

/// The directory settings and save files live in: the host's data directory, or the working
/// directory when the host had none (settings are then read from there and never written back).
/// `host_dir`: the path the entry resolved, or the platform's reason for having none.
pub fn dataDirOrWorkingDir(host_dir: DataDir) []const u8 {
    return switch (host_dir) {
        .resolved => |dir| dir,
        .unavailable => WORKING_DIR,
    };
}

/// Command-line flags the host parsed, as values: `null` means the player did not give that flag.
/// Each field is applied on top of the settings read from disk; nothing here replaces a saved value
/// the player did not name on this run.
pub const CliOverrides = struct {
    /// `-d` / `--difficulty`: puzzle difficulty for new games.
    difficulty: ?config.Difficulty = null,
    /// `-r` / `--renderer`: this run's renderer, never written to the settings file.
    renderer: ?config.RendererKind = null,
    /// `-v` / `--log-level`: runtime minimum log severity.
    log_level: ?logger.Severity = null,

    /// Lay the overrides over `base`; a flag the player did not give keeps `base`'s value.
    /// `base`: the settings loaded from disk (or code defaults when there is no file).
    /// Returns: the Config this run plays with.
    pub fn applyTo(self: CliOverrides, base: config.Config) config.Config {
        var cfg = base;
        if (self.difficulty) |difficulty| cfg.difficulty = difficulty;
        if (self.renderer) |renderer| cfg.renderers.preferred = renderer;
        if (self.log_level) |log_level| cfg.log_level = log_level;
        return cfg;
    }
};

/// Sync global logger severity from resolved startup config.
pub fn applyLoggerFromStartup(startup: config.Config) void {
    logger.min_level = startup.log_level;
}

/// JSON body for `/host-config.json`: `{"config": …}` in `config.json`'s shape, plus the host's file facts.
pub fn writeHostStartupJson(w: *std.Io.Writer, startup: config.Config) !void {
    return writeHostStartupJsonWithCurrentFile(w, startup, false, save_defaults.DEFAULT_SAVE_FILE);
}

/// Host bootstrap JSON for web clients: player config plus where the host serves its
/// current file (`startup_save_path`, null without one) and the name to save under.
pub fn writeHostStartupJsonWithCurrentFile(
    w: *std.Io.Writer,
    startup: config.Config,
    has_current_file: bool,
    default_save_filename: []const u8,
) !void {
    const startup_save_path = if (has_current_file) "/current-file" else null;
    try w.writeAll("{\"config\":");
    try config_store.writeConfigJson(w, startup);
    try w.writeAll(",\"default_save_filename\":");
    try std.json.Stringify.value(default_save_filename, .{}, w);
    try w.print(",\"startup_save_path\":{f}}}", .{std.json.fmt(startup_save_path, .{})});
}

/// Serialize startup config into a fixed buffer for host-config responses.
pub fn formatHostStartupJson(startup: config.Config, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try writeHostStartupJson(&w, startup);
    try std.Io.Writer.flush(&w);
    return w.buffered();
}

/// Formats host startup JSON with the host's current-file facts for platform adapters.
pub fn formatHostStartupJsonWithCurrentFile(
    startup: config.Config,
    has_current_file: bool,
    default_save_filename: []const u8,
    buf: []u8,
) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try writeHostStartupJsonWithCurrentFile(&w, startup, has_current_file, default_save_filename);
    try std.Io.Writer.flush(&w);
    return w.buffered();
}

fn expectStartupConfigOnEngine(engine: anytype, startup: config.Config) !void {
    try std.testing.expectEqual(startup.warn_solvability, engine.warn_dead_moves);
    try std.testing.expectEqual(startup.show_marks, engine.show_marks);
}

/// Load player prefs from disk, apply the host's command-line overrides, persist player prefs only.
/// `host_dir`: the platform data directory the host resolved, or its reason for having none.
/// `overrides`: flags the host parsed from argv; absent flags keep the values read from disk.
pub fn resolveStartupConfig(
    gpa: std.mem.Allocator,
    io: std.Io,
    host_dir: DataDir,
    overrides: CliOverrides,
) config_store.Error!config.Config {
    const dir = switch (host_dir) {
        .resolved => |dir| dir,
        .unavailable => |reason| {
            // No durable settings location: read the working directory, write nothing back, and
            // name the platform's reason once — this fall-back is startup's only log line.
            log.warn("data dir unavailable, reading settings and saving files in the working directory: {s}", .{reason});
            return overrides.applyTo(try config_store.loadOrDefault(gpa, io, WORKING_DIR));
        },
    };
    config_store.ensureConfigDir(io, dir);

    const cfg = overrides.applyTo(try config_store.loadOrDefault(gpa, io, dir));
    try config_store.save(gpa, io, dir, cfg);
    return cfg;
}

test "startup applies the given overrides on top of the saved settings and persists them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const saved = config.Config{
        .difficulty = .easy,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
        .theme = .dark,
        .show_region = false,
    };
    try config_store.saveInDir(std.testing.allocator, io, tmp.dir, saved);

    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const cfg = try resolveStartupConfig(std.testing.allocator, io, .{ .resolved = data_path }, .{
        .difficulty = .hard,
        .renderer = .ascii,
        .log_level = .warn,
    });
    try std.testing.expectEqual(config.Difficulty.hard, cfg.difficulty);
    try std.testing.expectEqual(config.RendererKind.ascii, cfg.renderers.preferred);
    try std.testing.expectEqual(logger.Severity.warn, cfg.log_level);
    // Fields the command line did not touch keep what the file said.
    try std.testing.expectEqual(config.ViewTheme.dark, cfg.theme);
    try std.testing.expectEqual(false, cfg.show_region);

    // Player prefs are written back; the renderer is this run's only and stays out of the file.
    const restored = try config_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expectEqual(config.Difficulty.hard, restored.difficulty);
    try std.testing.expectEqual(logger.Severity.warn, restored.log_level);
    try std.testing.expectEqual(config.ViewTheme.dark, restored.theme);
}

test "startup without overrides keeps every saved setting, not code defaults" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var saved = config.Config.default();
    saved.difficulty = .hard;
    saved.log_level = .debug;
    saved.theme = .light;
    saved.show_region = true;
    try config_store.saveInDir(std.testing.allocator, io, tmp.dir, saved);

    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const cfg = try resolveStartupConfig(std.testing.allocator, io, .{ .resolved = data_path }, .{});
    try std.testing.expectEqual(config.Difficulty.hard, cfg.difficulty);
    try std.testing.expectEqual(logger.Severity.debug, cfg.log_level);
    try std.testing.expectEqual(config.ViewTheme.light, cfg.theme);
    try std.testing.expectEqual(true, cfg.show_region);
}

test "host startup JSON reflects Config loaded from config.json on disk" {
    const test_defaults = @import("../../test/config_defaults.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var on_disk = test_defaults.testConfigDefaults();
    on_disk.difficulty = .medium;
    on_disk.log_level = .debug;
    on_disk.theme = .light;
    on_disk.show_region = true;
    on_disk.warn_solvability = true;
    on_disk.auto_restore = true;
    on_disk.auto_new = true;
    on_disk.auto_save = true;
    try config_store.saveInDir(std.testing.allocator, io, tmp.dir, on_disk);

    const loaded = try config_store.loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    var buf: [1024]u8 = undefined;
    const json = try formatHostStartupJson(loaded, &buf);
    try std.testing.expectEqualStrings(
        "{\"config\":{\"difficulty\":\"medium\",\"log_level\":\"debug\",\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":true,\"auto_restore\":true,\"auto_new\":true,\"auto_save\":true,\"show_marks\":true,\"test_probe\":false},\"default_save_filename\":\"sudoku.sud\",\"startup_save_path\":null}",
        json,
    );
}

test "host startup JSON points at the current file when the host has one" {
    const test_defaults = @import("../../test/config_defaults.zig");
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = true;
    cfg.auto_new = false;
    var buf: [1024]u8 = undefined;
    const json = try formatHostStartupJsonWithCurrentFile(cfg, true, save_defaults.DEFAULT_SAVE_FILE, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "startup_action") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"startup_save_path\":\"/current-file\"") != null);
}

test "startup config supplies the engine's fields and its log level reaches the logger" {
    const startup_engine = @import("engine.zig");
    const startup = (CliOverrides{ .difficulty = .hard, .log_level = .warn }).applyTo(config.Config.default());

    var engine = try startup_engine.initEngineFromStartup(startup);
    defer engine.deinit();

    try expectStartupConfigOnEngine(&engine, startup);
    try std.testing.expectEqual(logger.Severity.warn, logger.min_level);
}

test "host startup JSON's config reads back into the engine's fields (web host analogue)" {
    const startup_engine = @import("engine.zig");
    var sent = config.Config.default();
    sent.warn_solvability = true;
    sent.show_marks = false;
    var buf: [1024]u8 = undefined;
    const json = try formatHostStartupJson(sent, &buf);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    try std.json.Stringify.value(parsed.value.object.get("config").?, .{}, &body.writer);

    var startup = config.Config.default();
    try config_store.applyConfigJson(std.testing.allocator, &startup, body.written());
    var engine = try startup_engine.initEngineFromStartup(startup);
    defer engine.deinit();
    try expectStartupConfigOnEngine(&engine, startup);
    try std.testing.expect(!engine.show_marks);
}

test "startup with no data directory names the platform's reason and applies the overrides" {
    var buf: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buf);
    logger.test_sink = &sink;
    defer logger.test_sink = null;
    logger.min_level = .warn;
    defer logger.min_level = .info;

    const host_dir = DataDir{ .unavailable = "EnvironmentVariableMissing" };
    const cfg = try resolveStartupConfig(std.testing.allocator, std.testing.io, host_dir, .{ .difficulty = .hard });

    try std.testing.expectEqual(config.Difficulty.hard, cfg.difficulty);
    try std.testing.expectEqualStrings(
        "warn [startup] data dir unavailable, reading settings and saving files in the working directory: EnvironmentVariableMissing\n",
        sink.buffered(),
    );
}

test "the host's data dir is used, and the working directory when the host had none" {
    const resolved = DataDir{ .resolved = "/home/player/.local/share/sudoku" };
    const missing = DataDir{ .unavailable = "EnvironmentVariableMissing" };

    try std.testing.expectEqualStrings("/home/player/.local/share/sudoku", dataDirOrWorkingDir(resolved));
    try std.testing.expectEqualStrings(".", dataDirOrWorkingDir(missing));
}
