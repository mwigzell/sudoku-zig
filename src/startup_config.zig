// Startup config contract: host-resolved Config (disk + CLI) is what native
// Sudoku and wasm GameEngine must use — not JS literals or a second default path.
const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const wire = @import("wasm/wire.zig");
const cli = @import("native/cli.zig");
const settings_store = @import("settings_store.zig");
const path = @import("native/shell/path.zig");
const startup_policy = @import("startup_policy.zig");

/// View/theme fields the host wire carries alongside difficulty and log level.
pub fn configFromHostWire(
    difficulty: u8,
    log_level: u8,
    theme: config.ViewTheme,
    show_region: bool,
    warn_solvability: bool,
    auto_restore: bool,
    auto_new: bool,
    auto_save: bool,
) error{InvalidHostWire}!config.Config {
    const partial = wire.WireConfig.fromWire(difficulty, log_level) orelse return error.InvalidHostWire;
    var cfg = config.Config.default();
    cfg.difficulty = partial.difficulty.toPuzzleDifficulty();
    cfg.log_level = partial.log_level;
    cfg.theme = theme;
    cfg.show_region = show_region;
    cfg.warn_solvability = warn_solvability;
    cfg.auto_restore = auto_restore;
    cfg.auto_new = auto_new;
    cfg.auto_save = auto_save;
    return cfg;
}

pub fn applyLoggerFromStartup(startup: config.Config) void {
    logger.min_level = startup.log_level;
}

/// JSON body for `/host-config.json` — same shape as wasm `getConfig()`.
pub fn writeHostStartupJson(w: *std.Io.Writer, startup: config.Config) !void {
    return writeHostStartupJsonWithPolicy(w, startup, false);
}

/// Host bootstrap JSON for web clients, including shared startup policy action
/// so browser code can follow the same decision as native startup.
pub fn writeHostStartupJsonWithPolicy(
    w: *std.Io.Writer,
    startup: config.Config,
    has_current_file: bool,
) !void {
    const startup_save_path = if (has_current_file) "/current-file" else null;
    const wire_cfg = wire.WireConfig.fromConfig(startup);
    const decision = startup_policy.evaluate(.{
        .auto_restore = startup.auto_restore,
        .auto_new = startup.auto_new,
        .has_current_file = has_current_file,
    });
    const startup_action: []const u8 = switch (decision.action) {
        .restore => "restore",
        .new => "new",
        .idle => "idle",
    };
    const theme_name: []const u8 = switch (wire_cfg.theme) {
        .dark => "dark",
        .light => "light",
    };
    try std.Io.Writer.print(
        w,
        "{{\"difficulty\":{d},\"log_level\":{d},\"theme\":\"{s}\",\"show_region\":{any},\"warn_solvability\":{any},\"auto_restore\":{any},\"auto_new\":{any},\"auto_save\":{any},\"startup_action\":\"{s}\",\"startup_save_path\":{f}}}",
        .{
            @backingInt(wire_cfg.difficulty),
            @backingInt(wire_cfg.log_level),
            theme_name,
            wire_cfg.show_region,
            wire_cfg.warn_solvability,
            startup.auto_restore,
            startup.auto_new,
            startup.auto_save,
            startup_action,
            std.json.fmt(startup_save_path, .{}),
        },
    );
}

pub fn formatHostStartupJson(startup: config.Config, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try writeHostStartupJson(&w, startup);
    try std.Io.Writer.flush(&w);
    return w.buffered();
}

/// Formats host startup JSON with explicit policy context (current-file
/// presence + restore capability) for platform adapters.
pub fn formatHostStartupJsonWithPolicy(
    startup: config.Config,
    has_current_file: bool,
    buf: []u8,
) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try writeHostStartupJsonWithPolicy(&w, startup, has_current_file);
    try std.Io.Writer.flush(&w);
    return w.buffered();
}

fn expectStartupConfigOnEngine(engine: anytype, startup: config.Config) !void {
    const live = engine.getConfig();
    try std.testing.expectEqual(startup.difficulty, live.difficulty);
    try std.testing.expectEqual(startup.log_level, live.log_level);
    try std.testing.expectEqual(startup.theme, live.theme);
    try std.testing.expectEqual(startup.show_region, live.show_region);
    try std.testing.expectEqual(startup.warn_solvability, live.warn_solvability);
}

