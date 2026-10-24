// Android logcat transport adapter: owns Android-specific tag + liblog call.
const std = @import("std");

extern fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

const android_log_identity: [*:0]const u8 = "sudoku-zig";

/// Cross-platform log identity mapped to Android logcat tag.
pub fn logIdentity() [*:0]const u8 {
    return android_log_identity;
}

/// Emit one already-formatted log line to Android logcat.
pub fn write(priority: c_int, line: [:0]const u8) void {
    _ = __android_log_write(priority, android_log_identity, line.ptr);
}

test "logcat adapter exports write symbol" {
    _ = @TypeOf(write);
}
