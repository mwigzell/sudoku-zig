const puzzle_gen = @import("puzzle_gen/mod.zig");
const logger = @import("logger.zig");

pub const Difficulty = puzzle_gen.Difficulty;

/// Renderer back-ends available to the native entry layer.
pub const RendererKind = enum { ansi, ascii, tui, web };

/// Light/dark presentation preference for the web shell.
pub const ViewTheme = enum { dark, light };

/// Nominal game configuration — preference + escape hatch.
pub const Config = struct {
    /// Puzzle generation difficulty for new games.
    difficulty: puzzle_gen.Difficulty,
    /// Preferred renderer type. If it fails at init, the native Host falls back here.
    preferred_renderer: RendererKind,
    /// Fallback tried when the preferred renderer cannot be constructed; "null" forbids the fallback.
    fallback_renderer: ?RendererKind,
    /// Runtime minimum log severity emitted by the Logger; defaults to .info.
    log_level: logger.Severity,
    /// Current UI theme preference.
    theme: ViewTheme = .dark,
    /// Region-highlight toggle around the active selection.
    show_region: bool = false,
    /// Proactive solvability warnings after moves and on load (single player toggle).
    warn_solvability: bool = false,
    /// Startup policy: attempt automatic restore from current-file metadata.
    auto_restore: bool = false,
    /// Startup policy: start a new game when no restore occurred.
    auto_new: bool = false,
    /// Save policy: write successful state-changing commands automatically.
    auto_save: bool = false,

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
    if (cfg.theme != .dark) return error.TestFailed;
    if (cfg.show_region) return error.TestFailed;
    if (cfg.warn_solvability) return error.TestFailed;
    if (cfg.auto_restore) return error.TestFailed;
    if (cfg.auto_new) return error.TestFailed;
    if (cfg.auto_save) return error.TestFailed;
}