/// Load player prefs from disk, apply CLI on full `Config`, persist player prefs only.
pub fn resolveStartupConfig(
    gpa: std.mem.Allocator,
    io: std.Io,
    cli_it: *std.process.Args.Iterator,
) settings_store.Error!config.Config {
    const data_dir = path.computeDataDir(gpa) catch return settings_store.loadOrDefault(gpa, io, ".");
    defer gpa.free(data_dir);
    settings_store.ensureSettingsDir(io, data_dir);

    var cfg = try settings_store.loadOrDefault(gpa, io, data_dir);
    cfg = cli.parseCLIWithBase(cli_it, cfg) catch |err| switch (err) {
        cli.ParseError.HelpRequested, cli.ParseError.UnknownFlag => unreachable,
    };
    try settings_store.save(gpa, io, data_dir, cfg);
    return cfg;
}

test "CLI overrides persist on top of saved settings" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const saved = config.Config{
        .difficulty = .easy,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
        .theme = .dark,
        .show_region = false,
    };
    try settings_store.saveInDir(std.testing.allocator, io, tmp.dir, saved);

    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const argv: [3][*:0]const u8 = .{ "sudoku", "-d", "hard" };
    var it = std.process.Args.Iterator.init(std.process.Args{ .vector = argv[0..] });

    var cfg = try settings_store.loadOrDefault(std.testing.allocator, io, data_path);
    cfg = try cli.parseCLIWithBase(&it, cfg);
    try settings_store.save(std.testing.allocator, io, data_path, cfg);

    const restored = try settings_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expectEqual(config.Difficulty.hard, restored.difficulty);
    try std.testing.expectEqual(config.RendererKind.ansi, restored.preferred_renderer);
}

test "host startup JSON reflects Config loaded from settings.json on disk" {
    const test_defaults = @import("test/config_defaults.zig");
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
    try settings_store.saveInDir(std.testing.allocator, io, tmp.dir, on_disk);

    const loaded = try settings_store.loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    var buf: [256]u8 = undefined;
    const json = try formatHostStartupJson(loaded, &buf);
    try std.testing.expectEqualStrings(
        "{\"difficulty\":2,\"log_level\":0,\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":true,\"auto_restore\":true,\"auto_new\":true,\"auto_save\":true,\"startup_action\":\"new\",\"startup_save_path\":null}",
        json,
    );
}

test "host startup JSON matches Config wire fields" {
    const startup = config.Config{
        .difficulty = .medium,
        .preferred_renderer = .web,
        .fallback_renderer = .ansi,
        .log_level = .debug,
        .theme = .light,
        .show_region = true,
        .auto_restore = true,
        .auto_new = false,
        .auto_save = true,
    };

    var buf: [256]u8 = undefined;
    const json = try formatHostStartupJson(startup, &buf);
    try std.testing.expectEqualStrings(
        "{\"difficulty\":2,\"log_level\":0,\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":false,\"auto_restore\":true,\"auto_new\":false,\"auto_save\":true,\"startup_action\":\"idle\",\"startup_save_path\":null}",
        json,
    );
}

test "host startup JSON policy chooses restore when current file exists" {
    const test_defaults = @import("test/config_defaults.zig");
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = true;
    cfg.auto_new = false;
    var buf: [256]u8 = undefined;
    const json = try formatHostStartupJsonWithPolicy(cfg, true, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"startup_action\":\"restore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"startup_save_path\":\"/current-file\"") != null);
}

test "CLI-resolved startup config is GameEngine.cfg and logger min_level" {
    const startup_engine = @import("startup_engine.zig");
    const argv: [5][*:0]const u8 = .{ "sudoku", "-d", "hard", "-v", "warn" };
    var it = std.process.Args.Iterator.init(std.process.Args{ .vector = argv[0..] });
    _ = it.next();
    const startup = try cli.parseCLI(&it);

    var engine = try startup_engine.initEngineFromStartup(startup);
    defer engine.deinit();

    try expectStartupConfigOnEngine(&engine, startup);
    try std.testing.expectEqual(startup.log_level, logger.min_level);
}

test "host wire startup config matches GameEngine.cfg (web host analogue)" {
    const startup_engine = @import("startup_engine.zig");
    const startup = try configFromHostWire(
        @backingInt(wire.PlayerDifficulty.hard),
        @backingInt(logger.Severity.warn),
        .light,
        true,
        false,
        true,
        true,
        true,
    );

    var engine = try startup_engine.initEngineFromStartup(startup);
    defer engine.deinit();

    try expectStartupConfigOnEngine(&engine, startup);
}
