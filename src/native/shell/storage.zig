// Native storage: carries out the file and settings steps core flows ask for,
// through the file transport and the settings store.
const std = @import("std");
const game_engine = @import("../../core/engine/game_engine.zig");
const config = @import("../../core/config.zig");
const settings_store = @import("../../core/settings_store.zig");
const flow_mod = @import("../../core/flow/mod.zig");
const file_transport = @import("file_transport.zig");
const path_mod = @import("path.zig");
const save_defaults = @import("../../core/save_defaults.zig");
const logger = @import("../../core/logger.zig");

const log = logger.Logger(.storage);

const OPEN_NO_FILE_MSG: []const u8 = "open: no file specified";
const IMPORT_NO_FILE_MSG: []const u8 = "import: no file specified";
const SYSTEM_ERROR_MSG: []const u8 = "system error";
const RESOLVE_STAGE: []const u8 = "resolve";
const READ_STAGE: []const u8 = "readAll";

/// Where settings and the current-file pointer live, and the folder for the default save file.
pub const SettingsPersist = struct {
    io: std.Io,
    data_dir: []const u8,
    /// User-visible folder for the default autosave file when there is no current file.
    visible_save_dir: []const u8,
};

/// A file read through the transport; free both buffers with the transport.
pub const ReadResult = struct {
    /// The path the transport resolved the name to.
    resolved: []u8,
    bytes: []u8,
};

