// FileSession: the one owner of write context and the working file name.
// Flows read it to decide overwrite questions and update it after writes.
const std = @import("std");
const file_policy = @import("../file_policy.zig");

/// Longest working file name or path the session keeps.
pub const MAX_NAME_LEN = 4096;

pub const FileSession = struct {
    write_context: file_policy.WriteContext = .detached,
    working_buf: [MAX_NAME_LEN]u8 = undefined,
    working_len: ?usize = null,

    /// The file autosave follows; null until something is opened, restored or written.
    pub fn workingFile(self: *const FileSession) ?[]const u8 {
        const len = self.working_len orelse return null;
        return self.working_buf[0..len];
    }

    /// Replace the working file; a name too long to keep clears it.
    pub fn setWorkingFile(self: *FileSession, name: ?[]const u8) void {
        const value = name orelse {
            self.working_len = null;
            return;
        };
        if (value.len == 0 or value.len > self.working_buf.len) {
            self.working_len = null;
            return;
        }
        std.mem.copyForwards(u8, self.working_buf[0..value.len], value);
        self.working_len = value.len;
    }

    /// Apply a lifecycle event to the write context.
    pub fn apply(self: *FileSession, event: file_policy.WriteContextEvent) void {
        self.write_context = file_policy.nextWriteContext(self.write_context, event);
    }
};

test "file session starts detached with no working file" {
    const session = FileSession{};
    try std.testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
    try std.testing.expect(session.workingFile() == null);
}

test "file session keeps and clears the working file" {
    var session = FileSession{};
    session.setWorkingFile("game.sud");
    try std.testing.expectEqualStrings("game.sud", session.workingFile().?);
    session.setWorkingFile(null);
    try std.testing.expect(session.workingFile() == null);
}

test "file session follows write context events" {
    var session = FileSession{};
    session.apply(.open_success);
    try std.testing.expectEqual(file_policy.WriteContext.continuation, session.write_context);
    session.apply(.new_game_success);
    try std.testing.expectEqual(file_policy.WriteContext.detached, session.write_context);
}
