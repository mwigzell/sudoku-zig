const std = @import("std");

/// Shared startup policy decision seam: both native and web evaluate the same
/// flags/capabilities and then execute the chosen action in platform adapters.
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

/// Shared policy result: selected startup action plus any capability warning
/// the adapter should surface to the user.
pub const Decision = struct {
    action: Action,
};

/// Idle startup status shown by all frontends when startup policy selects
/// manual/idle mode.
pub const IDLE_STARTUP_STATUS: []const u8 = "Welcome to sudoku-zig! Choose New or Open to play";

/// Resolves startup precedence once:
/// restore (when requested + possible) -> new (when requested) -> idle.
pub fn evaluate(input: Input) Decision {
    if (input.auto_restore and input.has_current_file) {
        return .{ .action = .restore };
    }
    if (input.auto_new) return .{ .action = .new };
    return .{ .action = .idle };
}

/// Shared startup-status message for the selected action.
/// Restore/new are surfaced by command events; idle gets an explicit startup line.
pub fn statusForAction(action: Action) ?[]const u8 {
    return switch (action) {
        .idle => IDLE_STARTUP_STATUS,
        .restore, .new => null,
    };
}

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

test "statusForAction returns idle startup status only for idle action" {
    try std.testing.expectEqualStrings(IDLE_STARTUP_STATUS, statusForAction(.idle).?);
    try std.testing.expect(statusForAction(.restore) == null);
    try std.testing.expect(statusForAction(.new) == null);
}
