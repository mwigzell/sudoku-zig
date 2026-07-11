// Thin test-runner root for Zig 0.17 (addTest discovers from the root file).
// Imports each module so their co-located `test` blocks are reachable.
// In Zig 0.17, merely importing as `pub const` is not enough — the modules must
// be referenced in a way that compiles them into the test binary.
const std = @import("std");
const cell = @import("cell.zig");
const board = @import("board.zig");
const render = @import("render.zig");

// Sanity check: test blocks in THIS file (root) are always discovered.
test "sanity: test runner works" {
    std.debug.print("SANITY TEST RUNNING\n", .{});
    try std.testing.expect(true);
}

// Ensure co-located test blocks from imported modules compile in.
// Zig 0.17 dead-code-eliminates imports that aren't referenced.
test "references: cell, board, and render types (ensures co-located tests compile)" {
    _ = cell.Cell.init(.one);
    _ = board.Board.init();
    const ch = render.cellChar(cell.Cell.init(.three));
    _ = ch;
}

// --- printGrid test (lives here, not in render.zig, because std.Io
// restructured in 0.17) ---
test "render: printGrid renders with 3x3 box boundaries" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const b = board.Board.init(); // all empty / zero

    render.printGrid(&writer, b) catch |err| {
        std.debug.print("printGrid error: {s}\n", .{@errorName(err)});
        try std.testing.expect(false);
    };

    const actual = buf[0..writer.end];

    const expected = "+-----+-----+-----+\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "+-----+-----+-----+\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "+-----+-----+-----+\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "| . . . | . . . | . . . |\n"
        ++ "+-----+-----+-----+\n";

    std.debug.print("\n===== ACTUAL ({d} bytes) =====\n{s}===== END ACTUAL =====\n", .{ actual.len, actual });
    std.debug.print("\n===== EXPECTED ({d} bytes) =====\n{s}===== END EXPECTED =====\n", .{ expected.len, expected });

    try std.testing.expect(false); // FORCE FAIL: inspect actual vs expected above
}
