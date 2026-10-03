// Startup config contract: host-resolved Config (disk + CLI) is what native
// Sudoku and wasm GameEngine must use — not JS literals or a second default path.
const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const game_engine = @import("engine/game_engine.zig");
const wire = @import("wasm/wire.zig");
const cli = @import("native/cli.zig");
const sudoku = @import("native/shell/sudoku.zig");
const host_mod = @import("native/host.zig");
const settings_store = @import("settings_store.zig");
const path = @import("native/shell/path.zig");

/// View/theme fields the host wire carries alongside difficulty and log level.
pub fn configFromHostWire(
    difficulty: u8,
    log_level: u8,
    theme: config.ViewTheme,
    show_region: bool,
    warn_solvability: bool,
) error{InvalidHostWire}!config.Config {
    const partial = wire.WireConfig.fromWire(difficulty, log_level) orelse return error.InvalidHostWire;
    var cfg = config.Config.default();
    cfg.difficulty = partial.difficulty.toPuzzleDifficulty();
    cfg.log_level = partial.log_level;
    cfg.theme = theme;
    cfg.show_region = show_region;
    cfg.warn_solvability = warn_solvability;
    return cfg;
}

/// Same nominal fields `getConfig()` JSON exposes must match host startup config.
pub fn expectStartupLiveOnEngine(engine: *const game_engine.GameEngine, startup: config.Config) !void {
    const live = engine.getConfig();
    try std.testing.expectEqual(startup.difficulty, live.difficulty);
    try std.testing.expectEqual(startup.log_level, live.log_level);
    try std.testing.expectEqual(startup.theme, live.theme);
    try std.testing.expectEqual(startup.show_region, live.show_region);
    try std.testing.expectEqual(startup.warn_solvability, live.warn_solvability);
}

pub fn applyLoggerFromStartup(startup: config.Config) void {
    logger.min_level = startup.log_level;
}

/// JSON body for `/host-config.json` — same shape as wasm `getConfig()`.
pub fn writeHostStartupJson(w: *std.Io.Writer, startup: config.Config) !void {
    const wire_cfg = wire.WireConfig.fromConfig(startup);
    const theme_name: []const u8 = switch (wire_cfg.theme) {
        .dark => "dark",
        .light => "light",
    };
    try std.Io.Writer.print(
        w,
        "{{\"difficulty\":{d},\"log_level\":{d},\"theme\":\"{s}\",\"show_region\":{any},\"warn_solvability\":{any}}}",
        .{
            @backingInt(wire_cfg.difficulty),
            @backingInt(wire_cfg.log_level),
            theme_name,
            wire_cfg.show_region,
            wire_cfg.warn_solvability,
        },
    );
}

pub fn formatHostStartupJson(startup: config.Config, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try writeHostStartupJson(&w, startup);
    try std.Io.Writer.flush(&w);
    return w.buffered();
}

fn emptyPuzzleLine() [81]u8 {
    var line: [81]u8 = undefined;
    @memset(&line, '0');
    return line;
}

/// Native path analogue: `parseCLI` → logger + `GameEngine.init`.
pub fn initEngineFromStartup(startup: config.Config) game_engine.Error!game_engine.GameEngine {
    applyLoggerFromStartup(startup);
    return game_engine.GameEngine.init(emptyPuzzleLine()[0..], startup);
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
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var on_disk = config.Config.default();
    on_disk.difficulty = .medium;
    on_disk.log_level = .debug;
    on_disk.theme = .light;
    on_disk.show_region = true;
    on_disk.warn_solvability = true;
    try settings_store.saveInDir(std.testing.allocator, io, tmp.dir, on_disk);

    const loaded = try settings_store.loadOrDefaultInDir(std.testing.allocator, io, tmp.dir);
    var buf: [160]u8 = undefined;
    const json = try formatHostStartupJson(loaded, &buf);
    try std.testing.expectEqualStrings(
        "{\"difficulty\":2,\"log_level\":0,\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":true}",
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
    };

    var buf: [128]u8 = undefined;
    const json = try formatHostStartupJson(startup, &buf);
    try std.testing.expectEqualStrings(
        "{\"difficulty\":2,\"log_level\":0,\"theme\":\"light\",\"show_region\":true,\"warn_solvability\":false}",
        json,
    );
}

test "CLI-resolved startup config is GameEngine.cfg and logger min_level" {
    const argv: [5][*:0]const u8 = .{ "sudoku", "-d", "hard", "-v", "warn" };
    var it = std.process.Args.Iterator.init(std.process.Args{ .vector = argv[0..] });
    _ = it.next();
    const startup = try cli.parseCLI(&it);

    var engine = try initEngineFromStartup(startup);
    defer engine.deinit();

    try expectStartupLiveOnEngine(&engine, startup);
    try std.testing.expectEqual(startup.log_level, logger.min_level);
}

test "Sudoku.init uses CLI-resolved startup config on engine" {
    const argv: [5][*:0]const u8 = .{ "sudoku", "-d", "medium", "-v", "debug" };
    var it = std.process.Args.Iterator.init(std.process.Args{ .vector = argv[0..] });
    _ = it.next();
    const startup = try cli.parseCLI(&it);
    applyLoggerFromStartup(startup);

    var host = host_mod.Host.createForTest(startup, &[0][]const u8{});
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();

    var app = try sudoku.Sudoku.init(startup, facade, @import("native/shell/file_transport.zig").NativeTransport.make(std.testing.io), host.writer(), null);
    defer app.deinit();

    try std.testing.expectEqual(startup.difficulty, app.cfg.difficulty);
    try std.testing.expectEqual(startup.log_level, app.cfg.log_level);
    try expectStartupLiveOnEngine(&app.engine, startup);
}

test "host wire startup config matches GameEngine.cfg (web host analogue)" {
    const startup = try configFromHostWire(
        @backingInt(wire.PlayerDifficulty.hard),
        @backingInt(logger.Severity.warn),
        .light,
        true,
        false,
    );

    var engine = try initEngineFromStartup(startup);
    defer engine.deinit();

    try expectStartupLiveOnEngine(&engine, startup);
}
