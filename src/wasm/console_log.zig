// Wasm log sink: core's already-filtered log lines go to the JS shell (`glue.js` `sudoku_log`),
// which writes them to the console and the host log.
const std = @import("std");

extern "env" fn sudoku_log(level: u32, scope_ptr: [*]const u8, scope_len: usize, text_ptr: [*]const u8, text_len: usize) void;

/// Hand one line to the JS shell; `level` is the `logger.Severity` rank (debug 0 .. fatal 4).
pub fn write(level: u32, scope: []const u8, text: []const u8) void {
    sudoku_log(level, scope.ptr, scope.len, text.ptr, text.len);
}

test "wasm log sink exports write symbol" {
    _ = @TypeOf(write);
}
