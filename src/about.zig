// Product metadata for Help/About on native and wasm hosts.
const std = @import("std");
const build_info = @import("build_info.zig");
const version = @import("version.zig");

pub const name = "sudoku-zig";
pub const copyright_line = "© 2026 Mark Wigzell";
pub const licence = "MIT";

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

pub fn get() Info {
    return .{
        .name = name,
        .version = version.string,
        .commit = build_info.commit,
        .build_date = build_info.build_date,
        .copyright = copyright_line,
        .licence = licence,
        .logo = &logo_lines,
        .summary = summaryLine(),
    };
}

pub fn summaryLine() []const u8 {
    return std.fmt.comptimePrint("{s} {s} ({s}) — built {s} — {s}", .{
        name,
        version.string,
        build_info.commit,
        build_info.build_date,
        licence,
    });
}

test "summary includes version commit build date and licence" {
    const summary = summaryLine();
    try std.testing.expect(std.mem.indexOf(u8, summary, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, version.string) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, build_info.commit) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, build_info.build_date) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, licence) != null);
}

test "get exposes all About fields" {
    const info = get();
    try std.testing.expectEqualStrings(name, info.name);
    try std.testing.expectEqualStrings(version.string, info.version);
    try std.testing.expectEqualStrings(build_info.commit, info.commit);
    try std.testing.expectEqualStrings(build_info.build_date, info.build_date);
    try std.testing.expectEqualStrings(copyright_line, info.copyright);
    try std.testing.expectEqualStrings(licence, info.licence);
    try std.testing.expect(info.logo.len > 0);
    try std.testing.expectEqualStrings(summaryLine(), info.summary);
}

test "build metadata strings are non-empty" {
    try std.testing.expect(build_info.commit.len > 0);
    try std.testing.expect(build_info.build_date.len > 0);
}
