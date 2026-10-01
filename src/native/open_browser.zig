/// Desktop browser opener for `-r web` — not part of loopback `web_host`.
const std = @import("std");
const builtin = @import("builtin");

/// No working opener binary was found (`$BROWSER`, `open`, `xdg-open`, etc.).
pub const OpenError = error{Unavailable};

/// Injectable process spawn — production uses real `spawn`; tests record argv without launching a browser.
pub const SpawnFn = *const fn (io: std.Io, argv: []const []const u8) bool;

/// Opens `url` in the user's browser using the platform default opener chain.
pub fn openBrowser(io: std.Io, url: []const u8) OpenError!void {
    return openBrowserWith(io, url, trySpawn);
}

/// Same as `openBrowser` with a custom spawn implementation (unit tests).
pub fn openBrowserWith(io: std.Io, url: []const u8, spawn: SpawnFn) OpenError!void {
    if (std.c.getenv("BROWSER")) |b| {
        const browser = std.mem.span(b);
        if (browser.len > 0 and spawn(io, &.{ browser, url })) return;
    }

    switch (builtin.os.tag) {
        .macos => {
            if (spawn(io, &.{ "open", url })) return;
            if (spawn(io, &.{ "open", "-a", "Vivaldi", url })) return;
        },
        else => {
            if (spawn(io, &.{ "xdg-open", url })) return;
            if (spawn(io, &.{ "vivaldi", url })) return;
        },
    }
    return OpenError.Unavailable;
}

fn trySpawn(io: std.Io, argv: []const []const u8) bool {
    _ = std.process.spawn(io, .{ .argv = argv }) catch return false;
    return true;
}

const SpawnRecord = struct {
    calls: std.ArrayList([]const []const u8),
    fail_first: usize,
    gpa: std.mem.Allocator,

    fn recordSpawn(self: *SpawnRecord, io: std.Io, argv: []const []const u8) bool {
        _ = io;
        const copy = self.gpa.dupe([]const u8, argv) catch return false;
        self.calls.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return false;
        };
        return self.calls.items.len > self.fail_first;
    }
};

var spawn_rec: ?*SpawnRecord = null;

fn recordingSpawn(io: std.Io, argv: []const []const u8) bool {
    return spawn_rec.?.recordSpawn(io, argv);
}

test "openBrowser: macOS prefers default open before Vivaldi" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var rec = SpawnRecord{ .calls = .empty, .fail_first = 0, .gpa = gpa };
    defer {
        for (rec.calls.items) |argv| gpa.free(argv);
        rec.calls.deinit(gpa);
    }
    spawn_rec = &rec;

    const url = "http://127.0.0.1:8080/";
    try openBrowserWith(std.testing.io, url, recordingSpawn);

    try std.testing.expectEqual(@as(usize, 1), rec.calls.items.len);
    const argv = rec.calls.items[0];
    try std.testing.expectEqualStrings("open", argv[0]);
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings(url, argv[1]);
}

test "openBrowser: macOS falls back to Vivaldi when open fails" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var rec = SpawnRecord{ .calls = .empty, .fail_first = 1, .gpa = gpa };
    defer {
        for (rec.calls.items) |argv| gpa.free(argv);
        rec.calls.deinit(gpa);
    }
    spawn_rec = &rec;

    const url = "http://127.0.0.1:8080/";
    try openBrowserWith(std.testing.io, url, recordingSpawn);

    try std.testing.expectEqual(@as(usize, 2), rec.calls.items.len);
    try std.testing.expectEqualStrings("open", rec.calls.items[0][0]);
    try std.testing.expectEqualStrings(url, rec.calls.items[0][1]);
    const vivaldi = rec.calls.items[1];
    try std.testing.expectEqualStrings("open", vivaldi[0]);
    try std.testing.expectEqualStrings("-a", vivaldi[1]);
    try std.testing.expectEqualStrings("Vivaldi", vivaldi[2]);
    try std.testing.expectEqualStrings(url, vivaldi[3]);
}
