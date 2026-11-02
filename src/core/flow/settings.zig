// SettingsFlow: after a command that changes a player setting, ask the platform
// to persist the current settings.
const std = @import("std");
const config = @import("../config.zig");
const command = @import("../command.zig");
const step_mod = @import("step.zig");
const logger = @import("../logger.zig");

const log = logger.Logger(.flow);

const Step = step_mod.Step;
const Input = step_mod.Input;

/// Shown when the platform could not store the settings; its reason goes to the log.
pub const PERSIST_FAILED_MSG = "Your settings could not be saved.";

/// True when the command's change belongs in `settings.json`.
fn commandPersistsSettings(tag: command.CommandTag) bool {
    return switch (tag) {
        .set_theme, .toggle_region, .toggle_warn_solvability, .set_difficulty, .set_log_level => true,
        .toggle_auto_restore, .toggle_auto_new, .toggle_auto_save => true,
        .fill, .clear, .quit, .undo, .redo, .menu, .save, .open, .import, .@"export", .copy => false,
        .paste, .new, .save_as, .solve_for_me, .hint, .settings => false,
    };
}

pub const SettingsFlow = struct {
    cfg: config.Config,
    command: command.CommandTag,
    phase: Phase = .start,

    const Phase = enum { start, persisting, finished };

    /// Persist `cfg` after `tag` ran; skipped when the command changes no setting.
    pub fn afterCommand(cfg: config.Config, tag: command.CommandTag) SettingsFlow {
        return .{ .cfg = cfg, .command = tag };
    }

    /// Answer the last step; returns the next step (`.start` first).
    pub fn next(self: *SettingsFlow, input: Input) Step {
        switch (self.phase) {
            .start => {
                if (input != .start) return self.finish(.{ .show_error = step_mod.UNEXPECTED_INPUT_MSG });
                if (!commandPersistsSettings(self.command)) return self.finish(.done);
                self.phase = .persisting;
                return .{ .persist_settings = self.cfg };
            },
            .persisting => switch (input) {
                .persisted => |result| switch (result) {
                    .ok => return self.finish(.done),
                    .failed => |reason| {
                        log.err("settings save failed: {s}", .{reason});
                        return self.finish(.{ .show_error = PERSIST_FAILED_MSG });
                    },
                },
                else => return self.finish(.{ .show_error = step_mod.UNEXPECTED_INPUT_MSG }),
            },
            .finished => return .done,
        }
    }

    fn finish(self: *SettingsFlow, terminal: Step) Step {
        self.phase = .finished;
        return terminal;
    }
};

const testing = std.testing;

test "every settings command asks the platform to persist the current settings once" {
    var cfg = config.Config.default();
    cfg.theme = .light;
    for (std.enums.values(command.CommandTag)) |tag| {
        if (!commandPersistsSettings(tag)) continue;
        var flow = SettingsFlow.afterCommand(cfg, tag);
        const step = flow.next(.start);
        try testing.expectEqual(config.ViewTheme.light, step.persist_settings.theme);
        try testing.expect(flow.next(.{ .persisted = .ok }) == .done);
        try testing.expect(flow.next(.start) == .done);
    }
}

test "commands that change no setting persist nothing" {
    for ([_]command.CommandTag{ .fill, .undo, .new, .save, .quit }) |tag| {
        var flow = SettingsFlow.afterCommand(config.Config.default(), tag);
        try testing.expect(flow.next(.start) == .done);
    }
}

test "a persist failure shows core's sentence, not the platform's reason" {
    var flow = SettingsFlow.afterCommand(config.Config.default(), .set_theme);
    _ = flow.next(.start);
    try testing.expectEqualStrings(
        PERSIST_FAILED_MSG,
        flow.next(.{ .persisted = .{ .failed = "AccessDenied" } }).show_error,
    );
}

test "a wrong answer to persist_settings ends the flow with an error" {
    var flow = SettingsFlow.afterCommand(config.Config.default(), .toggle_region);
    _ = flow.next(.start);
    try testing.expectEqualStrings(step_mod.UNEXPECTED_INPUT_MSG, flow.next(.ack).show_error);
}

test "the flow must be started with start" {
    var flow = SettingsFlow.afterCommand(config.Config.default(), .toggle_region);
    try testing.expectEqualStrings(step_mod.UNEXPECTED_INPUT_MSG, flow.next(.ack).show_error);
}
