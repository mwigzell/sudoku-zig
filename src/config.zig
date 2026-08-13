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
};

test "config.default produces valid config" {
    const cfg = Config.default();
    if (cfg.difficulty != .easy) return error.TestFailed;
    if (cfg.preferred_renderer != .ansi) return error.TestFailed;
    if (cfg.fallback_renderer != .ansi) return error.TestFailed;
}
