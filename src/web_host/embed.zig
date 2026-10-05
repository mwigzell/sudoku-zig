//! Compile-time `@embedFile` payloads for the loopback web shell (`build.zig` must emit artifacts first).
const std = @import("std");

/// Shipped wasm module (`artifact.wasm` on the wire).
pub const wasm_bytes: []const u8 = @embedFile("../wasm/artifacts/artifact.wasm");
/// HTML entry loaded at `/`.
pub const page_html: []const u8 = @embedFile("../wasm/artifacts/page.html");
/// Wasm↔JS bridge emitted beside the artifact.
pub const glue_js: []const u8 = @embedFile("../wasm/artifacts/glue.js");
/// Puzzle-generation worker script.
pub const gen_worker_js: []const u8 = @embedFile("../wasm/artifacts/gen_worker.js");
/// Main-thread client for the gen worker.
pub const gen_client_js: []const u8 = @embedFile("../wasm/gen_client.js");
/// Web app shell bootstrap.
pub const shell_js: []const u8 = @embedFile("../wasm/shell.js");
/// Board DOM and input (`/board.js`).
pub const board_js: []const u8 = @embedFile("../wasm/board.js");
/// Edit menu actions (`/menu.js`).
pub const menu_js: []const u8 = @embedFile("../wasm/menu.js");
/// Top menubar chrome (`/menu_bar.js`).
pub const menu_bar_js: []const u8 = @embedFile("../wasm/menu_bar.js");
/// Theme tokens (`/theme.js`).
pub const theme_js: []const u8 = @embedFile("../wasm/theme.js");
/// File menu (`/file_menu.js`).
pub const file_menu_js: []const u8 = @embedFile("../wasm/file_menu.js");
/// New-game / generating modal (`/generating.js`).
pub const generating_js: []const u8 = @embedFile("../wasm/generating.js");
/// Gen progress UI rows (`/gen_progress_rows.js`).
pub const gen_progress_rows_js: []const u8 = @embedFile("../wasm/gen_progress_rows.js");
/// Gen progress formatting helpers (`/gen_progress_format.js`).
pub const gen_progress_format_js: []const u8 = @embedFile("../wasm/gen_progress_format.js");
/// Region overlay toggle (`/region.js`).
pub const region_js: []const u8 = @embedFile("../wasm/region.js");
/// Help copy (`/help.js`).
pub const help_js: []const u8 = @embedFile("../wasm/help.js");
/// Settings panel (`/settings.js`).
pub const settings_js: []const u8 = @embedFile("../wasm/settings.js");
/// Web app manifest (`/site.webmanifest`).
pub const site_webmanifest: []const u8 = @embedFile("../wasm/artifacts/site.webmanifest");
/// Web/app icon set and artwork variants (`/branding/*`).
pub const brand_favicon_16: []const u8 = @embedFile("../wasm/artifacts/branding/favicon-16x16.png");
pub const brand_favicon_32: []const u8 = @embedFile("../wasm/artifacts/branding/favicon-32x32.png");
pub const brand_apple_touch_icon: []const u8 = @embedFile("../wasm/artifacts/branding/apple-touch-icon.png");
pub const brand_android_chrome_192: []const u8 = @embedFile("../wasm/artifacts/branding/android-chrome-192x192.png");
pub const brand_android_chrome_512: []const u8 = @embedFile("../wasm/artifacts/branding/android-chrome-512x512.png");
pub const brand_splash_mark_256: []const u8 = @embedFile("../wasm/artifacts/branding/splash-mark-256.png");
pub const brand_about_variant_96: []const u8 = @embedFile("../wasm/artifacts/branding/about-variant-96.png");

test "embedded wasm artifact is non-empty" {
    try std.testing.expect(wasm_bytes.len > 8);
}

test "embedded page.html is non-empty" {
    try std.testing.expect(page_html.len > 0);
}

test "embedded glue.js is non-empty" {
    try std.testing.expect(glue_js.len > 0);
}

test "embedded gen_worker.js is non-empty" {
    try std.testing.expect(gen_worker_js.len > 0);
}

test "embedded gen_client.js is non-empty" {
    try std.testing.expect(gen_client_js.len > 0);
}

test "embedded shell.js is non-empty" {
    try std.testing.expect(shell_js.len > 0);
}

test "embedded board.js is non-empty" {
    try std.testing.expect(board_js.len > 0);
}

test "embedded menu.js is non-empty" {
    try std.testing.expect(menu_js.len > 0);
}

test "embedded menu_bar.js is non-empty" {
    try std.testing.expect(menu_bar_js.len > 0);
}

test "embedded theme.js is non-empty" {
    try std.testing.expect(theme_js.len > 0);
}

test "embedded file_menu.js is non-empty" {
    try std.testing.expect(file_menu_js.len > 0);
}

test "embedded generating.js is non-empty" {
    try std.testing.expect(generating_js.len > 0);
}

test "embedded gen_progress_rows.js is non-empty" {
    try std.testing.expect(gen_progress_rows_js.len > 0);
}

test "embedded gen_progress_format.js is non-empty" {
    try std.testing.expect(gen_progress_format_js.len > 0);
}

test "embedded region.js is non-empty" {
    try std.testing.expect(region_js.len > 0);
}

test "embedded help.js is non-empty" {
    try std.testing.expect(help_js.len > 0);
}

test "embedded settings.js is non-empty" {
    try std.testing.expect(settings_js.len > 0);
}

test "embedded site.webmanifest is non-empty" {
    try std.testing.expect(site_webmanifest.len > 0);
}

test "embedded branding images are non-empty" {
    try std.testing.expect(brand_favicon_16.len > 0);
    try std.testing.expect(brand_favicon_32.len > 0);
    try std.testing.expect(brand_apple_touch_icon.len > 0);
    try std.testing.expect(brand_android_chrome_192.len > 0);
    try std.testing.expect(brand_android_chrome_512.len > 0);
    try std.testing.expect(brand_splash_mark_256.len > 0);
    try std.testing.expect(brand_about_variant_96.len > 0);
}

test "embedded wasm artifact starts with the wasm magic header" {
    const magic = [_]u8{ 0x00, 'a', 's', 'm' };
    try std.testing.expectEqualSlices(u8, &magic, wasm_bytes[0..4]);
}
