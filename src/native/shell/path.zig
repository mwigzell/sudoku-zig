/// OS-aware directory resolution for the Sudoku save/load feature.
///
/// Resolves platform conventions (XDG on Linux, Application Support on macOS)
/// from `$HOME`, which only this platform knows. Portable path math over an
/// already-resolved directory is `core/path.zig`. All functions return **owned**
/// strings — caller is responsible for freeing via `gpa.free()`.
const std = @import("std");
const builtin = @import("builtin");
const save_defaults = @import("../../core/save_defaults.zig");
const data_dir_suffix = switch (builtin.os.tag) {
    .linux => "/.local/share/sudoku",
    .macos => "/Library/Application Support/sudoku",
    else => @compileError("computeDataDir: unsupported OS — add platform convention"),
};

const visible_save_dir_suffix = "/Documents/" ++ save_defaults.DEFAULT_FOLDER_NAME;

// POSIX: walks the C environ array to find $HOME.
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

/// Resolves the platform data directory for Sudoku (path math only — no
/// directory creation, so it stays io-free). Linux: `~/.local/share/sudoku/`.
/// macOS: `~/Library/Application Support/sudoku/`. Returns an owned string —
/// caller frees.
pub fn computeDataDir(gpa: std.mem.Allocator) ![]u8 {
    const home = try getHomeDir(gpa);
    errdefer gpa.free(home);

    const data_dir = try std.fmt.allocPrint(gpa, "{s}{s}", .{ home, data_dir_suffix });
    gpa.free(home);

    return data_dir;
}

/// User-visible folder for the default autosave file: `~/Documents/Sudoku` (path math only). Owned; caller frees.
pub fn computeVisibleSaveDir(gpa: std.mem.Allocator) ![]u8 {
    const home = try getHomeDir(gpa);
    defer gpa.free(home);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ home, visible_save_dir_suffix });
}

test "getHomeDir returns HOME" {
    const gpa = std.testing.allocator;
    const home = try getHomeDir(gpa);
    defer gpa.free(home);

    std.debug.assert(home.len > 0);
    std.debug.assert(home[0] == '/');
}

test "computeDataDir returns platform data dir" {
    const gpa = std.testing.allocator;

    const data_dir = try computeDataDir(gpa);
    defer gpa.free(data_dir);

    const expected_suffix = switch (builtin.os.tag) {
        .linux => ".local/share/sudoku",
        .macos => "Library/Application Support/sudoku",
        else => @compileError("unsupported OS"),
    };
    try std.testing.expect(std.mem.endsWith(u8, data_dir, expected_suffix));
    try std.testing.expect(data_dir[0] == '/');
}

test "computeVisibleSaveDir is the Sudoku folder in the user's Documents" {
    const gpa = std.testing.allocator;

    const home = try getHomeDir(gpa);
    defer gpa.free(home);
    const visible = try computeVisibleSaveDir(gpa);
    defer gpa.free(visible);

    const expected = try std.fmt.allocPrint(gpa, "{s}/Documents/Sudoku", .{home});
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, visible);
}

test "best-effort createDirPath leaves the data dir on disk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const data_dir = try computeDataDir(gpa);
    defer gpa.free(data_dir);

    const dir = std.Io.Dir.cwd();
    _ = dir.createDirPath(io, data_dir) catch {};
    const stat = try dir.statFile(io, data_dir, .{});
    try std.testing.expect(stat.kind == .directory);
}
