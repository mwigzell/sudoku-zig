// Current-file forget: the one place the two writes are ordered for every front end. Clearing the
// pointer is the write the settings store can refuse, so it goes first and a refusal leaves the
// player's save untouched; the platform's delete runs only once the pointer is clear.
const std = @import("std");
const config_store = @import("../config_store.zig");
const startup_config = @import("../startup/config.zig");
const logger = @import("../logger.zig");

const log = logger.Logger(.flow);

/// Shown when a forget failed for a reason that is not a settings refusal: no repair sentence is
/// true of it, so the player gets the generic failure and the error name goes to the log.
pub const FAILED_MSG = "The file could not be forgotten.";

/// Why the settings store would not clear the pointer. The player's repair differs, so core keeps
/// the two apart and every front end shows the matching sentence.
pub const Refusal = enum {
    /// The store would not use the settings file (a read it refused, or a file it could not parse).
    settings_unreadable,
    /// The read succeeded and the file is sound; the write itself failed (a full disk, a folder
    /// this user may not write).
    settings_unwritable,

    /// Core's sentence for this refusal: what happened and the repair that applies to it.
    pub fn sentence(self: Refusal) []const u8 {
        return switch (self) {
            .settings_unreadable => startup_config.SETTINGS_REFUSED_MSG,
            .settings_unwritable => startup_config.SETTINGS_WRITE_FAILED_MSG,
        };
    }
};

/// What a forget did. A refusal means nothing was touched, so the save and the pointer are as they were.
pub const Outcome = union(enum) {
    /// The pointer is clear; the file was deleted when the forget asked for it. A delete that could
    /// not run leaves the file on disk and is only logged: the requested state was reached.
    forgotten,
    /// The settings store refused to clear the pointer.
    refused: Refusal,
    /// The store failed for a reason that is not a settings refusal, so no repair sentence is true of
    /// it: the name rides to the caller, which logs it and shows the player the generic failure.
    failed: []const u8,
};

/// Where the current-file pointer lives; a run with no durable settings passes null.
pub const Settings = struct {
    /// Allocator for the settings store's own buffers.
    gpa: std.mem.Allocator,
    /// Handle the settings store reads and writes through.
    io: std.Io,
    /// Directory holding `config.json`.
    data_dir: []const u8,
};

/// The platform's file delete, behind the same vtable shape as the renderer facade and the file
/// transport: core owns the order, the adapter only removes bytes it knows how to remove.
pub const Deleter = struct {
    context: *anyopaque,
    /// Remove the file at this path; `FileNotFound` is not an error, a file that is already gone
    /// is what the forget asked for.
    remove_fn: *const fn (context: *anyopaque, path: []const u8) anyerror!void,

    /// Build a deleter for an adapter's own context.
    pub fn make(context: *anyopaque, remove_fn: *const fn (context: *anyopaque, path: []const u8) anyerror!void) Deleter {
        return .{ .context = context, .remove_fn = remove_fn };
    }

    /// Delete `path` through this adapter.
    pub fn remove(self: Deleter, path: []const u8) anyerror!void {
        return self.remove_fn(self.context, path);
    }
};

/// The refusal a store error means, when it is one this app knows how to repair: a write the system
/// refused is its own kind, and a file the store will not use is the read refusal. Any other error is
/// nobody's refusal — the caller reports it as a failure carrying its name, and logs nothing here.
pub fn refusalFor(err: config_store.Error) ?Refusal {
    return switch (err) {
        config_store.Error.System => .settings_unreadable,
        config_store.Error.WriteFailed => .settings_unwritable,
        else => null,
    };
}

/// Clear the pointer in `settings` (when there is one), then delete `path` when `delete` asks for
/// it. A refused clear returns before the file is touched; a delete that fails after the clear is
/// logged once, naming the file and the reason, and the forget still answers `.forgotten`.
pub fn forget(settings: ?Settings, path: []const u8, delete: bool, deleter: Deleter) Outcome {
    if (settings) |store| {
        config_store.setCurrentFile(store.gpa, store.io, store.data_dir, null) catch |err| {
            return if (refusalFor(err)) |reason| .{ .refused = reason } else .{ .failed = @errorName(err) };
        };
    }
    if (delete) deleter.remove(path) catch |err| {
        log.warn("could not delete {s}: {s}", .{ path, @errorName(err) });
    };
    return .forgotten;
}

// --- tests ---

/// A settings directory plus a pointer the store can read, so a clear either lands or is refused
/// by something the test set up.
const TestStore = struct {
    tmp: std.testing.TmpDir,
    /// Absolute path of the settings directory.
    dir: []u8,

    fn init() !@This() {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/data", .{tmp.sub_path});
        defer std.testing.allocator.free(rel);
        try std.Io.Dir.cwd().createDirPath(io, rel);
        const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, rel, std.testing.allocator);
        defer std.testing.allocator.free(abs);
        // The temp dir removes its tree, so the settings directory stays inside it.
        return .{ .tmp = tmp, .dir = try std.testing.allocator.dupe(u8, abs) };
    }

    fn deinit(self: *@This()) void {
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn settings(self: *const @This()) Settings {
        return .{ .gpa = std.testing.allocator, .io = std.testing.io, .data_dir = self.dir };
    }

    /// Turn `config.json` into a directory: no read of it can succeed, for root or an ordinary user alike.
    fn makeSettingsUnreadable(self: *const @This()) !void {
        const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ self.dir, config_store.file_name });
        defer std.testing.allocator.free(config_path);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, config_path);
    }

    fn pointer(self: *const @This()) !?[]u8 {
        return config_store.loadCurrentFile(std.testing.allocator, std.testing.io, self.dir);
    }
};

