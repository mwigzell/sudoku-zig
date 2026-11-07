// Flow protocol: core issues steps, adapters carry each one out on their
// platform and report the result back as the next input.
const std = @import("std");
const puzzle_gen = @import("../puzzle_gen/mod.zig");
const config = @import("../config.zig");
const legend_mod = @import("../renderer/legend.zig");
const game_engine = @import("../engine/game_engine.zig");
const frame_mod = @import("../frame.zig");

/// What a prompt is about; front ends mark it with its icon.
pub const MessageType = enum { information, warning, @"error" };

/// A message the player must acknowledge or answer; answered with `pressed`, the index of the button.
pub const PromptMessage = struct {
    type: MessageType,
    title: []const u8,
    text: []const u8,
    /// Left to right; the rightmost is the default.
    buttons: []const []const u8,
    /// The button that dismissing the prompt (Escape, Back, a tap outside) answers; null when only a button press answers.
    cancel: ?usize = null,

    /// The button dismissing answers: the named cancel button, or the only button; null when dismissing does nothing.
    pub fn dismissAnswer(self: PromptMessage) ?usize {
        if (self.cancel) |c| return c;
        if (self.buttons.len == 1) return 0;
        return null;
    }

    /// The rightmost button: focused, and chosen by Enter.
    pub fn defaultAnswer(self: PromptMessage) usize {
        return self.buttons.len - 1;
    }
};

pub const ERROR_TITLE: []const u8 = "Error";
pub const OK_LABEL: []const u8 = "OK";

/// The prompt for an error core reports: its title, the text, one OK button.
pub fn makeErrorPrompt(text: []const u8) PromptMessage {
    return .{ .type = .@"error", .title = ERROR_TITLE, .text = text, .buttons = &.{OK_LABEL} };
}

/// The step that shows an error; the flow ends once the player acknowledges it.
pub fn promptError(text: []const u8) Step {
    return .{ .prompt_message = makeErrorPrompt(text) };
}

/// Button indices of a `makeQuestion` prompt.
pub const QUESTION_CANCEL: usize = 0;
pub const QUESTION_OK: usize = 1;

/// A two-button question: `cancel_label` on the left (also what dismissing answers), `ok_label` on the right.
pub fn makeQuestion(
    message_type: MessageType,
    title: []const u8,
    text: []const u8,
    comptime ok_label: []const u8,
    comptime cancel_label: []const u8,
) Step {
    return .{ .prompt_message = .{
        .type = message_type,
        .title = title,
        .text = text,
        .buttons = &.{ cancel_label, ok_label },
        .cancel = QUESTION_CANCEL,
    } };
}

/// One thing for the adapter to do, named for the operation. `show_status` and `done` end the flow.
pub const Step = union(enum) {
    /// Report the platform's default save target name.
    resolve_default_target,
    /// Show this message and report the button the player pressed; answered with `pressed`.
    prompt_message: PromptMessage,
    /// Write the saved game to the current file (or a picker when none is bound), keep the restore copy, bind it; answered with `wrote`.
    save: GameWrite,
    /// Write the saved game to a file the player picks, suggesting this name (native: the typed path); answered with `wrote`.
    save_as: GameWrite,
    /// Write the saved game to the bound or default file, never through a picker; answered with `wrote`.
    autosave: GameWrite,
    /// The app is closing: write the saved game to the restore copy only; answered with `wrote`.
    flush: []const u8,
    /// Write the puzzle to this file; the current file is unchanged; answered with `wrote`.
    export_puzzle: []const u8,
    /// Let the player pick the file this install may not write, so it may write it again, and write the saved game there; answered with `wrote`.
    reclaim_file,
    /// Copy the puzzle to the clipboard (native: print it); answered with `copied`.
    copy_puzzle,
    /// Read the puzzle from the clipboard; answered with `read`.
    paste_puzzle,
    /// Read the saved game to restore at startup from this path; answered with `read`.
    restore: []const u8,
    /// Let the player choose a saved game, or read the path the command named; answered with `read`.
    open: ?[]const u8,
    /// Let the player choose a puzzle file, or read the path the command named; answered with `read`.
    import_puzzle: ?[]const u8,
    /// Draw the current game with this status line; answered with `ack`.
    show_game: ShowGame,
    /// Generate a puzzle at this difficulty and report it.
    generate_game: puzzle_gen.Difficulty,
    /// Stop restoring this current file at startup; answered with `ack`.
    forget_current_file: ForgetCurrentFile,
    /// Store these player settings in `settings.json`.
    persist_settings: config.Config,
    show_status: []const u8,
    done,
};

