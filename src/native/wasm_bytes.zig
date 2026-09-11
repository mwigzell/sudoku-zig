//! The .wasm artifact the native binary ships — embedded at compile time
//! so the web renderer needs no on-disk folder to serve.
//! build.zig emits the payloads into the sibling src/wasm/artifacts/ directory,
//! which @embedFile references below (inside the package root, so it cannot escape).
const std = @import("std");

pub const wasm_bytes: []const u8 = @embedFile("../wasm/artifacts/artifact.wasm");
pub const page_html: []const u8 = @embedFile("../wasm/artifacts/page.html");
pub const glue_js: []const u8 = @embedFile("../wasm/artifacts/glue.js");

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
