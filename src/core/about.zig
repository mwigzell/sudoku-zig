// Product metadata for Help/About on native and wasm hosts.
const std = @import("std");
const build_info = @import("../build_info.zig");
const version = @import("version.zig");

pub const name = "sudoku-zig";
pub const copyright_line = "© 2026 Mark Wigzell";
pub const licence = "MIT";
pub const debug_mark = " debug";

pub const logo_lines = [_][]const u8{
    "  ╔═══╗",
    "  ║ S ║",
    "  ╚═══╝",
};

pub const Info = struct {
    name: []const u8,
    version: []const u8,
    commit: []const u8,
    build_date: []const u8,
    copyright: []const u8,
    licence: []const u8,
    logo: []const []const u8,
    summary: []const u8,
};

/// Build the About payload consumed by native and wasm hosts.
pub fn get(debug_build: bool) Info {
    return .{
        .name = name,
        .version = versionLabel(debug_build),
        .commit = build_info.commit,
        .build_date = build_info.build_date,
        .copyright = copyright_line,
        .licence = licence,
        .logo = &logo_lines,
        .summary = summaryLine(debug_build),
    };
}

/// Version as shown in About: marked on Debug builds, bare on release builds.
pub fn versionLabel(debug_build: bool) []const u8 {
    return if (debug_build) version.string ++ debug_mark else version.string;
}

fn summaryFor(comptime label: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s} {s} ({s}) — built {s} — {s}", .{
        name,
        label,
        build_info.commit,
        build_info.build_date,
        licence,
    });
}

/// One-line version/build summary for About screens and diagnostics.
pub fn summaryLine(debug_build: bool) []const u8 {
    return if (debug_build) summaryFor(version.string ++ debug_mark) else summaryFor(version.string);
}

test "summary includes version commit build date and licence" {
    const summary = summaryLine(false);
    try std.testing.expect(std.mem.indexOf(u8, summary, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, version.string) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, build_info.commit) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, build_info.build_date) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, licence) != null);
}

test "get exposes all About fields" {
    const info = get(false);
    try std.testing.expectEqualStrings(name, info.name);
    try std.testing.expectEqualStrings(version.string, info.version);
    try std.testing.expectEqualStrings(build_info.commit, info.commit);
    try std.testing.expectEqualStrings(build_info.build_date, info.build_date);
    try std.testing.expectEqualStrings(copyright_line, info.copyright);
    try std.testing.expectEqualStrings(licence, info.licence);
    try std.testing.expect(info.logo.len > 0);
    try std.testing.expectEqualStrings(summaryLine(false), info.summary);
}

test "a debug build shows debug right after the version; a release build shows nothing" {
    const debug_info = get(true);
    try std.testing.expectEqualStrings(version.string ++ debug_mark, debug_info.version);
    try std.testing.expect(std.mem.indexOf(u8, debug_info.summary, version.string ++ debug_mark ++ " (") != null);
    const release_info = get(false);
    try std.testing.expectEqualStrings(version.string, release_info.version);
    try std.testing.expect(std.mem.indexOf(u8, release_info.summary, debug_mark) == null);
}

test "build metadata strings are non-empty" {
    try std.testing.expect(build_info.commit.len > 0);
    try std.testing.expect(build_info.build_date.len > 0);
}
