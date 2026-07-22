const puzzle_gen = @import("puzzle_gen.zig");

/// Renderer back-ends available to the bootstrap layer.
pub const RendererKind = enum { ascii_ansi };

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
            .preferred_renderer = .ascii_ansi,
            .fallback_renderer = .ascii_ansi,
        };
    }
};

test "config.default produces valid config" {
    const cfg = Config.default();
    if (cfg.difficulty != .easy) return error.TestFailed;
    if (cfg.preferred_renderer != .ascii_ansi) return error.TestFailed;
    if (cfg.fallback_renderer != .ascii_ansi) return error.TestFailed;
}
