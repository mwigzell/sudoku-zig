const puzzle_gen = @import("puzzle_gen.zig");
const logger = @import("logger.zig");

pub const Difficulty = puzzle_gen.Difficulty;

/// Renderer back-ends available to the bootstrap layer.
pub const RendererKind = enum { ansi, ascii, tui, wasm };

/// Nominal game configuration — preference + escape hatch.
pub const Config = struct {
    difficulty: puzzle_gen.Difficulty,
    /// Preferred renderer type. If it fails at init, the bootstrap falls back here.
    preferred_renderer: RendererKind,
    /// Fallback tried when the preferred renderer cannot be constructed; "null" forbids the fallback.
    fallback_renderer: ?RendererKind,
    /// Runtime minimum log severity emitted by the Logger; defaults to .info.
    log_level: logger.Severity,

    /// Hard-coded defaults — main.zig supplies this to the Sudoku layer at init time.
    pub fn default() Config {
        return .{
            .difficulty = .easy,
            .preferred_renderer = .ansi,
            .fallback_renderer = .ansi,
            .log_level = .info,
        };
    }
};

test "config.default produces valid config" {
    const cfg = Config.default();
    if (cfg.difficulty != .easy) return error.TestFailed;
    if (cfg.preferred_renderer != .ansi) return error.TestFailed;
    if (cfg.fallback_renderer != .ansi) return error.TestFailed;
}
