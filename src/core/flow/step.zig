// Flow protocol: core issues steps, adapters carry each one out on their
// platform and report the result back as the next input.
const puzzle_gen = @import("../puzzle_gen/mod.zig");
const config = @import("../config.zig");
const board = @import("../board/board.zig");
const legend_mod = @import("../renderer/legend.zig");
const game_engine = @import("../engine/game_engine.zig");
const event = @import("../event.zig");

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
    /// Write the current game (or, in an export flow, its puzzle line) to the named target.
    write: []const u8,
    /// Let the user pick the existing file the platform reported as taken, and write the game there; answered with `wrote`.
    pick_existing,
    /// Let the user choose a new file, suggesting this name, and write the game there; answered with `wrote`.
    pick_new: []const u8,
    /// Copy the current puzzle line where the user can paste it; answered with `copied`.
    copy_line,
    /// Read the saved game at this path and report its bytes.
    read_file: []const u8,
    /// Draw the current game with this status line; answered with `ack`.
    show_game: ShowGame,
    /// Generate a puzzle at this difficulty and report its one-line form.
    generate: puzzle_gen.Difficulty,
    /// Stop restoring this current file at startup; answered with `ack`.
    forget_current_file: ForgetCurrentFile,
    /// Store these player settings in `settings.json`.
    persist_settings: config.Config,
    show_status: []const u8,
    show_error: []const u8,
    done,
};

/// Everything the adapter draws for `show_game`, so it needs nothing else from the engine.
pub const ShowGame = struct {
    status: ?[]const u8,
    /// The working file to label the game with; null for an unsaved game.
    file: ?[]const u8,
    board: board.Board.BoardView,
    legend: legend_mod.Legend,
    config: config.Config,
    /// The cell the command edited, if any.
    cell: ?event.CellCoord = null,
};

/// The `show_game` step for the engine's current game.
pub fn showGame(engine: *game_engine.GameEngine, status: ?[]const u8, file: ?[]const u8) Step {
    return .{ .show_game = .{
        .status = status,
        .file = file,
        .board = engine.eventBoard(),
        .legend = engine.getLegend(),
        .config = engine.getConfig(),
    } };
}

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

/// Outcome of a step that either worked or failed with a reason (`persist_settings`, `copy_line`).
pub const Outcome = union(enum) {
    ok,
    failed: []const u8,
};

/// Outcome of a `write`, `pick_existing` or `pick_new` step.
pub const Wrote = union(enum) {
    /// Name of the target actually written (the platform may rename it).
    ok: []const u8,
    /// The user backed out of a platform picker.
    cancelled,
    /// The target exists but this install may not write it (an earlier install created it).
    taken: Taken,
    failed: []const u8,
};

/// The file a write could not use, and the folder it is in.
pub const Taken = struct {
    name: []const u8,
    dir: []const u8,
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
    persisted: Outcome,
    copied: Outcome,
    /// The adapter finished a step that has no result.
    ack,
};

/// Shown when an adapter answers a step with the wrong kind of input.
pub const UNEXPECTED_INPUT_MSG = "The save could not finish because the app sent an unexpected answer.";
