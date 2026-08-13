const std = @import("std");
const puzzle_gen = @import("puzzle_gen.zig");

pub const Difficulty = puzzle_gen.Difficulty;

/// Renderer back-ends available to the bootstrap layer.
pub const RendererKind = enum { ansi, tui, wasm };

/// Nominal game configuration — preference + escape hatch.
pub const Config = struct {
    difficulty: puzzle_gen.Difficulty,
    /// Preferred renderer type. If it fails at init, the bootstrap falls back here.
    preferred_renderer: RendererKind,
    /// Always-available fallback when preferred renderer is missing or platform-incompatible.
    fallback_renderer: RendererKind,

    /// Hard-coded defaults — main.zig supplies this to the Sudoku layer at init time.
    pub fn default() Config {
        return .{
            .difficulty = .easy,
            .preferred_renderer = .ansi,
            .fallback_renderer = .ansi,
        };
    }

    /// Parse command-line flags into a Config. Recognises `--renderer <kind>`.
    pub fn parseCLI(args: []const []const u8) error{InvalidRenderer}!Config {
        var cfg = Config.default();

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--renderer")) {
                if (i + 1 >= args.len) return error.InvalidRenderer;
                cfg.preferred_renderer = parseRenderer(args[i + 1]) catch return error.InvalidRenderer;
                i += 1; // skip the value arg
            }
        }

        return cfg;
    }
};

fn parseRenderer(kind: []const u8) error{InvalidRenderer}!RendererKind {
    if (std.mem.eql(u8, kind, "ansi")) return .ansi;
    if (std.mem.eql(u8, kind, "tui")) return .tui;
    if (std.mem.eql(u8, kind, "wasm")) return .wasm;
    return error.InvalidRenderer;
}

test "config.default produces valid config" {
    const cfg = Config.default();
    if (cfg.difficulty != .easy) return error.TestFailed;
    if (cfg.preferred_renderer != .ansi) return error.TestFailed;
    if (cfg.fallback_renderer != .ansi) return error.TestFailed;
}

test "config.parseCLI no flags returns defaults" {
    const args: []const []const u8 = &[_][]const u8{};

    const cfg = Config.parseCLI(args) catch |err| {
        if (err == error.InvalidRenderer) return error.TestFailed;
        return err;
    };
    if (cfg.preferred_renderer != .ansi) return error.TestFailed;
    if (cfg.fallback_renderer != .ansi) return error.TestFailed;
}

test "config.parseCLI --renderer wasm" {
    const args = &[_][]const u8{ "--renderer", "wasm" };

    const cfg = Config.parseCLI(args) catch |err| {
        if (err == error.InvalidRenderer) return error.TestFailed;
        return err;
    };
    if (cfg.preferred_renderer != .wasm) return error.TestFailed;
}
