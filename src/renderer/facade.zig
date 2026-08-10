const command = @import("../command.zig");
const board = @import("../board.zig");
const _legend = @import("../command/legend.zig");
const Legend = _legend.Legend;



/// Concrete error set for all Facade method signatures.
pub const Error = error{ OutOfMemory, ReadEOF, UnexpectedEOF, WriteFault, FileNotFound, AccessDenied };

/// Choice returned by new-game dialog options.
pub const NewGameChoice = enum { Generated, FromFile, FromUrl, PasteString };

/// Result of a new-game choice dialog. Wraps the positive selection with cancellation.
pub const NewGameChoiceResult = union(enum) {
    Choice: NewGameChoice,
    Cancelled,
};
/// Vtable struct — dispatches through *anyopaque context to the concrete renderer.
pub const Facade = struct {
    context: *anyopaque,

    render_fn: *const fn (*anyopaque, board.Board.BoardView, ?[]const u8) anyerror!void,

    showLegend_fn: *const fn (*anyopaque, Legend) anyerror!void,

    showError_fn: *const fn (*anyopaque, []const u8) anyerror!void,


    getCommandInput_fn: *const fn (*anyopaque, []const []const u8) anyerror!command.ParseCommandResult,

    pub fn render(self: *const Facade, view: board.Board.BoardView, status_msg: ?[]const u8) anyerror!void {
        return self.render_fn(self.context, view, status_msg);
    }

    pub fn showLegend(self: *const Facade, commands: Legend) anyerror!void {
        return self.showLegend_fn(self.context, commands);
    }

    pub fn showError(self: *const Facade, msg: []const u8) anyerror!void {
        return self.showError_fn(self.context, msg);
    }


    pub fn getCommandInput(self: *const Facade, names: []const []const u8) anyerror!command.ParseCommandResult {
        return self.getCommandInput_fn(self.context, names);
    }
};


/// Auto-wraps any concrete renderer type into a Facade.
pub fn Make(comptime CT: type) type {
    return struct {
        pub fn render_wrapper(ctx: *anyopaque, view: board.Board.BoardView, status_msg: ?[]const u8) anyerror!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.render(view, status_msg);
        }
        pub fn showLegend_wrapper(ctx: *anyopaque, commands: Legend) anyerror!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.showLegend(commands);
        }
        pub fn showError_wrapper(ctx: *anyopaque, msg: []const u8) anyerror!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.showError(msg);
        }

        pub fn getCommandInput_wrapper(ctx: *anyopaque, names: []const []const u8) anyerror!command.ParseCommandResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.getCommandInput(names);
        }

        /// Build a Facade pointing to the concrete renderer instance.
        pub fn make(instance: *CT) Facade {
            return Facade{
                .context = @ptrCast(@alignCast(instance)),
                .render_fn = render_wrapper,
                .showLegend_fn = showLegend_wrapper,
                .showError_fn = showError_wrapper,
                .getCommandInput_fn = getCommandInput_wrapper,
                };
        }
    };
}
