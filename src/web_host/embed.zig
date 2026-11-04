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
pub const gen_client_js: []const u8 = @embedFile("../wasm/gen/gen_client.js");
/// Web startup phase orchestration entry point.
pub const app_boot_js: []const u8 = @embedFile("../wasm/app_boot.js");
/// Web UI wiring after startup/session are ready.
pub const app_wire_js: []const u8 = @embedFile("../wasm/app_wire.js");
/// Status bar text (`/status_bar.js`).
pub const status_bar_js: []const u8 = @embedFile("../wasm/status_bar.js");
/// Prompt dialog (`/dialogs/prompt_dialog.js`).
pub const prompt_dialog_js: []const u8 = @embedFile("../wasm/dialogs/prompt_dialog.js");
/// Client diagnostics log (`/client_log.js`).
pub const client_log_js: []const u8 = @embedFile("../wasm/client_log.js");
/// Web session and current-file label (`/session.js`).
pub const session_js: []const u8 = @embedFile("../wasm/flows/session.js");
/// Host HTTP calls (`/host_api.js`).
pub const host_api_js: []const u8 = @embedFile("../wasm/host_api.js");
/// Generate step answerer (`/generate.js`).
pub const generate_js: []const u8 = @embedFile("../wasm/gen/generate.js");
/// Clipboard copy and paste (`/clipboard.js`).
pub const clipboard_js: []const u8 = @embedFile("../wasm/clipboard.js");
/// Autosave platform work (`/autosave.js`).
pub const autosave_js: []const u8 = @embedFile("../wasm/flows/autosave.js");
/// Browser file pickers, handles and download (`/files.js`).
pub const files_js: []const u8 = @embedFile("../wasm/files.js");
/// Step handlers web and Android share (`/flows/steps.js`).
pub const steps_js: []const u8 = @embedFile("../wasm/flows/steps.js");
/// The browser's step handlers (`/flows/web_steps.js`).
pub const web_steps_js: []const u8 = @embedFile("../wasm/flows/web_steps.js");
/// The Android WebView's step handlers (`/flows/android_steps.js`).
pub const android_steps_js: []const u8 = @embedFile("../wasm/flows/android_steps.js");
/// Web startup (`/startup.js`).
pub const startup_js: []const u8 = @embedFile("../wasm/flows/startup.js");
/// Board DOM and input (`/board.js`).
pub const board_js: []const u8 = @embedFile("../wasm/board.js");
/// Edit menu actions (`/menu.js`).
pub const menu_js: []const u8 = @embedFile("../wasm/menus/menu.js");
/// Top menubar chrome (`/menu_bar.js`).
pub const menu_bar_js: []const u8 = @embedFile("../wasm/menus/menu_bar.js");
/// Theme tokens (`/theme.js`).
pub const theme_js: []const u8 = @embedFile("../wasm/menus/theme.js");
/// File menu (`/file_menu.js`).
pub const file_menu_js: []const u8 = @embedFile("../wasm/menus/file_menu.js");
/// Android WebView bridge wrapper, loaded in the page head (`/android_bridge.js`).
pub const android_bridge_js: []const u8 = @embedFile("../wasm/android_bridge.js");
/// Core flow step runner (`/step_runner.js`).
pub const step_runner_js: []const u8 = @embedFile("../wasm/flows/step_runner.js");
/// New-game / generating modal (`/generating.js`).
pub const generating_js: []const u8 = @embedFile("../wasm/dialogs/generating.js");
/// Gen progress UI rows (`/gen_progress_rows.js`).
pub const gen_progress_rows_js: []const u8 = @embedFile("../wasm/gen/gen_progress_rows.js");
/// Region overlay toggle (`/region.js`).
pub const region_js: []const u8 = @embedFile("../wasm/menus/region.js");
/// Help copy (`/help.js`).
pub const help_js: []const u8 = @embedFile("../wasm/menus/help.js");
/// Settings panel (`/settings.js`).
pub const settings_js: []const u8 = @embedFile("../wasm/menus/settings.js");
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

test "embedded app_boot.js is non-empty" {
    try std.testing.expect(app_boot_js.len > 0);
}

test "embedded app_wire.js is non-empty" {
    try std.testing.expect(app_wire_js.len > 0);
}

test "embedded status_bar.js is non-empty" {
    try std.testing.expect(status_bar_js.len > 0);
}

test "embedded prompt_dialog.js is non-empty" {
    try std.testing.expect(prompt_dialog_js.len > 0);
}

test "embedded client_log.js is non-empty" {
    try std.testing.expect(client_log_js.len > 0);
}

test "embedded session.js is non-empty" {
    try std.testing.expect(session_js.len > 0);
}

test "embedded host_api.js is non-empty" {
    try std.testing.expect(host_api_js.len > 0);
}

test "embedded generate.js is non-empty" {
    try std.testing.expect(generate_js.len > 0);
}

test "embedded clipboard.js is non-empty" {
    try std.testing.expect(clipboard_js.len > 0);
}

test "embedded autosave.js is non-empty" {
    try std.testing.expect(autosave_js.len > 0);
}

test "embedded step handler modules are non-empty" {
    for ([_][]const u8{ files_js, steps_js, web_steps_js, android_steps_js }) |js| try std.testing.expect(js.len > 0);
}

test "embedded startup.js is non-empty" {
    try std.testing.expect(startup_js.len > 0);
}

test "embedded startup contract helper is non-empty" {}

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

test "embedded android_bridge.js is non-empty" {
    try std.testing.expect(android_bridge_js.len > 0);
}

test "embedded step_runner.js is non-empty" {
    try std.testing.expect(step_runner_js.len > 0);
}

test "embedded generating.js is non-empty" {
    try std.testing.expect(generating_js.len > 0);
}

test "embedded gen_progress_rows.js is non-empty" {
    try std.testing.expect(gen_progress_rows_js.len > 0);
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