/// A saved-game write. Without `replace`, a write to a fixed file that is already there
/// answers `exists` and writes nothing; core then decides whether to replace it.
pub const GameWrite = struct {
    name: []const u8,
    replace: bool,
};

/// True once the flow has nothing more for the adapter to do.
pub fn isTerminal(s: Step) bool {
    return switch (s) {
        .show_status, .done => true,
        else => false,
    };
}

/// Everything the adapter draws for `show_game`, so it needs nothing else from the engine.
pub const ShowGame = struct {
    /// The board, status line, selection and mark display to draw.
    frame: frame_mod.Frame,
    /// The current file to label the game with; null for an unsaved game.
    file: ?[]const u8,
    legend: legend_mod.Legend,
    config: config.Config,
    /// The game was replaced (new, open, import, paste): rebind to `file`.
    loaded: bool = false,
};

/// The `show_game` step for the engine's current game.
pub fn showGame(engine: *game_engine.GameEngine, status: ?[]const u8, file: ?[]const u8) Step {
    return .{ .show_game = .{
        .frame = frame_mod.build(engine, status),
        .file = file,
        .legend = engine.getLegend(),
        .config = engine.getConfig(),
    } };
}

/// Outcome of a step that reads something (`open`, `import_puzzle`, `restore`, `paste_puzzle`).
pub const Read = union(enum) {
    file: ReadFile,
    /// The player backed out of the picker.
    cancelled,
    failed: []const u8,
};

/// What was read; `name` labels the game when it is a saved game.
pub const ReadFile = struct {
    bytes: []const u8,
    name: ?[]const u8 = null,
};

/// The current file to forget, and whether to delete it from disk too.
pub const ForgetCurrentFile = struct {
    path: []const u8,
    delete: bool,
};

/// Outcome of a `generate` step.
pub const Generated = union(enum) {
    line: []const u8,
    /// The user stopped generation.
    cancelled,
    failed: []const u8,
};

/// Outcome of a step that either worked or failed with a reason (`persist_settings`, `copy_puzzle`).
pub const Outcome = union(enum) {
    ok,
    failed: []const u8,
};

/// Outcome of a write step (`save`, `save_as`, `autosave`, `flush`, `export_puzzle`, `reclaim_file`).
pub const Wrote = union(enum) {
    /// Name of the target actually written (the platform may rename it).
    ok: []const u8,
    /// Nothing written: the fixed file is already there and the step did not allow replacing it.
    exists,
    /// The user backed out of a platform picker.
    cancelled,
    /// The target exists but this install may not write it (an earlier install created it, or its permission is gone).
    taken: Taken,
    failed: []const u8,
};

/// The file a write could not use.
pub const Taken = struct {
    name: []const u8,
};

/// Adapter report for the step it just carried out.
pub const Input = union(enum) {
    start,
    default_target: []const u8,
    /// Index of the button the player pressed on a `prompt_message`.
    pressed: usize,
    wrote: Wrote,
    read: Read,
    generated: Generated,
    persisted: Outcome,
    copied: Outcome,
    /// The adapter finished a step that has no result.
    ack,
};

/// Shown when an adapter answers a step with the wrong kind of input.
pub const UNEXPECTED_INPUT_MSG = "The command could not finish because the app sent an unexpected answer.";
/// Shown when the platform could not generate a puzzle; its reason goes to the log.
pub const GENERATE_FAILED_MSG = "A new game could not be generated.";

test "a prompt's default is the rightmost button, and dismissing answers its cancel button or its only button" {
    const three: PromptMessage = .{ .type = .warning, .title = "T", .text = "Q?", .buttons = &.{ "A", "B", "C" } };
    try std.testing.expectEqual(@as(usize, 2), three.defaultAnswer());
    try std.testing.expectEqual(@as(?usize, null), three.dismissAnswer());
    var named = three;
    named.cancel = 0;
    try std.testing.expectEqual(@as(?usize, 0), named.dismissAnswer());
    try std.testing.expectEqual(@as(?usize, 0), makeErrorPrompt("x").dismissAnswer());
}