/// Records every delete and, when the test asks, checks what the settings store says at that moment.
const RecordingDeleter = struct {
    calls: usize = 0,
    /// Path the last delete was asked for.
    path: []const u8 = "",
    /// Whether the delete fails, standing in for a folder that will not let the file go.
    fail: bool = false,
    /// When set, the pointer is read on the delete call and checked to be already clear.
    store: ?*const TestStore = null,
    pointer_cleared_at_delete: bool = false,

    fn deleter(self: *@This()) Deleter {
        return Deleter.make(self, remove);
    }

    fn remove(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.path = path;
        if (self.store) |store| {
            const pointer = try store.pointer();
            defer if (pointer) |p| std.testing.allocator.free(p);
            self.pointer_cleared_at_delete = pointer == null;
        }
        if (self.fail) return error.AccessDenied;
    }
};

test "a refused clear never calls the delete and answers the refusal" {
    var store = try TestStore.init();
    defer store.deinit();
    try store.makeSettingsUnreadable();

    var recorder = RecordingDeleter{};
    const outcome = forget(store.settings(), "/games/ghost.sud", true, recorder.deleter());

    try std.testing.expectEqual(Refusal.settings_unreadable, outcome.refused);
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "the pointer is cleared before the delete, which runs once" {
    var store = try TestStore.init();
    defer store.deinit();
    try config_store.setCurrentFile(std.testing.allocator, std.testing.io, store.dir, "/games/game.sud");

    var recorder = RecordingDeleter{ .store = &store };
    const outcome = forget(store.settings(), "/games/game.sud", true, recorder.deleter());

    try std.testing.expect(outcome == .forgotten);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(recorder.pointer_cleared_at_delete);
    try std.testing.expectEqualStrings("/games/game.sud", recorder.path);
    const after = try store.pointer();
    try std.testing.expect(after == null);
}

test "a forget that keeps the file clears the pointer and calls no delete" {
    var store = try TestStore.init();
    defer store.deinit();
    try config_store.setCurrentFile(std.testing.allocator, std.testing.io, store.dir, "/games/game.sud");
    var recorder = RecordingDeleter{};

    try std.testing.expect(forget(store.settings(), "/games/game.sud", false, recorder.deleter()) == .forgotten);
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
    const pointer = try store.pointer();
    try std.testing.expect(pointer == null);
}

test "a delete that fails after the clear is logged once and still answers forgotten" {
    var store = try TestStore.init();
    defer store.deinit();
    try config_store.setCurrentFile(std.testing.allocator, std.testing.io, store.dir, "/games/game.sud");

    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    logger.test_sink = &sink;
    defer logger.test_sink = null;
    logger.min_level = .warn;
    defer logger.min_level = .info;

    var recorder = RecordingDeleter{ .fail = true };
    const outcome = forget(store.settings(), "/games/game.sud", true, recorder.deleter());

    try std.testing.expect(outcome == .forgotten);
    const pointer = try store.pointer();
    try std.testing.expect(pointer == null);
    try std.testing.expectEqualStrings("warn [flow] could not delete /games/game.sud: AccessDenied\n", sink.buffered());
}

test "a run with no settings has no pointer to clear and still deletes when asked" {
    var recorder = RecordingDeleter{};
    try std.testing.expect(forget(null, "/games/game.sud", true, recorder.deleter()) == .forgotten);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
}

test "each refusal maps to its own sentence, and each names its repair" {
    const sentence_mod = @import("../../test/sentence.zig");
    try std.testing.expectEqualStrings(startup_config.SETTINGS_REFUSED_MSG, Refusal.settings_unreadable.sentence());
    try std.testing.expectEqualStrings(startup_config.SETTINGS_WRITE_FAILED_MSG, Refusal.settings_unwritable.sentence());
    try sentence_mod.expectSentence(Refusal.settings_unreadable.sentence());
    try sentence_mod.expectSentence(Refusal.settings_unwritable.sentence());
    try std.testing.expect(std.mem.indexOf(u8, Refusal.settings_unreadable.sentence(), "Repair or delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, Refusal.settings_unwritable.sentence(), "disk has space") != null);
}

test "a store error maps to the refusal whose repair applies, and only those two map" {
    try std.testing.expectEqual(Refusal.settings_unwritable, refusalFor(config_store.Error.WriteFailed).?);
    try std.testing.expectEqual(Refusal.settings_unreadable, refusalFor(config_store.Error.System).?);
    // Nobody's repair: an error this app cannot explain is not called a settings refusal.
    try std.testing.expect(refusalFor(config_store.Error.OutOfMemory) == null);
    try std.testing.expect(refusalFor(config_store.Error.InvalidJson) == null);
    try std.testing.expect(refusalFor(config_store.Error.UnsupportedValue) == null);
}

test "a store error that is no refusal answers failed with its name, and touches no file" {
    var store = try TestStore.init();
    defer store.deinit();
    // The allocator fails inside the settings write's own path work, so the store reports an error
    // that is neither unreadable settings nor an unwritable settings file.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var recorder = RecordingDeleter{};

    const settings = Settings{ .gpa = failing.allocator(), .io = std.testing.io, .data_dir = store.dir };
    const outcome = forget(settings, "/games/game.sud", true, recorder.deleter());

    try std.testing.expectEqualStrings("OutOfMemory", outcome.failed);
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "the generic forget failure is a sentence, and it names no repair" {
    const sentence_mod = @import("../../test/sentence.zig");
    try sentence_mod.expectSentence(FAILED_MSG);
    try std.testing.expect(std.mem.indexOf(u8, FAILED_MSG, "Repair") == null);
    try std.testing.expect(std.mem.indexOf(u8, FAILED_MSG, "disk has space") == null);
}
