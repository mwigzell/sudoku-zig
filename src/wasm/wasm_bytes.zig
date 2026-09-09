//! The .wasm artifact the native binary ships — embedded at compile time
//! so the web renderer needs no on-disk folder to serve.
//! build.zig emits artifact.wasm next to this file (inside the package root,
//! which @embedFile may not escape).
const std = @import("std");

pub const wasm_bytes: []const u8 = @embedFile("artifact.wasm");
pub const page_html: []const u8 = @embedFile("page.html");
pub const glue_js: []const u8 = @embedFile("glue.js");

test "embedded wasm artifact is non-empty" {
    try std.testing.expect(wasm_bytes.len > 8);
}

test "embedded page.html is non-empty" {
    try std.testing.expect(page_html.len > 0);
}

test "embedded glue.js is non-empty" {
    try std.testing.expect(glue_js.len > 0);
}

test "embedded wasm artifact starts with the wasm magic header" {
    const magic = [_]u8{ 0x00, 'a', 's', 'm' };
    try std.testing.expectEqualSlices(u8, &magic, wasm_bytes[0..4]);
}
