//! Test root — imports all sub-modules so `addTest` discovers every co-located test block.
const cell = @import("cell.zig");
const board = @import("board.zig");
const board_serial = @import("board/serial.zig");
const board_conflict = @import("board/conflict.zig");


const game_engine = @import("engine/game_engine.zig");
const mock_renderer = @import("renderer/mock/mock_renderer.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const logger = @import("logger.zig");
const ascii_renderer = @import("renderer/ascii/ascii_renderer.zig");
const styler = @import("renderer/ascii/styler.zig");
const config = @import("config.zig");
const parse = @import("command/parse.zig");
const sudoku = @import("sudoku.zig");
const validator = @import("validator.zig");
const event = @import("event.zig");
const mutation_history = @import("engine/mutation_history.zig");
const disambiguate = @import("command/disambiguate.zig");
const legend = @import("command/legend.zig");
const path = @import("engine/path.zig");
const fill = @import("engine/fill.zig");
const clear_command = @import("engine/clear.zig");
const undo_command = @import("engine/undo.zig");
const redo_command = @import("engine/redo.zig");
const quit_command = @import("engine/quit.zig");
const save_command = @import("engine/save.zig");
const save_as_command = @import("engine/save_as.zig");
const open_command = @import("engine/open.zig");
const new_command = @import("engine/new.zig");
const input_source = @import("input_source.zig");


// You MUST enter module name in this test struct so that the reference pulls in the tests transitively
test {
    _ = .{
        cell, board, board_serial, board_conflict, game_engine,
        mock_renderer, puzzle_gen,
        logger, ascii_renderer, styler,
        config, parse, validator,
        sudoku, event, mutation_history, disambiguate, legend, path, fill, clear_command, undo_command, redo_command, quit_command, save_command, save_as_command, open_command, new_command,
    };
}
