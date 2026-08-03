//! Test root — imports all sub-modules so `addTest` discovers every co-located test block.
const cell = @import("cell.zig");
const board = @import("board.zig");
const game_engine = @import("game_engine.zig");
const mock_renderer = @import("mock_renderer.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const logger = @import("logger.zig");
const ascii_renderer = @import("ascii_renderer.zig");
const styler = @import("styler.zig");
const config = @import("config.zig");
const parse = @import("command/parse.zig");
const sudoku = @import("sudoku.zig");
const validator = @import("validator.zig");
const event = @import("event.zig");
const mutation_history = @import("command/mutation_history.zig");
const disambiguate = @import("command/disambiguate.zig");
const legend = @import("command/legend.zig");
const path = @import("command/path.zig");
const fill = @import("command/fill.zig");
const clear_command = @import("command/clear.zig");
const undo_command = @import("command/undo.zig");
const redo_command = @import("command/redo.zig");
const quit_command = @import("command/quit.zig");
const save_command = @import("command/save.zig");
const open_command = @import("command/open.zig");


// You MUST enter module name in this test struct so that the reference pulls in the tests transitively
test {
    _ = .{
        cell, board, game_engine,
        mock_renderer, puzzle_gen,
        logger, ascii_renderer, styler,
        config, parse, validator,
        sudoku, event, mutation_history, disambiguate, legend, path, fill, clear_command, undo_command, redo_command, quit_command, save_command, open_command,
    };
}
