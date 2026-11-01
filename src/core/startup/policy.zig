const std = @import("std");

/// Startup decision seam: the startup flow evaluates it once per launch on every platform.
pub const Action = enum {
    restore,
    new,
    idle,
};

/// Inputs required to evaluate startup behavior deterministically across
/// frontends: user policy flags, restore pointer presence, and capability.
pub const Input = struct {
    auto_restore: bool,
    auto_new: bool,
    has_current_file: bool,
};

/// The startup action the flow carries out.
pub const Decision = struct {
    action: Action,
};

/// Idle startup status shown by all frontends when startup policy selects
/// manual/idle mode.
pub const IDLE_STARTUP_STATUS: []const u8 = "Welcome to sudoku-zig! Choose New or Open to play.";

/// Resolves startup precedence once:
/// restore (when requested + possible) -> new (when requested) -> idle.
pub fn evaluate(input: Input) Decision {
    if (input.auto_restore and input.has_current_file) {
        return .{ .action = .restore };
    }
    if (input.auto_new) return .{ .action = .new };
    return .{ .action = .idle };
}

/// Question when restore lands on a solved board.
pub const RESTORE_SOLVED_TITLE: []const u8 = "Puzzle solved";
pub const RESTORE_SOLVED_PROMPT: []const u8 = "The restored puzzle is already solved. Do you want to start a new game?";
pub const RESTORE_SOLVED_OK_LABEL: []const u8 = "New game";
pub const RESTORE_SOLVED_CANCEL_LABEL: []const u8 = "Keep";

test "evaluate chooses restore when restore is enabled and path exists" {
    const d = evaluate(.{
        .auto_restore = true,
        .auto_new = true,
        .has_current_file = true,
    });
    try std.testing.expectEqual(Action.restore, d.action);
}

test "evaluate chooses new when restore is not selected" {
    const d = evaluate(.{
        .auto_restore = false,
        .auto_new = true,
        .has_current_file = false,
    });
    try std.testing.expectEqual(Action.new, d.action);
}

test "evaluate chooses idle when restore is requested but no file exists and auto_new is false" {
    const d = evaluate(.{
        .auto_restore = true,
        .auto_new = false,
        .has_current_file = false,
    });
    try std.testing.expectEqual(Action.idle, d.action);
}
