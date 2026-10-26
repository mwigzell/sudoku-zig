// Shared test-only startup/config baseline so tests opt in explicitly.
const config = @import("../core/config.zig");

/// Explicit test defaults independent of production constructor side effects.
pub fn testConfigDefaults() config.Config {
    return .{
        .difficulty = .easy,
        .preferred_renderer = .ansi,
        .fallback_renderer = .ansi,
        .log_level = .info,
        .theme = .system,
        .show_region = false,
        .warn_solvability = false,
        .auto_restore = false,
        .auto_new = false,
        .auto_save = false,
    };
}
