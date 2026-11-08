const std = @import("std");
const builtin = @import("builtin");
const puzzle_gen = @import("puzzle_gen/mod.zig");
const logger = @import("logger.zig");

pub const Difficulty = puzzle_gen.Difficulty;

/// Renderer back-ends available to the native entry layer.
pub const RendererKind = enum { ansi, ascii, tui, web };

/// Presentation preference for UI shells.
pub const ViewTheme = enum { dark, light, system };

/// The test-only field's type: a bool in test builds, nothing (`void`, never saved) in the app.
const TestProbe = if (builtin.is_test) bool else void;

/// Renderer choice for one native run: set from the CLI, never saved.
pub const Renderers = struct {
    /// Tried first by the native Host.
    preferred: RendererKind,
    /// Tried when the preferred renderer cannot be constructed; null forbids a fallback.
    fallback: ?RendererKind,
};

/// The player's configuration. Every field except `renderers` is saved and editable in Settings.
pub const Config = struct {
    /// Puzzle generation difficulty for new games.
    difficulty: puzzle_gen.Difficulty,
    /// Renderer choice for this run (CLI only).
    renderers: Renderers,
    /// Runtime minimum log severity emitted by the Logger; defaults to .info.
    log_level: logger.Severity,
    /// Current UI theme preference.
    theme: ViewTheme = .system,
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
    /// Draw pencil marks. Hiding them never removes them.
    show_marks: bool = true,
    /// Exists only in test builds, to prove a new field needs no production code beyond this struct and the config table.
    test_probe: TestProbe = if (builtin.is_test) false else {},

    /// Hard-coded defaults — entry_native.zig supplies this to the Sudoku layer at init time.
    pub fn default() Config {
        return .{
            .difficulty = .easy,
            .renderers = .{ .preferred = .ansi, .fallback = .ansi },
            .log_level = .info,
        };
    }

    /// Is the field named `name` saved in `config.json`? All are but the CLI-only `renderers` and a `void` field.
    pub fn isSaved(comptime name: []const u8) bool {
        return !std.mem.eql(u8, name, "renderers") and @FieldType(Config, name) != void;
    }
};

test "config.default produces valid config" {
    const cfg = Config.default();
    if (cfg.difficulty != .easy) return error.TestFailed;
    if (cfg.renderers.preferred != .ansi) return error.TestFailed;
    if (cfg.renderers.fallback != .ansi) return error.TestFailed;
    if (cfg.theme != .system) return error.TestFailed;
    if (cfg.show_region) return error.TestFailed;
    if (cfg.warn_solvability) return error.TestFailed;
    if (cfg.auto_restore) return error.TestFailed;
    if (cfg.auto_new) return error.TestFailed;
    if (cfg.auto_save) return error.TestFailed;
    if (!cfg.show_marks) return error.TestFailed;
}
