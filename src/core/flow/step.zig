// Flow protocol: core issues steps, adapters carry each one out on their
// platform and report the result back as the next input.
const puzzle_gen = @import("../puzzle_gen/mod.zig");

/// A two-button question; `yes` in the answer means the user picked `ok_label`.
pub const Ask = struct {
    title: []const u8,
    text: []const u8,
    ok_label: []const u8,
    cancel_label: []const u8,
};

/// One thing for the adapter to do. `show_status`, `show_error` and `done` end the flow.
pub const Step = union(enum) {
    /// Report the platform's default save target name.
    resolve_default_target,
    /// Report whether the named target already exists for the user.
    check_target: []const u8,
    ask: Ask,
    /// Write the current game to the named target.
    write: []const u8,
    /// Read the saved game at this path and report its bytes.
    read_file: []const u8,
    /// Draw the current game with this status line; answered with `ack`.
    show_game: ShowGame,
    /// Generate a puzzle at this difficulty and report its one-line form.
    generate: puzzle_gen.Difficulty,
    /// Stop restoring this current file at startup; answered with `ack`.
    forget_current_file: ForgetCurrentFile,
    show_status: []const u8,
    show_error: []const u8,
    done,
};

/// What `show_game` puts on screen besides the board.
pub const ShowGame = struct {
    status: ?[]const u8,
    /// The working file to label the game with; null for an unsaved game.
    file: ?[]const u8,
};

/// The current file to forget, and whether to delete it from disk too.
pub const ForgetCurrentFile = struct {
    path: []const u8,
    delete: bool,
};

/// Outcome of a `read_file` step.
pub const FileRead = union(enum) {
    bytes: []const u8,
    failed: []const u8,
};

/// Outcome of a `generate` step.
pub const Generated = union(enum) {
    line: []const u8,
    /// The user stopped generation.
    cancelled,
    failed: []const u8,
};

/// Outcome of a `write` step.
pub const Wrote = union(enum) {
    /// Name of the target actually written (the platform may rename it).
    ok: []const u8,
    /// The user backed out of a platform picker.
    cancelled,
    failed: []const u8,
};

/// Adapter report for the step it just carried out.
pub const Input = union(enum) {
    start,
    default_target: []const u8,
    target_checked: bool,
    answered: bool,
    wrote: Wrote,
    file_read: FileRead,
    generated: Generated,
    /// The adapter finished a step that has no result.
    ack,
};

/// Shown when an adapter answers a step with the wrong kind of input.
pub const UNEXPECTED_INPUT_MSG = "The save could not finish because the app sent an unexpected answer.";
