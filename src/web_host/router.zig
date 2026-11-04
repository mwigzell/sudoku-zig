/// Path → embedded asset routing (pure; sockets live in `mod.zig`).
const std = @import("std");
const embed = @import("embed.zig");
const build_info = @import("../build_info.zig");

/// This host's build facts for the page: the wasm ships in every host, so it cannot know the host's mode.
pub const build_info_json = std.fmt.comptimePrint("{{\"debug_build\":{}}}", .{build_info.debug_build});

/// Known GET paths under the loopback static host (plus dynamic `host_config` body at serve time).
pub const RouteResult = enum {
    page,
    glue,
    gen_client,
    gen_worker,
    app_boot,
    app_wire,
    status_bar,
    prompt_dialog,
    client_log,
    session,
    host_api,
    generate,
    clipboard,
    autosave,
    files,
    steps,
    web_steps,
    android_steps,
    startup,
    board,
    menu,
    menu_bar,
    theme,
    file_menu,
    step_runner,
    android_bridge,
    generating,
    gen_progress_rows,
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
    build_info,
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

    /// Normalized HTTP path (e.g. `/board.js`); unknown paths are `Error.NotFound`.
    pub fn route(path: []const u8) Error!RouteResult {
        if (std.mem.eql(u8, path, "/")) return .page;
        if (std.mem.eql(u8, path, "/glue.js")) return .glue;
        if (std.mem.eql(u8, path, "/gen/gen_client.js")) return .gen_client;
        if (std.mem.eql(u8, path, "/gen_worker.js")) return .gen_worker;
        if (std.mem.eql(u8, path, "/app_boot.js")) return .app_boot;
        if (std.mem.eql(u8, path, "/app_wire.js")) return .app_wire;
        if (std.mem.eql(u8, path, "/status_bar.js")) return .status_bar;
        if (std.mem.eql(u8, path, "/dialogs/prompt_dialog.js")) return .prompt_dialog;
        if (std.mem.eql(u8, path, "/client_log.js")) return .client_log;
        if (std.mem.eql(u8, path, "/flows/session.js")) return .session;
        if (std.mem.eql(u8, path, "/host_api.js")) return .host_api;
        if (std.mem.eql(u8, path, "/gen/generate.js")) return .generate;
        if (std.mem.eql(u8, path, "/clipboard.js")) return .clipboard;
        if (std.mem.eql(u8, path, "/flows/autosave.js")) return .autosave;
        if (std.mem.eql(u8, path, "/files.js")) return .files;
        if (std.mem.eql(u8, path, "/flows/steps.js")) return .steps;
        if (std.mem.eql(u8, path, "/flows/web_steps.js")) return .web_steps;
        if (std.mem.eql(u8, path, "/flows/android_steps.js")) return .android_steps;
        if (std.mem.eql(u8, path, "/flows/startup.js")) return .startup;
        if (std.mem.eql(u8, path, "/board.js")) return .board;
        if (std.mem.eql(u8, path, "/menus/menu.js")) return .menu;
        if (std.mem.eql(u8, path, "/menus/menu_bar.js")) return .menu_bar;
        if (std.mem.eql(u8, path, "/menus/theme.js")) return .theme;
        if (std.mem.eql(u8, path, "/menus/file_menu.js")) return .file_menu;
        if (std.mem.eql(u8, path, "/flows/step_runner.js")) return .step_runner;
        if (std.mem.eql(u8, path, "/android_bridge.js")) return .android_bridge;
        if (std.mem.eql(u8, path, "/dialogs/generating.js")) return .generating;
        if (std.mem.eql(u8, path, "/gen/gen_progress_rows.js")) return .gen_progress_rows;
        if (std.mem.eql(u8, path, "/menus/region.js")) return .region;
        if (std.mem.eql(u8, path, "/menus/help.js")) return .help;
        if (std.mem.eql(u8, path, "/menus/settings.js")) return .settings;
        if (std.mem.eql(u8, path, "/site.webmanifest")) return .site_webmanifest;
        if (std.mem.eql(u8, path, "/branding/favicon-16x16.png")) return .brand_favicon_16;
        if (std.mem.eql(u8, path, "/branding/favicon-32x32.png")) return .brand_favicon_32;
        if (std.mem.eql(u8, path, "/branding/apple-touch-icon.png")) return .brand_apple_touch_icon;
        if (std.mem.eql(u8, path, "/branding/android-chrome-192x192.png")) return .brand_android_chrome_192;
        if (std.mem.eql(u8, path, "/branding/android-chrome-512x512.png")) return .brand_android_chrome_512;
        if (std.mem.eql(u8, path, "/branding/splash-mark-256.png")) return .brand_splash_mark_256;
        if (std.mem.eql(u8, path, "/branding/about-variant-96.png")) return .brand_about_variant_96;
        if (std.mem.eql(u8, path, "/build-info.json")) return .build_info;
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
            .app_boot => embed.app_boot_js,
            .app_wire => embed.app_wire_js,
            .status_bar => embed.status_bar_js,
            .prompt_dialog => embed.prompt_dialog_js,
            .client_log => embed.client_log_js,
            .session => embed.session_js,
            .host_api => embed.host_api_js,
            .generate => embed.generate_js,
            .clipboard => embed.clipboard_js,
            .autosave => embed.autosave_js,
            .files => embed.files_js,
            .steps => embed.steps_js,
            .web_steps => embed.web_steps_js,
            .android_steps => embed.android_steps_js,
            .startup => embed.startup_js,
            .board => embed.board_js,
            .menu => embed.menu_js,
            .menu_bar => embed.menu_bar_js,
            .theme => embed.theme_js,
            .file_menu => embed.file_menu_js,
            .step_runner => embed.step_runner_js,
            .android_bridge => embed.android_bridge_js,
            .generating => embed.generating_js,
            .gen_progress_rows => embed.gen_progress_rows_js,
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
            .build_info => build_info_json,
            .host_config => "",
            .artifact => embed.wasm_bytes,
        };
    }

    /// `Content-Type` header value for a successful GET on this route.
    pub fn contentType(result: RouteResult) []const u8 {
        return switch (result) {
            .page => "text/html",
            .artifact => "application/wasm",
            .build_info, .host_config => "application/json",
            .site_webmanifest => "application/manifest+json",
            .brand_favicon_16, .brand_favicon_32, .brand_apple_touch_icon, .brand_android_chrome_192, .brand_android_chrome_512, .brand_splash_mark_256, .brand_about_variant_96 => "image/png",
            .glue, .gen_client, .gen_worker, .app_boot, .app_wire, .status_bar, .prompt_dialog, .client_log, .session, .host_api, .generate, .clipboard, .autosave, .files, .steps, .web_steps, .android_steps, .startup, .board, .menu, .menu_bar, .theme, .file_menu, .step_runner, .android_bridge, .generating, .gen_progress_rows, .region, .help, .settings => "text/javascript",
        };
    }
};
