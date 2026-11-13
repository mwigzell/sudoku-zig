// Portable save-path math: no environment, no I/O, no platform convention.
// Callers hand in the data directory the native entry resolved.
const std = @import("std");

/// Parent directory of an absolute or relative file path (owned string).
/// A path with no `/` has no directory part, so it answers `"."`.
pub fn parentDir(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return gpa.dupe(u8, ".");
    if (idx == 0) return gpa.dupe(u8, "/");
    return gpa.dupe(u8, path[0..idx]);
}

/// Resolves a save file path. If `path` starts with `/`, returns an owned
/// copy (passthrough). Otherwise joins it against `data_dir`.
pub fn resolveSavePath(gpa: std.mem.Allocator, data_dir: []const u8, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '/') {
        return gpa.dupe(u8, path);
    }
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ data_dir, path });
}

test "parentDir extracts directory from absolute path" {
    const gpa = std.testing.allocator;

    const a = try parentDir(gpa, "/tmp/foo/bar.sud");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/tmp/foo", a);

    const b = try parentDir(gpa, "/tmp/file.sud");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("/tmp", b);
}

test "resolveSavePath joins relative path against data_dir" {
    const gpa = std.testing.allocator;

    const result = try resolveSavePath(gpa, "/home/user/.local/share/sudoku", "game.sud");
    defer gpa.free(result);

    try std.testing.expectEqualStrings("/home/user/.local/share/sudoku/game.sud", result);
}

test "resolveSavePath passes absolute path through as owned copy" {
    const gpa = std.testing.allocator;

    const result = try resolveSavePath(gpa, "/data/sudoku", "/abs/save.sud");
    defer gpa.free(result);

    try std.testing.expectEqualStrings("/abs/save.sud", result);
}

test "resolveSavePath handles nested relative path" {
    const gpa = std.testing.allocator;

    const result = try resolveSavePath(gpa, "/data/sudoku", "backup/save1.sud");
    defer gpa.free(result);

    try std.testing.expectEqualStrings("/data/sudoku/backup/save1.sud", result);
}
