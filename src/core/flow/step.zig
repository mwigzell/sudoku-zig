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

/// One thing for the adapter to do, named for the operation. `show_status`, `show_error` and `done` end the flow.
pub const Step = union(enum) {
    /// Report the platform's default save target name.
    resolve_default_target,
    ask: Ask,
    /// Write the saved game to the working file (or a picker when none is bound), keep the restore copy, bind it; answered with `wrote`.
    save: GameWrite,
    /// Write the saved game to a file the player picks, suggesting this name (native: the typed path); answered with `wrote`.
    save_as: GameWrite,
    /// Write the saved game to the bound or default file, never through a picker; answered with `wrote`.
    autosave: GameWrite,
    /// The app is closing: write the saved game to the restore copy only; answered with `wrote`.
    flush: []const u8,
    /// Write the puzzle to this file; the working file is unchanged; answered with `wrote`.
    export_puzzle: []const u8,
    /// Let the player pick the file an earlier install wrote, so this install may write it again, and write the saved game there; answered with `wrote`.
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
    show_error: []const u8,
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
        .show_status, .show_error, .done => true,
        else => false,
    };
}

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
    /// The game was replaced (new, open, import, paste): drop the selection and rebind to `file`.
    loaded: bool = false,
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
    answered: bool,
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
