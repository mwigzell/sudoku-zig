const command = @import("../command.zig");
const config = @import("../config.zig");
const logger = @import("../logger.zig");
const board = @import("../board/board.zig");
const event = @import("../event.zig");
const legend = @import("legend.zig");
const flow_step = @import("../flow/step.zig");
const puzzle_gen = @import("../puzzle_gen/mod.zig");
const Legend = legend.Legend;

/// Row/col passed into render for native region highlight; null ⇒ no shading.
pub const Selection = event.CellCoord;

/// Concrete error set for all Facade method signatures.
pub const Error = error{System};

/// Native terminal renderer vtable: `Sudoku` and `AsciiRenderer` use this loop.
/// Browser play uses wasm JSON exports + JS DOM (ADR-0010) — not this type.
/// A future Zig web/canvas renderer would implement the same shape if added.
///
/// The loop sees only these methods plus the renderer's error set collapsed to
/// `error.System`.
///
/// Contract:
///   * A turn = getCommandInput → dispatch → render + showLegend after a
///     board change, or promptMessage when a message is produced. The renderer
///     itself completes each interactive call (see the method docs).
///   * Borrowed arguments (view, commands, msg, names) are caller-owned;
///     a renderer must not retain them past the call.
///   * Live menu/settings labels cross only via scalar args on
///     getCommandInput (Sudoku passes engine config each turn). No bundled
///     pref types on the facade — see AGENTS.md “Native renderer facade seam”.
///   * The facade is caller-owned and dead after deinit.
pub const Facade = struct {
    context: *anyopaque,

    render_fn: *const fn (*anyopaque, board.Board.BoardView, ?[]const u8, ?Selection, bool) Error!void,

    showLegend_fn: *const fn (*anyopaque, Legend) Error!void,

    promptMessage_fn: *const fn (*anyopaque, flow_step.PromptMessage) Error!usize,

    getCommandInput_fn: *const fn (
        *anyopaque,
        []const []const u8,
        show_region: bool,
        show_marks: bool,
        warn_solvability: bool,
        difficulty: config.Difficulty,
        log_level: logger.Severity,
        theme: config.ViewTheme,
        auto_restore: bool,
        auto_new: bool,
        auto_save: bool,
        hint_target: ?Selection,
    ) Error!command.ParseCommandResult,

    report_gen_progress_fn: *const fn (*anyopaque, puzzle_gen.GenProgressEvent) Error!void,

    deinit_fn: *const fn (*anyopaque) void,

    /// Draw the current board in full. When status_msg is non-null, renderers
    /// with a status surface draw it non-blocking (no input read); null ⇒ plain
    /// board. marks_visible is core's choice of the board with pencil marks.
    pub fn render(self: *const Facade, view: board.Board.BoardView, status_msg: ?[]const u8, selection: ?Selection, marks_visible: bool) Error!void {
        return self.render_fn(self.context, view, status_msg, selection, marks_visible);
    }

    /// Draw the command legend for the caller-supplied available commands.
    pub fn showLegend(self: *const Facade, commands: Legend) Error!void {
        return self.showLegend_fn(self.context, commands);
    }

    /// Show a message the player must acknowledge or answer (an error, a question) and return
    /// the index of the button they pressed (interactive). Status lines ride render's status_msg slot.
    pub fn promptMessage(self: *const Facade, prompt: flow_step.PromptMessage) Error!usize {
        return self.promptMessage_fn(self.context, prompt);
    }

    /// Show a prompt and get user command input, parsed against the offered
    /// command names. End-of-input reports as error.System.
    pub fn getCommandInput(
        self: *const Facade,
        names: []const []const u8,
        show_region: bool,
        show_marks: bool,
        warn_solvability: bool,
        difficulty: config.Difficulty,
        log_level: logger.Severity,
        theme: config.ViewTheme,
        auto_restore: bool,
        auto_new: bool,
        auto_save: bool,
        hint_target: ?Selection,
    ) Error!command.ParseCommandResult {
        return self.getCommandInput_fn(self.context, names, show_region, show_marks, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target);
    }

    /// Live puzzle generation feedback (native terminal); not gameplay `Event` status.
    pub fn reportGenProgress(self: *const Facade, gen_event: puzzle_gen.GenProgressEvent) Error!void {
        return self.report_gen_progress_fn(self.context, gen_event);
    }

    /// Release all renderer-owned memory — the renderer owns its teardown path
    /// (e.g. self-destroy). The facade is unusable afterwards.
    pub fn deinit(self: *Facade) void {
        self.deinit_fn(self.context);
    }
};

/// Auto-wraps any concrete renderer type into a Facade.
pub fn Make(comptime CT: type) type {
    return struct {
        /// Forward `render` through erased context to the concrete renderer.
        pub fn render_wrapper(ctx: *anyopaque, view: board.Board.BoardView, status_msg: ?[]const u8, selection: ?Selection, marks_visible: bool) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.render(view, status_msg, selection, marks_visible) catch return error.System;
        }
        /// Forward `showLegend` through erased context to the concrete renderer.
        pub fn showLegend_wrapper(ctx: *anyopaque, commands: Legend) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.showLegend(commands) catch return error.System;
        }
        /// Forward `promptMessage` through erased context to the concrete renderer.
        pub fn promptMessage_wrapper(ctx: *anyopaque, prompt: flow_step.PromptMessage) Error!usize {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.promptMessage(prompt) catch return error.System;
        }

        /// Forward `getCommandInput` through erased context with live prefs args.
        pub fn getCommandInput_wrapper(
            ctx: *anyopaque,
            names: []const []const u8,
            show_region: bool,
            show_marks: bool,
            warn_solvability: bool,
            difficulty: config.Difficulty,
            log_level: logger.Severity,
            theme: config.ViewTheme,
            auto_restore: bool,
            auto_new: bool,
            auto_save: bool,
            hint_target: ?Selection,
        ) Error!command.ParseCommandResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.getCommandInput(names, show_region, show_marks, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target) catch error.System;
        }

        /// Forward generator progress events through the facade seam.
        pub fn reportGenProgress_wrapper(ctx: *anyopaque, gen_event: puzzle_gen.GenProgressEvent) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.reportGenProgress(gen_event);
        }

        /// Forward teardown through erased context to the concrete renderer.
        pub fn deinit_wrapper(ctx: *anyopaque) void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.deinit();
        }

        /// Build a Facade pointing to the concrete renderer instance.
        pub fn make(instance: *CT) Facade {
            return Facade{
                .context = @ptrCast(@alignCast(instance)),
                .render_fn = render_wrapper,
                .showLegend_fn = showLegend_wrapper,
                .promptMessage_fn = promptMessage_wrapper,
                .getCommandInput_fn = getCommandInput_wrapper,
                .report_gen_progress_fn = reportGenProgress_wrapper,
                .deinit_fn = deinit_wrapper,
            };
        }
    };
}
