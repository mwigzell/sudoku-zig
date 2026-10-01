// Native About acknowledgement text — equal-width lines via `display_width`.
const std = @import("std");
const about = @import("../../about.zig");
const display_width = @import("display_width.zig");

fn nativeLines(info: about.Info) [6][]const u8 {
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
    const info = about.get();
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

test "formatNativeText includes logo summary copyright licence" {
    const text = try formatNativeText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, about.logo_lines[0]) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, about.summaryLine()) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, about.copyright_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, about.licence) != null);
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