pub const Storage = struct {
    transport: file_transport.FileTransport,
    /// Null when the run has nowhere to keep settings; settings and pointer writes are then skipped.
    settings_persist: ?SettingsPersist = null,

    /// The current-file pointer saved by the last run, owned by `gpa`; null when there is none.
    pub fn loadCurrentFile(self: *const @This(), gpa: std.mem.Allocator) ?[]u8 {
        const sp = self.settings_persist orelse return null;
        return settings_store.loadCurrentFile(gpa, sp.io, sp.data_dir) catch |err| {
            log.warn("current file setting unreadable: {s}", .{@errorName(err)});
            return null;
        };
    }

    /// Carry out the write half of a `persist_settings` step.
    pub fn persistSettings(self: *const @This(), cfg: config.Config) flow_mod.step.Outcome {
        const sp = self.settings_persist orelse return .ok;
        settings_store.save(std.heap.page_allocator, sp.io, sp.data_dir, cfg) catch |err| return .{ .failed = @errorName(err) };
        return .ok;
    }

    /// Whether `path` is there; a file this user may not read still counts as there.
    pub fn exists(self: *const @This(), path: []const u8) bool {
        const resolved = self.transport.resolve(self.transport.context, path) catch |err| {
            log.warn("could not resolve {s}: {s}", .{ path, @errorName(err) });
            return false;
        };
        defer self.transport.free(self.transport.context, resolved);
        const bytes = self.transport.readAll(self.transport.context, resolved) catch |err| switch (err) {
            file_transport.TransportError.FileNotFound => {
                log.info("expected: {s} is not there yet ({s})", .{ resolved, @errorName(err) });
                return false;
            },
            file_transport.TransportError.AccessDenied => {
                log.info("expected: {s} is there but not readable by this user ({s})", .{ resolved, @errorName(err) });
                return true;
            },
            else => {
                log.warn("could not check {s}: {s}", .{ resolved, @errorName(err) });
                return false;
            },
        };
        self.transport.free(self.transport.context, bytes);
        return true;
    }

    /// Carry out a `resolve_default_target` step: `<visible_save_dir>/sudoku.sud`, or the bare
    /// default name without settings persistence. Only the default folder is created on demand;
    /// a missing current-file folder must still fail the write.
    pub fn resolveDefaultTarget(self: *const @This(), scratch: []u8) []const u8 {
        const sp = self.settings_persist orelse return copyInto(scratch, save_defaults.DEFAULT_SAVE_FILE);
        std.Io.Dir.cwd().createDirPath(sp.io, sp.visible_save_dir) catch |err| {
            log.warn("could not create save folder {s}: {s}", .{ sp.visible_save_dir, @errorName(err) });
        };
        const path = path_mod.resolveSavePath(std.heap.page_allocator, sp.visible_save_dir, save_defaults.DEFAULT_SAVE_FILE) catch |err| {
            log.err("default save path failed, using the bare name: {s}", .{@errorName(err)});
            return copyInto(scratch, save_defaults.DEFAULT_SAVE_FILE);
        };
        defer std.heap.page_allocator.free(path);
        return copyInto(scratch, path);
    }

    /// Remember `path` as the file the next launch restores; null forgets it.
    pub fn persistCurrentFile(self: *const @This(), path: ?[]const u8) void {
        const sp = self.settings_persist orelse return;
        settings_store.setCurrentFile(std.heap.page_allocator, sp.io, sp.data_dir, path) catch |err| {
            log.err("could not remember the current file: {s}", .{@errorName(err)});
        };
    }

    /// Carry out a `save`, `save_as` or `autosave` step: the terminal has no picker, so all three
    /// write the named file. Without `replace` a file already there is left alone and answers `exists`.
    /// The written file becomes the current file.
    pub fn saveGame(self: *const @This(), engine: *game_engine.GameEngine, target: flow_mod.step.GameWrite, scratch: []u8) flow_mod.Wrote {
        if (!target.replace and self.exists(target.name)) return .exists;
        const save_buf = engine.toSaveFormat(std.heap.page_allocator) catch |err| return .{ .failed = @errorName(err) };
        defer std.heap.page_allocator.free(save_buf);
        const wrote = self.writeNamed(target.name, save_buf, scratch);
        if (wrote == .ok) self.persistCurrentFile(wrote.ok);
        return wrote;
    }

    /// Carry out an `export_puzzle` step; the current file is unchanged.
    pub fn exportPuzzle(self: *const @This(), engine: *game_engine.GameEngine, name: []const u8, scratch: []u8) flow_mod.Wrote {
        const line = engine.toPuzzle();
        return self.writeNamed(name, &line, scratch);
    }

    /// Carry out a `restore` step; on success the bytes are owned by the caller (free with the transport).
    pub fn restore(self: *const @This(), path: []const u8, scratch: []u8) flow_mod.step.Read {
        switch (self.readNamed(path, scratch)) {
            .ok => |read| {
                self.transport.free(self.transport.context, read.resolved);
                return .{ .file = .{ .bytes = read.bytes } };
            },
            .failed => |text| return .{ .failed = text },
        }
    }

    /// Carry out an `open` step: the terminal has no picker, so read the path typed with the command.
    /// On success `read` owns the bytes and resolved path until the flow takes the next step.
    pub fn open(self: *const @This(), path: ?[]const u8, scratch: []u8, read: *?ReadResult) flow_mod.step.Read {
        return self.readTyped(path orelse return .{ .failed = OPEN_NO_FILE_MSG }, scratch, read);
    }

    /// Carry out an `import_puzzle` step: read the path typed with the command, as for `open`.
    pub fn importPuzzle(self: *const @This(), path: ?[]const u8, scratch: []u8, read: *?ReadResult) flow_mod.step.Read {
        return self.readTyped(path orelse return .{ .failed = IMPORT_NO_FILE_MSG }, scratch, read);
    }

    fn readTyped(self: *const @This(), path: []const u8, scratch: []u8, read: *?ReadResult) flow_mod.step.Read {
        switch (self.readNamed(path, scratch)) {
            .ok => |got| {
                read.* = got;
                return .{ .file = .{ .bytes = got.bytes, .name = got.resolved } };
            },
            .failed => |text| return .{ .failed = text },
        }
    }

    /// Resolve `name` and write `bytes` there; answers the resolved path.
    fn writeNamed(self: *const @This(), name: []const u8, bytes: []const u8, scratch: []u8) flow_mod.Wrote {
        const resolved = self.transport.resolve(self.transport.context, name) catch |err|
            return .{ .failed = failedAt(scratch, RESOLVE_STAGE, err) };
        defer self.transport.free(self.transport.context, resolved);
        self.transport.write(self.transport.context, resolved, bytes) catch |err| return .{ .failed = @errorName(err) };
        return .{ .ok = copyInto(scratch, resolved) };
    }

    /// Carry out a `forget_current_file` step: stop restoring it, and delete it when asked.
    pub fn forgetCurrentFile(self: *const @This(), forget: flow_mod.step.ForgetCurrentFile) void {
        const sp = self.settings_persist orelse return;
        if (forget.delete) delete: {
            const resolved = self.transport.resolve(self.transport.context, forget.path) catch |err| {
                log.warn("could not resolve {s} to delete it: {s}", .{ forget.path, @errorName(err) });
                break :delete;
            };
            defer self.transport.free(self.transport.context, resolved);
            std.Io.Dir.deleteFileAbsolute(sp.io, resolved) catch |err| {
                log.warn("could not delete {s}: {s}", .{ resolved, @errorName(err) });
            };
        }
        self.persistCurrentFile(null);
    }

    const NamedRead = union(enum) {
        ok: ReadResult,
        /// Text naming the stage that failed, in `scratch`.
        failed: []const u8,
    };

    /// Resolve and read `path`; on success the caller owns both buffers (free with the transport).
    fn readNamed(self: *const @This(), path: []const u8, scratch: []u8) NamedRead {
        const resolved = self.transport.resolve(self.transport.context, path) catch |err|
            return .{ .failed = failedAt(scratch, RESOLVE_STAGE, err) };
        const bytes = self.transport.readAll(self.transport.context, resolved) catch |err| {
            self.transport.free(self.transport.context, resolved);
            return .{ .failed = failedAt(scratch, READ_STAGE, err) };
        };
        return .{ .ok = .{ .resolved = resolved, .bytes = bytes } };
    }
};

