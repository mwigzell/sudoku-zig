// Re-export command parsing types (moved Issue 29)
const command_parse = @import("../command/parse.zig");
pub const SaveFileResult = command_parse.SaveFileResult;
pub const OpenFileResult = command_parse.OpenFileResult;
pub const ParseCommandResult = command_parse.ParseCommandResult;
pub const PuzzleReturn = union(enum) {
    PuzzleString: []u8,  // Owned puzzle string — renderer decides source
    Cancelled,
};
const board = @import("../board.zig");

// Re-export for facade users; defined in game_engine.zig
const AvailableCommands = @import("../game_engine.zig").AvailableCommands;

/// Concrete error set for all Facade method signatures.
pub const Error = error{ OutOfMemory, ReadEOF, UnexpectedEOF, WriteFault, FileNotFound, AccessDenied };

/// Vtable struct — dispatches through *anyopaque context to the concrete renderer.
pub const Facade = struct {
    context: *anyopaque,

    render_fn: *const fn (*anyopaque, board.Board.BoardView, ?[]const u8) anyerror!void,

    showLegend_fn: *const fn (*anyopaque, AvailableCommands) anyerror!void,

    showError_fn: *const fn (*anyopaque, []const u8) anyerror!void,


    openDialog_fn: *const fn (*anyopaque) anyerror!OpenFileResult,

    newGameOptions_fn: *const fn (*anyopaque) anyerror!PuzzleReturn,

    getCommandInput_fn: *const fn (*anyopaque, AvailableCommands) anyerror!ParseCommandResult,

    pub fn render(self: *const Facade, view: board.Board.BoardView, status_msg: ?[]const u8) anyerror!void {
        return self.render_fn(self.context, view, status_msg);
    }

    pub fn showLegend(self: *const Facade, commands: AvailableCommands) anyerror!void {
        return self.showLegend_fn(self.context, commands);
    }

    pub fn showError(self: *const Facade, msg: []const u8) anyerror!void {
        return self.showError_fn(self.context, msg);
    }


    pub fn openDialog(self: *const Facade) anyerror!OpenFileResult {
        return self.openDialog_fn(self.context);
    }

    pub fn newGameOptions(self: *const Facade) anyerror!PuzzleReturn {
        return self.newGameOptions_fn(self.context);
    }

    pub fn getCommandInput(self: *const Facade, commands: AvailableCommands) anyerror!ParseCommandResult {
        return self.getCommandInput_fn(self.context, commands);
    }
};


/// Auto-wraps any concrete renderer type into a Facade.
pub fn Make(comptime CT: type) type {
    return struct {
        pub fn render_wrapper(ctx: *anyopaque, view: board.Board.BoardView, status_msg: ?[]const u8) anyerror!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.render(view, status_msg);
        }
        pub fn showLegend_wrapper(ctx: *anyopaque, commands: AvailableCommands) anyerror!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.showLegend(commands);
        }
        pub fn showError_wrapper(ctx: *anyopaque, msg: []const u8) anyerror!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.showError(msg);
        }
        pub fn openDialog_wrapper(ctx: *anyopaque) anyerror!OpenFileResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.openDialog();
        }
        pub fn newGameOptions_wrapper(ctx: *anyopaque) anyerror!PuzzleReturn {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.newGameOptions();
        }

        pub fn getCommandInput_wrapper(ctx: *anyopaque, cmds: AvailableCommands) anyerror!ParseCommandResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.getCommandInput(cmds);
        }

        /// Build a Facade pointing to the concrete renderer instance.
        pub fn make(instance: *CT) Facade {
            return Facade{
                .context = @ptrCast(@alignCast(instance)),
                .render_fn = render_wrapper,
                .showLegend_fn = showLegend_wrapper,
                .showError_fn = showError_wrapper,
                .openDialog_fn = openDialog_wrapper,
                .newGameOptions_fn = newGameOptions_wrapper,
                .getCommandInput_fn = getCommandInput_wrapper,
                };
        }
    };
}
