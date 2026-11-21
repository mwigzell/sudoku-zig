// Verify-slow entry: aggregates costly suites outside the fast verify path.
const _puzzle_gen_live = @import("test/slow/puzzle_gen_live.zig");
const _core_e2e = @import("test/slow/core_e2e.zig");

test {
    _ = _puzzle_gen_live;
    _ = _core_e2e;
}