/// `<stage>: <error>` in `scratch`, naming the transport call that failed.
fn failedAt(scratch: []u8, stage: []const u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(scratch, "{s}: {s}", .{ stage, @errorName(err) }) catch SYSTEM_ERROR_MSG;
}

fn copyInto(scratch: []u8, text: []const u8) []const u8 {
    const len = @min(text.len, scratch.len);
    std.mem.copyForwards(u8, scratch[0..len], text[0..len]);
    return scratch[0..len];
}

const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");
/// A temp folder with an absolute path, and a `Storage` whose settings live in it.
const TestRoot = struct {
    tmp: std.testing.TmpDir,
    /// Absolute path of the temp folder.
    dir: []u8,

    fn init() !@This() {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer std.testing.allocator.free(rel);
        const abs_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel, std.testing.allocator);
        defer std.testing.allocator.free(abs_z);
        const dir = try std.testing.allocator.dupe(u8, abs_z);
        return .{ .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *@This()) void {
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
        file_transport.NativeTransport.deinitSession();
    }

    /// Absolute path of `name` inside the temp folder, owned by the testing allocator.
    fn path(self: *const @This(), name: []const u8) ![]u8 {
        return std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ self.dir, name });
    }

    /// Storage on the native transport; settings and the visible save folder use `visible`.
    fn storage(self: *const @This(), visible: []const u8) Storage {
        return .{
            .transport = file_transport.NativeTransport.make(std.testing.io),
            .settings_persist = .{ .io = std.testing.io, .data_dir = self.dir, .visible_save_dir = visible },
        };
    }

    fn currentFile(self: *const @This()) !?[]u8 {
        return settings_store.loadCurrentFile(std.testing.allocator, std.testing.io, self.dir);
    }
};

test "exists: a written file is there and a missing one is not" {
    var root = try TestRoot.init();
    defer root.deinit();
    const store = root.storage(root.dir);
    const there = try root.path("there.sud");
    defer std.testing.allocator.free(there);
    try store.transport.write(store.transport.context, there, "x");
    const missing = try root.path("missing.sud");
    defer std.testing.allocator.free(missing);

    try std.testing.expect(store.exists(there));
    try std.testing.expect(!store.exists(missing));
}

test "resolveDefaultTarget: the default file in the visible folder, creating the folder; the bare name without settings" {
    var root = try TestRoot.init();
    defer root.deinit();
    const visible = try root.path("Documents/Sudoku");
    defer std.testing.allocator.free(visible);
    var scratch: [flow_mod.file_session.MAX_NAME_LEN]u8 = undefined;

    const target = root.storage(visible).resolveDefaultTarget(&scratch);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ visible, save_defaults.DEFAULT_SAVE_FILE });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, target);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, visible, .{});

    const bare: Storage = .{ .transport = file_transport.NativeTransport.make(std.testing.io) };
    try std.testing.expectEqualStrings(save_defaults.DEFAULT_SAVE_FILE, bare.resolveDefaultTarget(&scratch));
}

test "saveGame makes the target the current file; exportPuzzle leaves it alone" {
    var root = try TestRoot.init();
    defer root.deinit();
    const store = root.storage(root.dir);
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    var scratch: [flow_mod.file_session.MAX_NAME_LEN]u8 = undefined;

    const game = try root.path("game.sud");
    defer std.testing.allocator.free(game);
    try std.testing.expectEqualStrings(game, store.saveGame(&engine, .{ .name = game, .replace = false }, &scratch).ok);
    const current = (try root.currentFile()) orelse return error.TestFailed;
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings(game, current);
    const saved = try store.transport.readAll(store.transport.context, game);
    defer store.transport.free(store.transport.context, saved);
    var reloaded = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer reloaded.deinit();
    try reloaded.fromSaveFormat(saved);
    try std.testing.expectEqualSlices(u8, &engine.toPuzzle(), &reloaded.toPuzzle());
    try std.testing.expectEqualDeep(engine.state.status.optional(), reloaded.state.status.optional());

    const line = try root.path("puzzle.txt");
    defer std.testing.allocator.free(line);
    store.persistCurrentFile(game);
    try std.testing.expectEqualStrings(line, store.exportPuzzle(&engine, line, &scratch).ok);
    const bytes = try store.transport.readAll(store.transport.context, line);
    defer store.transport.free(store.transport.context, bytes);
    try std.testing.expectEqualSlices(u8, &engine.toPuzzle(), bytes);
    const after = (try root.currentFile()) orelse return error.TestFailed;
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(game, after);
}

