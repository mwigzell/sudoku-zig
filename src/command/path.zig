/// OS-aware filesystem path utilities for the Sudoku save/load feature.
///
/// Resolves platform conventions (XDG data dirs on Linux) so callers like
/// `sudoku.zig` don't need to know about `$HOME`, directory creation, or
/// absolute-path detection. All functions return **owned** strings — caller
/// is responsible for freeing via `gpa.free()`.

const std = @import("std");

// Linux-only: walks the C environ array to find $HOME.
fn getHomeDir(gpa: std.mem.Allocator) ![]u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const entry_raw = std.c.environ[i] orelse break;
        const entry = std.mem.sliceTo(entry_raw, 0);
        if (std.mem.indexOfScalarPos(u8, entry, 0, '=')) |eq| {
            if (eq == 4 and std.mem.eql(u8, entry[0..eq], "HOME")) {
                return gpa.dupe(u8, entry[eq + 1 ..]);
            }
        }
    }
    return error.EnvironmentVariableMissing;


}


/// Resolves the XDG data directory for Sudoku (~/.local/share/sudoku/) and
/// ensures it exists on disk. Returns an owned string — caller frees.
pub fn getDataDir(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const home = try getHomeDir(gpa);
    errdefer gpa.free(home);

    const data_dir = try std.fmt.allocPrint(gpa, "{s}/.local/share/sudoku", .{home});
    gpa.free(home);

    // mkdir -p equivalent — absolute path ignores the dir argument
    const cwd = std.Io.Dir.cwd();
    _ = cwd.createDirPath(io, data_dir) catch {};

    return data_dir;
}

/// Resolves a save file path. If `path` starts with `/`, returns an owned
/// copy (passthrough). Otherwise joins it against `data_dir`.
pub fn resolveSavePath(gpa: std.mem.Allocator, data_dir: []const u8, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '/') {
        return gpa.dupe(u8, path);
    }
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ data_dir, path });
}

test "getHomeDir returns HOME" {
    const gpa = std.testing.allocator;
    const home = try getHomeDir(gpa);
    defer gpa.free(home);

    // Invariant: starts with /home/ or /root
    std.debug.assert(home.len > 0);
    std.debug.assert(std.mem.startsWith(u8, home, "/"));
    std.debug.assert(!std.mem.eql(u8, home, ""));
}
test "getDataDir returns ~/.local/share/sudoku and creates it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const data_dir = try getDataDir(gpa, io);
    defer gpa.free(data_dir);

    // Path ends with the expected XDG suffix
    std.debug.assert(std.mem.endsWith(u8, data_dir, ".local/share/sudoku"));
    std.debug.assert(std.mem.startsWith(u8, data_dir, "/home/"));
    std.debug.assert(!std.mem.eql(u8, data_dir, ""));

    // Directory actually exists on disk
    const dir = std.Io.Dir.cwd();
    const stat = try dir.statFile(io, data_dir, .{});
    std.debug.assert(stat.kind == .directory);
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
