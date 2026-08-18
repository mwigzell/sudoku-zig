const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const version = @import("version.zig");

pub const ParseError = error{
    HelpRequested,
    UnknownFlag,
};

fn usage(exit_code: u8) noreturn {
    std.debug.print(
        \\Usage: sudoku [OPTIONS]
        \\
        \\  -h, --help              Show this help message
        \\  -V, --version           Show version and exit
        \\  -r, --renderer <kind>   Choose renderer (ansi, ascii, tui, web)
        \\  -d, --difficulty <level> Puzzle difficulty (easy, medium, hard)
        \\  -v, --log-level <level>  Minimum log severity (debug, info, warn, err, fatal)
        \\
    , .{});

    std.process.exit(exit_code);
}

/// Iterate argv and return a Config with defaults overridden by flags.
pub fn parseCLI(iterator: *std.process.Args.Iterator) ParseError!config.Config {
    _ = iterator.next(); // skip process name

    var cfg = config.Config.default();

    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage(0);
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("sudoku {s}\n", .{version.string});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--renderer")) {
            const kind = iterator.next() orelse {
                std.debug.print("Error: --renderer requires a value\n", .{});
                usage(1);
            };
            cfg.preferred_renderer = parseRenderer(kind) orelse {
                std.debug.print("Error: invalid renderer kind '{s}'\n", .{kind});
                usage(1);
            };
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--difficulty")) {
            const diff = iterator.next() orelse {
                std.debug.print("Error: --difficulty requires a value\n", .{});
                usage(1);
            };
            cfg.difficulty = parseDifficulty(diff) orelse {
                std.debug.print("Error: invalid difficulty '{s}'\n", .{diff});
                usage(1);
            };
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--log-level")) {
            const lvl = iterator.next() orelse {
                std.debug.print("Error: --log-level requires a value\n", .{});
                usage(1);
            };
            cfg.log_level = parseLogLevel(lvl) orelse {
                std.debug.print("Error: invalid log level '{s}'\n", .{lvl});
                usage(1);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown flag: '{s}'\n", .{arg});
            usage(1);
        }
    }

    return cfg;
}

fn parseRenderer(kind: []const u8) ?config.RendererKind {
    if (std.mem.eql(u8, kind, "ansi")) return .ansi;
    if (std.mem.eql(u8, kind, "ascii")) return .ascii;
    if (std.mem.eql(u8, kind, "tui")) return .tui;
    if (std.mem.eql(u8, kind, "web")) return .web;
    return null;
}

fn parseDifficulty(diff: []const u8) ?config.Difficulty {
    if (std.mem.eql(u8, diff, "easy")) return .easy;
    if (std.mem.eql(u8, diff, "medium")) return .medium;
    if (std.mem.eql(u8, diff, "hard")) return .hard;
    return null;
}

fn parseLogLevel(lvl: []const u8) ?logger.Severity {
    if (std.mem.eql(u8, lvl, "debug")) return .debug;
    if (std.mem.eql(u8, lvl, "info")) return .info;
    if (std.mem.eql(u8, lvl, "warn")) return .warn;
    if (std.mem.eql(u8, lvl, "err")) return .err;
    if (std.mem.eql(u8, lvl, "fatal")) return .fatal;
    return null;
}

fn initIt(comptime argv: anytype) std.process.Args.Iterator {
    return std.process.Args.Iterator.init(std.process.Args{ .vector = argv[0..] });
}

test "-d medium sets medium difficulty and preserves default renderer" {
    const argv: [3][*:0]const u8 = .{ "sudoku", "-d", "medium" };
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(config.Difficulty.medium, cfg.difficulty);
    try std.testing.expectEqual(config.RendererKind.ansi, cfg.preferred_renderer);
}

test "-d hard sets hard difficulty" {
    const argv: [3][*:0]const u8 = .{ "sudoku", "-d", "hard" };
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(config.Difficulty.hard, cfg.difficulty);
}

test "no -d leaves difficulty at default easy" {
    const argv: [1][*:0]const u8 = .{"sudoku"};
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(config.Difficulty.easy, cfg.difficulty);
}

test "-d medium and -r ascii both overlay defaults" {
    const argv: [5][*:0]const u8 = .{ "sudoku", "-d", "medium", "-r", "ascii" };
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(config.Difficulty.medium, cfg.difficulty);
    try std.testing.expectEqual(config.RendererKind.ascii, cfg.preferred_renderer);
}

test "--difficulty long form sets easy" {
    const argv: [3][*:0]const u8 = .{ "sudoku", "--difficulty", "easy" };
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(config.Difficulty.easy, cfg.difficulty);
}

test "-v debug sets debug log level" {
    const argv: [3][*:0]const u8 = .{ "sudoku", "-v", "debug" };
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(logger.Severity.debug, cfg.log_level);
}

test "-v warn preserves difficulty and renderer defaults" {
    const argv: [3][*:0]const u8 = .{ "sudoku", "-v", "warn" };
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(logger.Severity.warn, cfg.log_level);
    try std.testing.expectEqual(config.Difficulty.easy, cfg.difficulty);
    try std.testing.expectEqual(config.RendererKind.ansi, cfg.preferred_renderer);
}

test "no -v leaves log level at default info" {
    const argv: [1][*:0]const u8 = .{"sudoku"};
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(logger.Severity.info, cfg.log_level);
}

test "--log-level long form sets err" {
    const argv: [3][*:0]const u8 = .{ "sudoku", "--log-level", "err" };
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(logger.Severity.err, cfg.log_level);
}

test "-d medium and -v debug both overlay defaults" {
    const argv: [5][*:0]const u8 = .{ "sudoku", "-d", "medium", "-v", "debug" };
    var it = initIt(argv);
    const cfg = parseCLI(&it) catch unreachable;
    try std.testing.expectEqual(config.Difficulty.medium, cfg.difficulty);
    try std.testing.expectEqual(logger.Severity.debug, cfg.log_level);
    try std.testing.expectEqual(config.RendererKind.ansi, cfg.preferred_renderer);
}
