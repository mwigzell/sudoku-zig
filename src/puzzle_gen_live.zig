// verify-slow entry shim — imports the slow generator properties from test/entry.
const _live = @import("test/entry/puzzle_gen_live.zig");

test {
    _ = _live;
}
