// Re-export command parsing types (moved Issue 29)
const command_parse = @import("../command/parse.zig");
pub const NewGameChoice = command_parse.NewGameChoice;
pub const NewGameChoiceResult = command_parse.NewGameChoiceResult;
pub const SaveFileResult = command_parse.SaveFileResult;
pub const OpenFileResult = command_parse.OpenFileResult;
pub const ParseCommandResult = command_parse.ParseCommandResult;
const board = @import("../board.zig");

// Re-export for facade users; defined in game_engine.zig
const AvailableCommands = @import("../game_engine.zig").AvailableCommands;

/// Concrete error set for all Facade method signatures.
pub const Error = error{ OutOfMemory, ReadEOF, UnexpectedEOF, WriteFault, FileNotFound, AccessDenied };

/// Vtable struct — dispatches through *anyopaque context to the concrete renderer.
pub const Facade = struct {
    context: *anyopaque,

    render_fn: *const fn (*anyopaque, board.Board.BoardView, ?[]const u8) Error!void,

    showLegend_fn: *const fn (*anyopaque, AvailableCommands) Error!void,

    showError_fn: *const fn (*anyopaque, []const u8) Error!void,

    saveDialog_fn: *const fn (*anyopaque, []const u8) Error!SaveFileResult,

    openDialog_fn: *const fn (*anyopaque) Error!OpenFileResult,

    newGameOptions_fn: *const fn (*anyopaque) Error!NewGameChoiceResult,

    getCommandInput_fn: *const fn (*anyopaque, AvailableCommands) Error!ParseCommandResult,

    pub fn render(self: *Facade, view: board.Board.BoardView, status_msg: ?[]const u8) Error!void {
        return self.render_fn(self.context, view, status_msg);
    }

    pub fn showLegend(self: *Facade, commands: AvailableCommands) Error!void {
        return self.showLegend_fn(self.context, commands);
    }

    pub fn showError(self: *Facade, msg: []const u8) Error!void {
        return self.showError_fn(self.context, msg);
    }

    pub fn saveDialog(self: *Facade, default_name: []const u8) Error!SaveFileResult {
        return self.saveDialog_fn(self.context, default_name);
    }

    pub fn openDialog(self: *Facade) Error!OpenFileResult {
        return self.openDialog_fn(self.context);
    }

    pub fn newGameOptions(self: *Facade) Error!NewGameChoiceResult {
        return self.newGameOptions_fn(self.context);
    }

    pub fn getCommandInput(self: *Facade, commands: AvailableCommands) Error!ParseCommandResult {
        return self.getCommandInput_fn(self.context, commands);
    }
};


/// Auto-wraps any concrete renderer type into a Facade.
pub fn Make(comptime CT: type) type {
    return struct {
        pub fn render_wrapper(ctx: *anyopaque, view: board.Board.BoardView, status_msg: ?[]const u8) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.render(view, status_msg);
        }
        pub fn showLegend_wrapper(ctx: *anyopaque, commands: AvailableCommands) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.showLegend(commands);
        }
        pub fn showError_wrapper(ctx: *anyopaque, msg: []const u8) Error!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.showError(msg);
        }
        pub fn saveDialog_wrapper(ctx: *anyopaque, default_name: []const u8) Error!SaveFileResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.saveDialog(default_name);
        }
        pub fn openDialog_wrapper(ctx: *anyopaque) Error!OpenFileResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.openDialog();
        }
        pub fn newGameOptions_wrapper(ctx: *anyopaque) Error!NewGameChoiceResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.newGameOptions();
        }

        pub fn getCommandInput_wrapper(ctx: *anyopaque, cmds: AvailableCommands) Error!ParseCommandResult {
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
                .saveDialog_fn = saveDialog_wrapper,
                .openDialog_fn = openDialog_wrapper,
                .newGameOptions_fn = newGameOptions_wrapper,
                .getCommandInput_fn = getCommandInput_wrapper,
                };
        }
    };
}
