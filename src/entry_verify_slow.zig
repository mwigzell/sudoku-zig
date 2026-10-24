// Verify-slow entry: aggregates costly suites outside the fast verify path.
const _puzzle_gen_live = @import("test/slow/puzzle_gen_live.zig");

test {
    _ = _puzzle_gen_live;
}
