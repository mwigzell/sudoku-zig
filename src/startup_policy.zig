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
    restore_supported: bool,
};

/// Shared policy result: selected startup action plus any capability warning
/// the adapter should surface to the user.
pub const Decision = struct {
    action: Action,
    warn_restore_unavailable: bool,
};

/// Resolves startup precedence once:
/// restore (when requested + possible) -> new (when requested) -> idle.
pub fn evaluate(input: Input) Decision {
    if (input.auto_restore and input.has_current_file) {
        if (input.restore_supported) return .{ .action = .restore, .warn_restore_unavailable = false };
        return .{
            .action = if (input.auto_new) .new else .idle,
            .warn_restore_unavailable = true,
        };
    }
    if (input.auto_new) return .{ .action = .new, .warn_restore_unavailable = false };
    return .{ .action = .idle, .warn_restore_unavailable = false };
}

test "evaluate chooses restore when restore is enabled, supported, and path exists" {
    const d = evaluate(.{
        .auto_restore = true,
        .auto_new = true,
        .has_current_file = true,
        .restore_supported = true,
    });
    try std.testing.expectEqual(Action.restore, d.action);
    try std.testing.expect(!d.warn_restore_unavailable);
}

test "evaluate degrades to new with warning when restore unsupported and auto_new enabled" {
    const d = evaluate(.{
        .auto_restore = true,
        .auto_new = true,
        .has_current_file = true,
        .restore_supported = false,
    });
    try std.testing.expectEqual(Action.new, d.action);
    try std.testing.expect(d.warn_restore_unavailable);
}

test "evaluate degrades to idle with warning when restore unsupported and auto_new disabled" {
    const d = evaluate(.{
        .auto_restore = true,
        .auto_new = false,
        .has_current_file = true,
        .restore_supported = false,
    });
    try std.testing.expectEqual(Action.idle, d.action);
    try std.testing.expect(d.warn_restore_unavailable);
}

test "evaluate chooses new when restore is not selected" {
    const d = evaluate(.{
        .auto_restore = false,
        .auto_new = true,
        .has_current_file = false,
        .restore_supported = true,
    });
    try std.testing.expectEqual(Action.new, d.action);
    try std.testing.expect(!d.warn_restore_unavailable);
}
