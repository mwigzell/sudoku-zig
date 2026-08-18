/// OS-aware filesystem path utilities for the Sudoku save/load feature.
///
/// Resolves platform conventions (XDG on Linux, Application Support on macOS)
/// so callers like `sudoku.zig` don't need to know about `$HOME`, directory
/// creation, or absolute-path detection. All functions return **owned** strings
/// — caller is responsible for freeing via `gpa.free()`.
const std = @import("std");
const builtin = @import("builtin");
const logger = @import("../logger.zig");

const data_dir_suffix = switch (builtin.os.tag) {
    .linux => "/.local/share/sudoku",
    .macos => "/Library/Application Support/sudoku",
    else => @compileError("getDataDir: unsupported OS — add platform convention"),
};

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

/// Resolves the platform data directory for Sudoku and ensures it exists on
/// disk. Linux: `~/.local/share/sudoku/`. macOS: `~/Library/Application
/// Support/sudoku/`. Returns an owned string — caller frees.
pub fn getDataDir(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const home = try getHomeDir(gpa);
    errdefer gpa.free(home);

    const data_dir = try std.fmt.allocPrint(gpa, "{s}{s}", .{ home, data_dir_suffix });
    gpa.free(home);

    const log = logger.Logger(.path);
    const cwd = std.Io.Dir.cwd();
    _ = cwd.createDirPath(io, data_dir) catch |err| {
        log.err("could not create data dir: {s}", .{@errorName(err)});
    };

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

    std.debug.assert(home.len > 0);
    std.debug.assert(home[0] == '/');
}

test "getDataDir returns platform data dir and creates it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const data_dir = try getDataDir(gpa, io);
    defer gpa.free(data_dir);

    const expected_suffix = switch (builtin.os.tag) {
        .linux => ".local/share/sudoku",
        .macos => "Library/Application Support/sudoku",
        else => @compileError("unsupported OS"),
    };
    try std.testing.expect(std.mem.endsWith(u8, data_dir, expected_suffix));
    try std.testing.expect(data_dir[0] == '/');

    const dir = std.Io.Dir.cwd();
    const stat = try dir.statFile(io, data_dir, .{});
    try std.testing.expect(stat.kind == .directory);
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
