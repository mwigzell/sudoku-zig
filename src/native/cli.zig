const std = @import("std");
const config = @import("../core/config.zig");
const logger = @import("../core/logger.zig");
const config_table = @import("../core/config_table.zig");
const version = @import("../core/version.zig");

pub const ParseError = error{
    HelpRequested,
    UnknownFlag,
};

const log = logger.Logger(.cli);

/// Help text; printed to stdout for -h/--version and appended to flag errors.
const usage_fmt =
    \\Usage: sudoku [OPTIONS]
    \\
    \\  -h, --help              Show this help message
    \\  -V, --version           Show version and exit
    \\  -r, --renderer <kind>   Choose renderer (ansi, ascii, tui, web)
    \\  -d, --difficulty <level> Puzzle difficulty (easy, medium, hard)
    \\  -v, --log-level <level>  Minimum log severity (debug, info, warn, err, fatal)
;
/// Iterate argv and return a Config with `base` overridden by flags.
pub fn parseCLIWithBase(iterator: *std.process.Args.Iterator, base: config.Config) ParseError!config.Config {
    _ = iterator.next(); // skip process name

    var cfg = base;

    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}\n", .{usage_fmt});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("sudoku {s}\n", .{version.string});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--renderer")) {
            const kind = iterator.next() orelse {
                failFlag("--renderer requires a value.", .{});
            };
            cfg.renderers.preferred = parseRenderer(kind) orelse {
                failFlag("invalid renderer kind '{s}'.", .{kind});
            };
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--difficulty")) {
            const diff = iterator.next() orelse {
                failFlag("--difficulty requires a value.", .{});
            };
            cfg.difficulty = config_table.parseChoice(config.Difficulty, "difficulty", diff) catch |err| {
                failFlag("invalid difficulty '{s}' ({s}).", .{ diff, @errorName(err) });
            };
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--log-level")) {
            const lvl = iterator.next() orelse {
                failFlag("--log-level requires a value.", .{});
            };
            cfg.log_level = config_table.parseChoice(logger.Severity, "log_level", lvl) catch |err| {
                failFlag("invalid log level '{s}' ({s}).", .{ lvl, @errorName(err) });
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            failFlag("Unknown flag: '{s}'.", .{arg});
        }
    }

    return cfg;
}

/// Iterate argv and return a Config with code defaults overridden by flags.
pub fn parseCLI(iterator: *std.process.Args.Iterator) ParseError!config.Config {
    return parseCLIWithBase(iterator, config.Config.default());
}

/// Exit status for a bad command-line flag.
const FLAG_ERROR_EXIT = 2;

/// A bad flag is the user's typo, not a crash: log it with the usage text and exit, no stack trace.
fn failFlag(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt ++ "\n\n{s}", args ++ .{usage_fmt});
    std.process.exit(FLAG_ERROR_EXIT);
}

fn parseRenderer(kind: []const u8) ?config.RendererKind {
    if (std.mem.eql(u8, kind, "ansi")) return .ansi;
    if (std.mem.eql(u8, kind, "ascii")) return .ascii;
    if (std.mem.eql(u8, kind, "tui")) return .tui;
    if (std.mem.eql(u8, kind, "web")) return .web;
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
    try std.testing.expectEqual(config.RendererKind.ansi, cfg.renderers.preferred);
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
    try std.testing.expectEqual(config.RendererKind.ascii, cfg.renderers.preferred);
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
    try std.testing.expectEqual(config.RendererKind.ansi, cfg.renderers.preferred);
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
    try std.testing.expectEqual(config.RendererKind.ansi, cfg.renderers.preferred);
}