test "saveGame: a file already there answers exists unless replacing is allowed" {
    var root = try TestRoot.init();
    defer root.deinit();
    const store = root.storage(root.dir);
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    var scratch: [flow_mod.file_session.MAX_NAME_LEN]u8 = undefined;
    const game = try root.path("game.sud");
    defer std.testing.allocator.free(game);
    try store.transport.write(store.transport.context, game, "old");

    try std.testing.expect(store.saveGame(&engine, .{ .name = game, .replace = false }, &scratch) == .exists);
    const kept = try store.transport.readAll(store.transport.context, game);
    defer store.transport.free(store.transport.context, kept);
    try std.testing.expectEqualStrings("old", kept);
    try std.testing.expectEqualStrings(game, store.saveGame(&engine, .{ .name = game, .replace = true }, &scratch).ok);
}

test "a failed write reports why and keeps the current file" {
    var root = try TestRoot.init();
    defer root.deinit();
    const store = root.storage(root.dir);
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    var scratch: [flow_mod.file_session.MAX_NAME_LEN]u8 = undefined;
    const kept = try root.path("kept.sud");
    defer std.testing.allocator.free(kept);
    store.persistCurrentFile(kept);
    const unwritable = try root.path("no-such-folder/game.sud");
    defer std.testing.allocator.free(unwritable);

    try std.testing.expect(store.saveGame(&engine, .{ .name = unwritable, .replace = true }, &scratch) == .failed);
    try std.testing.expect(store.exportPuzzle(&engine, unwritable, &scratch) == .failed);
    const current = (try root.currentFile()) orelse return error.TestFailed;
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings(kept, current);
}

test "forgetCurrentFile: deletes the file only when asked, and forgets it either way" {
    var root = try TestRoot.init();
    defer root.deinit();
    const store = root.storage(root.dir);
    const file = try root.path("restore.sud");
    defer std.testing.allocator.free(file);

    for ([_]bool{ false, true }) |delete| {
        try store.transport.write(store.transport.context, file, "x");
        store.persistCurrentFile(file);
        store.forgetCurrentFile(.{ .path = file, .delete = delete });
        try std.testing.expectEqual(!delete, store.exists(file));
        try std.testing.expect((try root.currentFile()) == null);
    }
}

test "open and importPuzzle: no typed path fails with the command's message; a missing file names the failing stage" {
    var root = try TestRoot.init();
    defer root.deinit();
    const store = root.storage(root.dir);
    var scratch: [flow_mod.file_session.MAX_NAME_LEN]u8 = undefined;
    var read: ?ReadResult = null;

    try std.testing.expectEqualStrings(OPEN_NO_FILE_MSG, store.open(null, &scratch, &read).failed);
    try std.testing.expectEqualStrings(IMPORT_NO_FILE_MSG, store.importPuzzle(null, &scratch, &read).failed);
    const missing = try root.path("missing.txt");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("readAll: FileNotFound", store.importPuzzle(missing, &scratch, &read).failed);
    try std.testing.expect(read == null);
}

test "importPuzzle and restore: a typed path's bytes come back, with the resolved name" {
    var root = try TestRoot.init();
    defer root.deinit();
    const store = root.storage(root.dir);
    var scratch: [flow_mod.file_session.MAX_NAME_LEN]u8 = undefined;
    const file = try root.path("puzzle.txt");
    defer std.testing.allocator.free(file);
    const payload = "one-line payload";
    try store.transport.write(store.transport.context, file, payload);

    var read: ?ReadResult = null;
    const picked = store.importPuzzle(file, &scratch, &read).file;
    defer if (read) |r| {
        store.transport.free(store.transport.context, r.resolved);
        store.transport.free(store.transport.context, r.bytes);
    };
    try std.testing.expectEqualSlices(u8, payload, picked.bytes);
    try std.testing.expectEqualStrings(file, picked.name.?);

    const bytes = store.restore(file, &scratch).file.bytes;
    defer store.transport.free(store.transport.context, @constCast(bytes));
    try std.testing.expectEqualSlices(u8, payload, bytes);
}

test "persistSettings: writes the settings file; without settings there is nothing to write" {
    var root = try TestRoot.init();
    defer root.deinit();
    var cfg = config.Config.default();
    cfg.difficulty = .hard;

    try std.testing.expect(root.storage(root.dir).persistSettings(cfg) == .ok);
    const saved = try settings_store.loadOrDefault(std.testing.allocator, std.testing.io, root.dir);
    try std.testing.expectEqual(config.Difficulty.hard, saved.difficulty);

    const bare: Storage = .{ .transport = file_transport.NativeTransport.make(std.testing.io) };
    try std.testing.expect(bare.persistSettings(cfg) == .ok);
}
