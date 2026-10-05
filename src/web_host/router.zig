/// Path → embedded asset routing (pure; sockets live in `mod.zig`).
const std = @import("std");
const embed = @import("embed.zig");

/// Known GET paths under the loopback static host (plus dynamic `host_config` body at serve time).
pub const RouteResult = enum {
    page,
    glue,
    gen_client,
    gen_worker,
    shell,
    board,
    menu,
    menu_bar,
    theme,
    file_menu,
    generating,
    gen_progress_rows,
    gen_progress_format,
    region,
    help,
    settings,
    site_webmanifest,
    brand_favicon_16,
    brand_favicon_32,
    brand_apple_touch_icon,
    brand_android_chrome_192,
    brand_android_chrome_512,
    brand_splash_mark_256,
    brand_about_variant_96,
    host_config,
    artifact,
};

const route_count = switch (@typeInfo(RouteResult)) {
    .@"enum" => |e| e.field_names.len,
    else => unreachable,
};

/// Maps request paths to embedded assets; tracks which routes were hit (tests and delivery checks).
pub const Router = struct {
    delivered: [route_count]bool,

    pub const Error = error{NotFound};

    /// Empty delivery bitmap — every route starts unserved.
    pub fn init() Router {
        return .{ .delivered = std.mem.zeroes([route_count]bool) };
    }

    /// Normalized HTTP path (e.g. `/shell.js`); unknown paths are `Error.NotFound`.
    pub fn route(path: []const u8) Error!RouteResult {
        if (std.mem.eql(u8, path, "/")) return .page;
        if (std.mem.eql(u8, path, "/glue.js")) return .glue;
        if (std.mem.eql(u8, path, "/gen_client.js")) return .gen_client;
        if (std.mem.eql(u8, path, "/gen_worker.js")) return .gen_worker;
        if (std.mem.eql(u8, path, "/shell.js")) return .shell;
        if (std.mem.eql(u8, path, "/board.js")) return .board;
        if (std.mem.eql(u8, path, "/menu.js")) return .menu;
        if (std.mem.eql(u8, path, "/menu_bar.js")) return .menu_bar;
        if (std.mem.eql(u8, path, "/theme.js")) return .theme;
        if (std.mem.eql(u8, path, "/file_menu.js")) return .file_menu;
        if (std.mem.eql(u8, path, "/generating.js")) return .generating;
        if (std.mem.eql(u8, path, "/gen_progress_rows.js")) return .gen_progress_rows;
        if (std.mem.eql(u8, path, "/gen_progress_format.js")) return .gen_progress_format;
        if (std.mem.eql(u8, path, "/region.js")) return .region;
        if (std.mem.eql(u8, path, "/help.js")) return .help;
        if (std.mem.eql(u8, path, "/settings.js")) return .settings;
        if (std.mem.eql(u8, path, "/site.webmanifest")) return .site_webmanifest;
        if (std.mem.eql(u8, path, "/branding/favicon-16x16.png")) return .brand_favicon_16;
        if (std.mem.eql(u8, path, "/branding/favicon-32x32.png")) return .brand_favicon_32;
        if (std.mem.eql(u8, path, "/branding/apple-touch-icon.png")) return .brand_apple_touch_icon;
        if (std.mem.eql(u8, path, "/branding/android-chrome-192x192.png")) return .brand_android_chrome_192;
        if (std.mem.eql(u8, path, "/branding/android-chrome-512x512.png")) return .brand_android_chrome_512;
        if (std.mem.eql(u8, path, "/branding/splash-mark-256.png")) return .brand_splash_mark_256;
        if (std.mem.eql(u8, path, "/branding/about-variant-96.png")) return .brand_about_variant_96;
        if (std.mem.eql(u8, path, "/host-config.json")) return .host_config;
        if (std.mem.eql(u8, path, "/artifact.wasm")) return .artifact;
        return Error.NotFound;
    }

    /// Records that this asset was returned at least once (idempotent per route).
    pub fn markDelivered(self: *Router, result: RouteResult) void {
        self.delivered[@backingInt(result)] = true;
    }

    /// True when every `RouteResult` variant has been marked delivered.
    pub fn allDelivered(self: *const Router) bool {
        for (self.delivered) |d| {
            if (!d) return false;
        }
        return true;
    }

    /// Embedded bytes for static routes; empty for `.host_config` (formatted from live `Config` in the host).
    pub fn body(result: RouteResult) []const u8 {
        return switch (result) {
            .page => embed.page_html,
            .glue => embed.glue_js,
            .gen_client => embed.gen_client_js,
            .gen_worker => embed.gen_worker_js,
            .shell => embed.shell_js,
            .board => embed.board_js,
            .menu => embed.menu_js,
            .menu_bar => embed.menu_bar_js,
            .theme => embed.theme_js,
            .file_menu => embed.file_menu_js,
            .generating => embed.generating_js,
            .gen_progress_rows => embed.gen_progress_rows_js,
            .gen_progress_format => embed.gen_progress_format_js,
            .region => embed.region_js,
            .help => embed.help_js,
            .settings => embed.settings_js,
            .site_webmanifest => embed.site_webmanifest,
            .brand_favicon_16 => embed.brand_favicon_16,
            .brand_favicon_32 => embed.brand_favicon_32,
            .brand_apple_touch_icon => embed.brand_apple_touch_icon,
            .brand_android_chrome_192 => embed.brand_android_chrome_192,
            .brand_android_chrome_512 => embed.brand_android_chrome_512,
            .brand_splash_mark_256 => embed.brand_splash_mark_256,
            .brand_about_variant_96 => embed.brand_about_variant_96,
            .host_config => "",
            .artifact => embed.wasm_bytes,
        };
    }

    /// `Content-Type` header value for a successful GET on this route.
    pub fn contentType(result: RouteResult) []const u8 {
        return switch (result) {
            .page => "text/html",
            .artifact => "application/wasm",
            .host_config => "application/json",
            .site_webmanifest => "application/manifest+json",
            .brand_favicon_16, .brand_favicon_32, .brand_apple_touch_icon, .brand_android_chrome_192, .brand_android_chrome_512, .brand_splash_mark_256, .brand_about_variant_96 => "image/png",
            .glue, .gen_client, .gen_worker, .shell, .board, .menu, .menu_bar, .theme, .file_menu, .generating, .gen_progress_rows, .gen_progress_format, .region, .help, .settings => "text/javascript",
        };
    }
};
