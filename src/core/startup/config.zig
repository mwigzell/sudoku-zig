// Startup config contract: host-resolved Config (disk + CLI) is what native
// Sudoku and wasm GameEngine must use — not JS literals or a second default path.
const std = @import("std");
const config = @import("../config.zig");
const logger = @import("../logger.zig");
const cli = @import("../../native/cli.zig");
const config_store = @import("../config_store.zig");
const path = @import("../../native/shell/path.zig");
const save_defaults = @import("../save_defaults.zig");

const log = logger.Logger(.startup);

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

/// Load player prefs from disk, apply CLI on full `Config`, persist player prefs only.
pub fn resolveStartupConfig(
    gpa: std.mem.Allocator,
    io: std.Io,
    cli_it: *std.process.Args.Iterator,
) config_store.Error!config.Config {
    const data_dir = path.computeDataDir(gpa) catch |err| {
        log.warn("data dir unavailable, reading settings from the working directory: {s}", .{@errorName(err)});
        return config_store.loadOrDefault(gpa, io, ".");
    };
    defer gpa.free(data_dir);
    config_store.ensureConfigDir(io, data_dir);

    var cfg = try config_store.loadOrDefault(gpa, io, data_dir);
    cfg = cli.parseCLIWithBase(cli_it, cfg) catch |err| switch (err) {
        cli.ParseError.HelpRequested, cli.ParseError.UnknownFlag => unreachable,
    };
    try config_store.save(gpa, io, data_dir, cfg);
    return cfg;
}

test "CLI overrides persist on top of saved settings" {
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

    const argv: [3][*:0]const u8 = .{ "sudoku", "-d", "hard" };
    var it = std.process.Args.Iterator.init(std.process.Args{ .vector = argv[0..] });

    var cfg = try config_store.loadOrDefault(std.testing.allocator, io, data_path);
    cfg = try cli.parseCLIWithBase(&it, cfg);
    try config_store.save(std.testing.allocator, io, data_path, cfg);

    const restored = try config_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expectEqual(config.Difficulty.hard, restored.difficulty);
    try std.testing.expectEqual(config.RendererKind.ansi, restored.renderers.preferred);
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
        "{\"config\":{\"difficulty\":\"medium\",\"log_level\":\"debug\",\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":true,\"auto_restore\":true,\"auto_new\":true,\"auto_save\":true,\"show_marks\":true},\"default_save_filename\":\"sudoku.sud\",\"startup_save_path\":null}",
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

test "CLI-resolved startup config gives the engine its fields and sets logger min_level" {
    const startup_engine = @import("engine.zig");
    const argv: [5][*:0]const u8 = .{ "sudoku", "-d", "hard", "-v", "warn" };
    var it = std.process.Args.Iterator.init(std.process.Args{ .vector = argv[0..] });
    _ = it.next();
    const startup = try cli.parseCLI(&it);

    var engine = try startup_engine.initEngineFromStartup(startup);
    defer engine.deinit();

    try expectStartupConfigOnEngine(&engine, startup);
    try std.testing.expectEqual(startup.log_level, logger.min_level);
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
