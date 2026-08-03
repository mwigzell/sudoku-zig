const std = @import("std");
const board = @import("board.zig");
const cell = @import("cell.zig");

// Re-export for facade users; defined in game_engine.zig
const AvailableCommands = @import("game_engine.zig").AvailableCommands;
const config = @import("config.zig");

/// How to start a new game. Returned by saveDialog/openDialog/getCommandInput when needed.
pub const NewGameChoice = union(enum) {
    Generated: config.Difficulty, // Easy/Medium/Hard picked from menu
    FromFile: []u8,       // Owned path from file picker
    FromUrl: []u8,         // Owned URL string
    PasteString: []u8,     // Raw puzzle string
    Cancelled,
};

/// Result of a save dialog interaction.
pub const SaveFileResult = union(enum) {
    FileName: []u8,       // Owned allocated filename to save to
    Cancelled,
};

pub const OpenFileResult = SaveFileResult;

/// Structured command input from the renderer's widget layer.
/// Terminal reads stdin text and parses it; WASM shows buttons/modals in DOM. Both return the same type.
pub const CommandInput = union(enum) {
    Fill: struct { row: usize, col: usize, digit: cell.CellValue },
    Clear: struct { row: usize, col: usize },
    Quit: void,
    Undo: void,
    Redo: void,
    Save: void,
    Open: []u8,                 // Owned path string (renderer already resolved through openDialog)
    NewGame: NewGameChoice,
};


/// Concrete error set for all Facade method signatures.
pub const RenderError = error{OutOfMemory, ReadEOF, UnexpectedEOF, WriteFault, FileNotFound, AccessDenied};

/// Vtable struct — dispatches through *anyopaque context to the concrete renderer.
pub const Facade = struct {
    context: *anyopaque

    render_fn:         fn (*anyopaque, board.Board.BoardView, ?[]const u8) RenderError!void,
    showLegend_fn:     fn (*anyopaque, AvailableCommands) RenderError!void,
    showError_fn:      fn (*anyopaque, []const u8) RenderError!void,
    saveDialog_fn:     fn (*anyopaque, []const u8, std.mem.Allocator) RenderError!SaveFileResult,
    openDialog_fn:     fn (*anyopaque, std.mem.Allocator) RenderError!OpenFileResult,
    newGameOptions_fn: fn (*anyopaque, std.mem.Allocator) RenderError!NewGameChoice,
    getCommandInput_fn:fn (*anyopaque, AvailableCommands, std.mem.Allocator) RenderError!CommandInput

    pub fn render(self: *Facade, view: board.Board.BoardView, status_msg: ?[]const u8) RenderError!void {
        return self.render_fn(self.context, view, status_msg);
    }

    pub fn showLegend(self: *Facade, commands: AvailableCommands) RenderError!void {
        return self.showLegend_fn(self.context, commands);
    }

    pub fn showError(self: *Facade, msg: []const u8) RenderError!void {
        return self.showError_fn(self.context, msg);
    }

    pub fn saveDialog(self: *Facade, default_name: []const u8, alloc: std.mem.Allocator) RenderError!SaveFileResult {
        return self.saveDialog_fn(self.context, default_name, alloc);
    }

    pub fn openDialog(self: *Facade, alloc: std.mem.Allocator) RenderError!OpenFileResult {
        return self.openDialog_fn(self.context, alloc);
    }

    pub fn newGameOptions(self: *Facade, alloc: std.mem.Allocator) RenderError!NewGameChoice {
        return self.newGameOptions_fn(self.context, alloc);
    }

    pub fn getCommandInput(self: *Facade, avail: AvailableCommands, alloc: std.mem.Allocator) RenderError!CommandInput {
        return self.getCommandInput_fn(self.context, avail, alloc);
    }
};

/// Auto-wraps any concrete renderer type into a Facade.
pub fn Make(comptime CT: type) type {
    return struct {

        pub fn render_wrapper(ctx: *anyopaque, view: board.Board.BoardView, status_msg: ?[]const u8) RenderError!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.render(view, status_msg);
        }

        pub fn showLegend_wrapper(ctx: *anyopaque, commands: AvailableCommands) RenderError!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.showLegend(commands);
        }

        pub fn showError_wrapper(ctx: *anyopaque, msg: []const u8) RenderError!void {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.showError(msg);
        }

        pub fn saveDialog_wrapper(ctx: *anyopaque, default_name: []const u8, alloc: std.mem.Allocator) RenderError!SaveFileResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.saveDialog(default_name, alloc);
        }

        pub fn openDialog_wrapper(ctx: *anyopaque, alloc: std.mem.Allocator) RenderError!OpenFileResult {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.openDialog(alloc);
        }

        pub fn newGameOptions_wrapper(ctx: *anyopaque, alloc: std.mem.Allocator) RenderError!NewGameChoice {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.newGameOptions(alloc);
        }

        pub fn getCommandInput_wrapper(ctx: *anyopaque, avail: AvailableCommands, alloc: std.mem.Allocator) RenderError!CommandInput {
            const self: *CT = @ptrCast(@alignCast(@constCast(ctx)));
            return self.getCommandInput(avail, alloc);
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
