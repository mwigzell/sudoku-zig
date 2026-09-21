// display_width.zig — monospace terminal column count for UTF-8 text.

const std = @import("std");

/// Visible columns in a fixed-width terminal (one column per UTF-8 codepoint here).
pub fn columns(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Return a copy of `text` with ASCII spaces appended so `columns(out) == width`.
pub fn padColumns(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const cur = columns(text);
    if (cur >= width) return allocator.dupe(u8, text);
    const extra = width - cur;
    const out = try allocator.alloc(u8, text.len + extra);
    @memcpy(out[0..text.len], text);
    @memset(out[text.len..], ' ');
    return out;
}

test "columns counts UTF-8 logo glyphs not bytes" {
    try std.testing.expectEqual(@as(usize, 7), columns("  ╔═══╗"));
    try std.testing.expectEqual(@as(usize, 3), columns("MIT"));
}

test "padColumns aligns mixed UTF-8 and ASCII to equal columns" {
    const logo = "  ╔═══╗";
    const summary = "sudoku-zig 0.1.0 (abc123) — built 2026-09-21 — MIT";
    const target = columns(summary);

    const padded_logo = try padColumns(std.testing.allocator, logo, target);
    defer std.testing.allocator.free(padded_logo);
    const padded_summary = try padColumns(std.testing.allocator, summary, target);
    defer std.testing.allocator.free(padded_summary);

    try std.testing.expectEqual(target, columns(padded_logo));
    try std.testing.expectEqual(target, columns(padded_summary));
}
