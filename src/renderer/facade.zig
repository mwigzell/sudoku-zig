const command = @import("../command.zig");
const board = @import("../board/board.zig");
const legend = @import("legend.zig");
const Legend = legend.Legend;

/// Concrete error set for all Facade method signatures.
pub const Error = error{System};

/// Options returned by new-game dialog.
pub const NewGameOptions = enum { Generated, FromFile, FromUrl, PasteString };

/// Result of a new-game options selection. Wraps the positive choice with cancellation.
pub const NewGameOptionsResult = union(enum) {
    Choice: NewGameOptions,
    Cancelled,
};
/// Vtable interface shared by all deployments (terminal, web): the loop
/// sees only these methods plus the renderer's error set collapsed to
/// error.System.
///
/// Contract:
///   * A turn = getCommandInput → dispatch → render + showLegend after a
///     board change, or showError when a message is produced. The renderer
///     itself completes each interactive call (see the method docs).
///   * Borrowed arguments (view, commands, msg, names) are caller-owned;
///     a renderer must not retain them past the call.
///   * The facade is caller-owned and dead after deinit.
pub const Facade = struct {
    context: *anyopaque,

    render_fn: *const fn (*anyopaque, board.Board.BoardView, ?[]const u8) Error!void,

    showLegend_fn: *const fn (*anyopaque, Legend) Error!void,

    showError_fn: *const fn (*anyopaque, []const u8) Error!void,

    getCommandInput_fn: *const fn (*anyopaque, []const []const u8) Error!command.ParseCommandResult,
    deinit_fn: *const fn (*anyopaque) void,

    /// Draw the current board in full. status_msg is a reserved status-bar
    /// slot; renderers may ignore it.
    pub fn render(self: *const Facade, view: board.Board.BoardView, status_msg: ?[]const u8) Error!void {
        return self.render_fn(self.context, view, status_msg);
    }

    /// Draw the command legend for the caller-supplied available commands.
    pub fn showLegend(self: *const Facade, commands: Legend) Error!void {
        return self.showLegend_fn(self.context, commands);
    }

    /// Display a message and get user acknowledgement.
    pub fn showError(self: *const Facade, msg: []const u8) Error!void {
        return self.showError_fn(self.context, msg);
    }

    /// Show a prompt and get user command input, parsed against the offered
    /// command names. End-of-input reports as error.System.
    pub fn getCommandInput(self: *const Facade, names: []const []const u8) Error!command.ParseCommandResult {
        return self.getCommandInput_fn(self.context, names);
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
        pub fn render_wrapper(ctx: *anyopaque, view: board.Board.BoardView, status_msg: ?[]const u8) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.render(view, status_msg) catch return error.System;
        }
        pub fn showLegend_wrapper(ctx: *anyopaque, commands: Legend) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.showLegend(commands) catch return error.System;
        }
        pub fn showError_wrapper(ctx: *anyopaque, msg: []const u8) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            self.showError(msg) catch return error.System;
        }

        pub fn getCommandInput_wrapper(ctx: *anyopaque, names: []const []const u8) Error!command.ParseCommandResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.getCommandInput(names) catch error.System;
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
                .deinit_fn = deinit_wrapper,
            };
        }
    };
}
