// FileSession: the one owner of write context and the current file name.
// Flows read it to decide overwrite questions and update it after writes.
const std = @import("std");
const file_policy = @import("../file_policy.zig");

/// Longest current file name or path the session keeps.
pub const MAX_NAME_LEN = 4096;

pub const FileSession = struct {
    write_context: file_policy.WriteContext = .detached,
    current_buf: [MAX_NAME_LEN]u8 = undefined,
    current_len: ?usize = null,

    /// The file autosave follows; null until something is opened, restored or written.
    pub fn currentFile(self: *const FileSession) ?[]const u8 {
        const len = self.current_len orelse return null;
        return self.current_buf[0..len];
    }

    /// Replace the current file; a name too long to keep clears it.
    pub fn setCurrentFile(self: *FileSession, name: ?[]const u8) void {
        const value = name orelse {
            self.current_len = null;
            return;
        };
        if (value.len == 0 or value.len > self.current_buf.len) {
            self.current_len = null;
            return;
        }
        std.mem.copyForwards(u8, self.current_buf[0..value.len], value);
        self.current_len = value.len;
    }

    /// Apply a lifecycle event to the write context.
    pub fn apply(self: *FileSession, event: file_policy.WriteContextEvent) void {
        self.write_context = file_policy.nextWriteContext(self.write_context, event);
    }

    /// Record a load that replaced the game: an opened file becomes the current file and later
    /// writes continue it; anything else detaches, so the next write onto an existing file asks first.
    pub fn noteLoad(self: *FileSession, load: Load) void {
        switch (load) {
            .new_game => self.apply(.new_game_success),
            .open => |name| {
                if (name) |n| self.setCurrentFile(n);
                self.apply(.open_success);
            },
            .import => self.apply(.import_success),
            .paste => self.apply(.paste_success),
        }
    }
};

/// What replaced the game; `open` carries the opened file's name when the platform knows it.
pub const Load = union(enum) {
    new_game,
    open: ?[]const u8,
    import,
    paste,
};

test "file session starts detached with no current file" {
    const session = FileSession{};
    try std.testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
    try std.testing.expect(session.currentFile() == null);
}

test "file session keeps and clears the current file" {
    var session = FileSession{};
    session.setCurrentFile("game.sud");
    try std.testing.expectEqualStrings("game.sud", session.currentFile().?);
    session.setCurrentFile(null);
    try std.testing.expect(session.currentFile() == null);
}

test "opening a file makes it the current file and continues it" {
    var session = FileSession{};
    session.noteLoad(.{ .open = "game.sud" });
    try std.testing.expectEqualStrings("game.sud", session.currentFile().?);
    try std.testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
}

test "an unnamed open keeps the current file and still continues it" {
    var session = FileSession{};
    session.setCurrentFile("old.sud");
    session.noteLoad(.{ .open = null });
    try std.testing.expectEqualStrings("old.sud", session.currentFile().?);
    try std.testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
}

test "new, import and paste keep the current file but detach from it" {
    for ([_]Load{ .new_game, .import, .paste }) |load| {
        var session = FileSession{};
        session.noteLoad(.{ .open = "game.sud" });
        session.noteLoad(load);
        try std.testing.expectEqualStrings("game.sud", session.currentFile().?);
        try std.testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
    }
}

test "file session follows write context events" {
    var session = FileSession{};
    session.apply(.open_success);
    try std.testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
    session.apply(.new_game_success);
    try std.testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
}
