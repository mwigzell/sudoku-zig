const std = @import("std");
const config = @import("config.zig");

pub const ParseError = error{
    HelpRequested,
    UnknownFlag,
};

fn usage(exit_code: u8) noreturn {
    std.debug.print(
        \\Usage: sudoku [OPTIONS]
        \\
        \\  -h, --help              Show this help message
        \\  -r, --renderer <kind>   Choose renderer (ansi, tui, wasm)
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
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--renderer")) {
            const kind = iterator.next() orelse {
                std.debug.print("Error: --renderer requires a value\n", .{});
                usage(1);
            };
            cfg.preferred_renderer = parseRenderer(kind) orelse {
                std.debug.print("Error: invalid renderer kind '{s}'\n", .{kind});
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
    if (std.mem.eql(u8, kind, "tui")) return .tui;
    if (std.mem.eql(u8, kind, "wasm")) return .wasm;
    return null;
}
