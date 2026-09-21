// about.zig — product metadata for Help/About on native and wasm hosts.

const std = @import("std");
const build_info = @import("build_info.zig");
const display_width = @import("display_width.zig");
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

fn nativeLines(info: Info) [6][]const u8 {
    return .{
        info.logo[0],
        info.logo[1],
        info.logo[2],
        info.summary,
        info.copyright,
        info.licence,
    };
}

/// Multi-line About text for the native acknowledgement box — each line padded to equal width.
pub fn formatNativeText(allocator: std.mem.Allocator) ![]u8 {
    const info = get();
    const lines = nativeLines(info);

    var max_cols: usize = 0;
    for (lines) |line| max_cols = @max(max_cols, display_width.columns(line));

    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const padded = try display_width.padColumns(allocator, lines[i], max_cols);
        defer allocator.free(padded);
        try list.appendSlice(allocator, padded);
        if (i + 1 < lines.len) try list.append(allocator, '\n');
    }

    return try list.toOwnedSlice(allocator);
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

test "formatNativeText includes logo summary copyright licence" {
    const text = try formatNativeText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, logo_lines[0]) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, summaryLine()) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, copyright_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, licence) != null);
}

test "formatNativeText pads every line to equal terminal width" {
    const text = try formatNativeText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    var iter = std.mem.splitScalar(u8, text, '\n');
    var first_cols: ?usize = null;
    while (iter.next()) |line| {
        const cols = display_width.columns(line);
        if (first_cols) |w| {
            try std.testing.expectEqual(w, cols);
        } else {
            first_cols = cols;
        }
    }
    try std.testing.expect(first_cols != null and first_cols.? > 0);
}

test "build metadata strings are non-empty" {
    try std.testing.expect(build_info.commit.len > 0);
    try std.testing.expect(build_info.build_date.len > 0);
}
