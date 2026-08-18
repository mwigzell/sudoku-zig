//! The .wasm artifact the native binary ships — embedded at compile time
//! so the web renderer needs no on-disk folder to serve.
//! build.zig emits hello.wasm next to this file (inside the package root,
//! which @embedFile may not escape).
const std = @import("std");

pub const wasm_bytes: []const u8 = @embedFile("hello.wasm");

test "embedded wasm artifact is non-empty" {
    try std.testing.expect(wasm_bytes.len > 8);
}

test "embedded wasm artifact starts with the wasm magic header" {
    const magic = [_]u8{ 0x00, 'a', 's', 'm' };
    try std.testing.expectEqualSlices(u8, &magic, wasm_bytes[0..4]);
}
