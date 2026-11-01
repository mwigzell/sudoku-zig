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
    "hint",
    "solve",
    "solve_for_me",
    "open",
    "import",
    "paste",
};

/// Replace question asked before overwriting an existing file; `{s}` is the file name.
pub const REPLACE_CONFIRM_TITLE: []const u8 = "Replace file?";
pub const REPLACE_CONFIRM_FMT = "The file {s} already exists. Do you want to replace it?";
pub const REPLACE_CONFIRM_OK_LABEL: []const u8 = "Replace";
pub const REPLACE_CONFIRM_CANCEL_LABEL: []const u8 = "Cancel";

/// Status after the user declines to replace a file on Save / Save As.
pub const WRITE_CANCELLED_MSG: []const u8 = "cancelled";
/// Status after a successful Save / Save As; `{s}` is the written target.
pub const SAVED_TO_FMT = "saved to: {s}";
/// Question when the platform's autosave file was created by an earlier install; `{s}` are the file and its folder.
pub const TAKEN_TITLE: []const u8 = "Autosave file";
pub const TAKEN_FMT = "The file {s} in {s} was saved by an earlier install. Pick it to keep autosaving there, or choose a new name.";
pub const TAKEN_PICK_LABEL: []const u8 = "Pick it";
pub const TAKEN_NEW_NAME_LABEL: []const u8 = "New name";

/// Status when the player asks to Save while autosave is on.
pub const SAVE_WHILE_AUTO_SAVE_MSG: []const u8 = "Auto Save is on, so your game is already saved.";

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

/// Where an autosave writes; adapters resolve `default_visible` to their platform's user-visible location.
pub const AutoSaveTarget = enum {
    working_file,
    default_visible,
};

/// Autosave target inputs gathered by the adapter.
pub const AutoSaveTargetInput = struct {
    has_working_file: bool,
};

/// Autosave follows the working file; with none, it writes the default visible file (which then becomes the working file).
pub fn autoSaveTarget(input: AutoSaveTargetInput) AutoSaveTarget {
    return if (input.has_working_file) .working_file else .default_visible;
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

test "autosave targets the default visible file when there is no working file" {
    try std.testing.expectEqual(AutoSaveTarget.default_visible, autoSaveTarget(.{ .has_working_file = false }));
}

test "autosave targets the working file when one exists" {
    try std.testing.expectEqual(AutoSaveTarget.working_file, autoSaveTarget(.{ .has_working_file = true }));
}

test "commandTriggersAutoSaveByName follows shared trigger set" {
    const should_trigger = [_][]const u8{ "fill", "undo", "hint", "solve", "open", "paste" };
    for (should_trigger) |name| {
        try std.testing.expect(commandTriggersAutoSaveByName(name));
    }
    try std.testing.expect(!commandTriggersAutoSaveByName("save_as"));
}

test "file prompts read as sentences that start with words, not the file name" {
    const sentence = @import("../test/sentence.zig");
    var buf: [256]u8 = undefined;
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, REPLACE_CONFIRM_FMT, .{"game.sud"}));
    try sentence.expectSentence(try std.fmt.bufPrint(&buf, TAKEN_FMT, .{ "sudoku.sud", "Documents" }));
    try sentence.expectSentence(SAVE_WHILE_AUTO_SAVE_MSG);
}
