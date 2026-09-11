// Portable game state: the board plus mutation history — no deployments, no I/O.
const board_mod = @import("../board/board.zig");
const mutation_history = @import("mutation_history.zig");

pub const State = struct {
    board: board_mod.Board,
    history: mutation_history.MutationHistory,
};

// Io-free codec round-trip over State (seam: save_format takes/returns State)
const save_format = @import("save_format.zig");
const puzzle_gen = @import("../puzzle_gen.zig");
const std = @import("std");

test "State codec: toSaveFormat/fromSaveFormat round-trip without std.Io" {
    const gpa = std.testing.allocator;
    const brd = try board_mod.fromOneLineString(puzzle_gen.PuzzleGen.default());
    var state = State{ .board = brd, .history = mutation_history.MutationHistory.init(gpa) };
    defer state.history.deinit();

    const buf = try save_format.toSaveFormat(&state, gpa);
    defer gpa.free(buf);

    var loaded = try save_format.fromSaveFormat(gpa, buf);
    defer loaded.history.deinit();
    try std.testing.expectEqual(state.history.pointer, loaded.history.pointer);
}
