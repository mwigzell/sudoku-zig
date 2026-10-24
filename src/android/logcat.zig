// Android logcat transport adapter: owns Android-specific tag + liblog call.
const std = @import("std");

extern fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

const android_tag: [*:0]const u8 = "sudoku-zig";

/// Logcat tag used for Android transport logs.
pub fn tag() [*:0]const u8 {
    return android_tag;
}

/// Emit one already-formatted log line to Android logcat.
pub fn write(priority: c_int, line: [:0]const u8) void {
    _ = __android_log_write(priority, android_tag, line.ptr);
}

test "logcat adapter exports write symbol" {
    _ = @TypeOf(write);
}
