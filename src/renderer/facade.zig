const command = @import("../command.zig");
const config = @import("../config.zig");
const logger = @import("../logger.zig");
const board = @import("../board/board.zig");
const event = @import("../event.zig");
const legend = @import("legend.zig");
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
///     board change, or showError when a message is produced. The renderer
///     itself completes each interactive call (see the method docs).
///   * Borrowed arguments (view, commands, msg, names) are caller-owned;
///     a renderer must not retain them past the call.
///   * Live menu/settings labels cross only via scalar args on
///     getCommandInput (Sudoku passes engine config each turn). No bundled
///     pref types on the facade — see AGENTS.md “Native renderer facade seam”.
///   * The facade is caller-owned and dead after deinit.
pub const Facade = struct {
    context: *anyopaque,

    render_fn: *const fn (*anyopaque, board.Board.BoardView, ?[]const u8, ?Selection) Error!void,

    showLegend_fn: *const fn (*anyopaque, Legend) Error!void,

    showError_fn: *const fn (*anyopaque, []const u8) Error!void,

    getCommandInput_fn: *const fn (
        *anyopaque,
        []const []const u8,
        show_region: bool,
        warn_solvability: bool,
        difficulty: config.Difficulty,
        log_level: logger.Severity,
        theme: config.ViewTheme,
        hint_target: ?Selection,
    ) Error!command.ParseCommandResult,

    report_gen_progress_fn: *const fn (*anyopaque, puzzle_gen.GenProgressEvent) Error!void,

    deinit_fn: *const fn (*anyopaque) void,

    /// Draw the current board in full. When status_msg is non-null, renderers
    /// with a status surface draw it non-blocking (no input read); null ⇒ plain
    /// board.
    pub fn render(self: *const Facade, view: board.Board.BoardView, status_msg: ?[]const u8, selection: ?Selection) Error!void {
        return self.render_fn(self.context, view, status_msg, selection);
    }

    /// Draw the command legend for the caller-supplied available commands.
    pub fn showLegend(self: *const Facade, commands: Legend) Error!void {
        return self.showLegend_fn(self.context, commands);
    }

    /// Display an `.error_msg` and get user acknowledgement (interactive).
    /// `.ok.msg` status must not ride this channel — it goes through render's
    /// status_msg slot.
    pub fn showError(self: *const Facade, msg: []const u8) Error!void {
        return self.showError_fn(self.context, msg);
    }

    /// Show a prompt and get user command input, parsed against the offered
    /// command names. End-of-input reports as error.System.
    pub fn getCommandInput(
        self: *const Facade,
        names: []const []const u8,
        show_region: bool,
        warn_solvability: bool,
        difficulty: config.Difficulty,
        log_level: logger.Severity,
        theme: config.ViewTheme,
        hint_target: ?Selection,
    ) Error!command.ParseCommandResult {
        return self.getCommandInput_fn(self.context, names, show_region, warn_solvability, difficulty, log_level, theme, hint_target);
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
        pub fn render_wrapper(ctx: *anyopaque, view: board.Board.BoardView, status_msg: ?[]const u8, selection: ?Selection) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.render(view, status_msg, selection) catch return error.System;
        }
        pub fn showLegend_wrapper(ctx: *anyopaque, commands: Legend) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.showLegend(commands) catch return error.System;
        }
        pub fn showError_wrapper(ctx: *anyopaque, msg: []const u8) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.showError(msg) catch return error.System;
        }

        pub fn getCommandInput_wrapper(
            ctx: *anyopaque,
            names: []const []const u8,
            show_region: bool,
            warn_solvability: bool,
            difficulty: config.Difficulty,
            log_level: logger.Severity,
            theme: config.ViewTheme,
            hint_target: ?Selection,
        ) Error!command.ParseCommandResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.getCommandInput(names, show_region, warn_solvability, difficulty, log_level, theme, hint_target) catch error.System;
        }

        pub fn reportGenProgress_wrapper(ctx: *anyopaque, gen_event: puzzle_gen.GenProgressEvent) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.reportGenProgress(gen_event);
        }

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
                .showError_fn = showError_wrapper,
                .getCommandInput_fn = getCommandInput_wrapper,
                .report_gen_progress_fn = reportGenProgress_wrapper,
                .deinit_fn = deinit_wrapper,
            };
        }
    };
}
