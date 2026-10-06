const std = @import("std");

/// Shared write-intent categories for save persistence paths.
pub const WriteIntent = enum {
    save,
    save_as,
    auto_save,
};

/// Shared overwrite decision returned to platform adapters.
pub const OverwriteDecision = enum {
    write,
    require_replace_confirm,
};

/// Shared write-lane state:
/// - continuation: writing the current active lane (no replace prompt for existing target)
/// - detached: first write after lane reset/new context (existing target requires confirm)
pub const WriteContext = enum {
    continuation,
    detached,
};

/// Lifecycle events that drive overwrite-context transitions across seams.
pub const WriteContextEvent = enum {
    startup_restore,
    startup_new,
    startup_idle,
    open_success,
    save_success,
    save_as_success,
    auto_save_success,
    new_game_success,
    import_success,
    paste_success,
};

/// Canonical command names that trigger auto-save across platform seams.
pub const AUTO_SAVE_TRIGGER_COMMANDS = [_][]const u8{
    "fill",
    "clear",
    "undo",
    "redo",
    "solve",
    "solve_for_me",
    "open",
    "import",
    "paste",
};

/// Wire JSON for host startup payload; used by web adapters to avoid local trigger lists.
pub const AUTO_SAVE_TRIGGER_COMMANDS_JSON: []const u8 =
    "[\"fill\",\"clear\",\"undo\",\"redo\",\"solve\",\"solve_for_me\",\"open\",\"import\",\"paste\"]";

/// User-facing replace confirmation copy used by all write seams.
pub const REPLACE_CONFIRM_MSG: []const u8 = "file already exists, replace?";

/// Shared overwrite-policy inputs:
pub const OverwriteInput = struct {
    intent: WriteIntent,
    target_exists: bool,
    write_context: WriteContext,
};

/// Central overwrite policy:
/// - writes to missing targets never prompt
/// - continuation writes to existing targets do not prompt
/// - detached writes to existing targets require explicit replace confirm
pub fn evaluateOverwritePolicy(input: OverwriteInput) OverwriteDecision {
    _ = input.intent;
    if (!input.target_exists) return .write;
    if (input.write_context == .continuation) return .write;
    return .require_replace_confirm;
}

/// Maps a lifecycle event to the next overwrite context used by save policy.
pub fn nextWriteContext(current: WriteContext, event: WriteContextEvent) WriteContext {
    _ = current;
    return switch (event) {
        .startup_restore, .open_success, .save_success, .save_as_success, .auto_save_success => .continuation,
        .startup_new, .startup_idle, .new_game_success, .import_success, .paste_success => .detached,
    };
}

/// Parses a text event name from host/web adapters into a write-context event.
pub fn parseWriteContextEvent(name: []const u8) ?WriteContextEvent {
    if (std.mem.eql(u8, name, "startup_restore")) return .startup_restore;
    if (std.mem.eql(u8, name, "startup_new")) return .startup_new;
    if (std.mem.eql(u8, name, "startup_idle")) return .startup_idle;
    if (std.mem.eql(u8, name, "open_success")) return .open_success;
    if (std.mem.eql(u8, name, "save_success")) return .save_success;
    if (std.mem.eql(u8, name, "save_as_success")) return .save_as_success;
    if (std.mem.eql(u8, name, "auto_save_success")) return .auto_save_success;
    if (std.mem.eql(u8, name, "new_game_success")) return .new_game_success;
    if (std.mem.eql(u8, name, "import_success")) return .import_success;
    if (std.mem.eql(u8, name, "paste_success")) return .paste_success;
    return null;
}

/// Returns true when the command name should trigger auto-save policy.
pub fn commandTriggersAutoSaveByName(name: []const u8) bool {
    for (AUTO_SAVE_TRIGGER_COMMANDS) |trigger| {
        if (std.mem.eql(u8, name, trigger)) return true;
    }
    return false;
}

test "overwrite policy requires confirm for every intent when target exists" {
    const intents = [_]WriteIntent{ .save, .save_as, .auto_save };
    for (intents) |intent| {
        try std.testing.expectEqual(OverwriteDecision.require_replace_confirm, evaluateOverwritePolicy(.{
            .intent = intent,
            .target_exists = true,
            .write_context = .detached,
        }));
    }
}

test "overwrite policy allows write for every intent when target does not exist" {
    const intents = [_]WriteIntent{ .save, .save_as, .auto_save };
    for (intents) |intent| {
        try std.testing.expectEqual(OverwriteDecision.write, evaluateOverwritePolicy(.{
            .intent = intent,
            .target_exists = false,
            .write_context = .detached,
        }));
    }
}

test "overwrite policy allows continuation write for existing target" {
    const intents = [_]WriteIntent{ .save, .save_as, .auto_save };
    for (intents) |intent| {
        try std.testing.expectEqual(OverwriteDecision.write, evaluateOverwritePolicy(.{
            .intent = intent,
            .target_exists = true,
            .write_context = .continuation,
        }));
    }
}

test "nextWriteContext maps restore/open/save events to continuation" {
    const continuation_events = [_]WriteContextEvent{
        .startup_restore,
        .open_success,
        .save_success,
        .save_as_success,
        .auto_save_success,
    };
    for (continuation_events) |event| {
        try std.testing.expectEqual(WriteContext.continuation, nextWriteContext(.detached, event));
    }
}

test "nextWriteContext maps new/import/paste/idle events to detached" {
    const detached_events = [_]WriteContextEvent{
        .startup_new,
        .startup_idle,
        .new_game_success,
        .import_success,
        .paste_success,
    };
    for (detached_events) |event| {
        try std.testing.expectEqual(WriteContext.detached, nextWriteContext(.continuation, event));
    }
}

test "commandTriggersAutoSaveByName follows shared trigger set" {
    const should_trigger = [_][]const u8{ "fill", "undo", "solve", "open", "paste" };
    for (should_trigger) |name| {
        try std.testing.expect(commandTriggersAutoSaveByName(name));
    }
    try std.testing.expect(!commandTriggersAutoSaveByName("hint"));
    try std.testing.expect(!commandTriggersAutoSaveByName("save_as"));
}
