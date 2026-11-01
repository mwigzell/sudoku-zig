// Test doubles for driving `Sudoku` through its real loop: a scripted renderer and an in-memory transport.
const std = @import("std");
const facade_mod = @import("../../core/renderer/facade.zig");
const board = @import("../../core/board/board.zig");
const legend = @import("../../core/renderer/legend.zig");
const flow_mod = @import("../../core/flow/mod.zig");
const command = @import("../../core/command.zig");
const config = @import("../../core/config.zig");
const logger = @import("../../core/logger.zig");
const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");
const file_transport = @import("file_transport.zig");

/// Scripted renderer: feeds preset commands and yes/no answers, records what the shell showed.
pub const DeterministicFacade = struct {
    steps: []const command.ParseCommandResult,
    idx: usize = 0,
    render_calls: usize = 0,
    legend_calls: usize = 0,
    error_calls: usize = 0,
    replace_prompts: usize = 0,
    last_render_msg: ?[]const u8 = null,
    replace_answers: []const bool = &[_]bool{},
    replace_idx: usize = 0,

    /// Renderer seam backed by this scripted facade.
    pub fn asFacade(self: *@This()) facade_mod.Facade {
        return facade_mod.Make(@This()).make(self);
    }

    /// Records render calls from Sudoku.handleEvent for deterministic branch tests.
    pub fn render(self: *@This(), _: board.Board.BoardView, msg: ?[]const u8, _: ?facade_mod.Selection) !void {
        self.render_calls += 1;
        self.last_render_msg = msg;
    }

    /// Records legend refreshes from successful event handling.
    pub fn showLegend(self: *@This(), _: legend.Legend) !void {
        self.legend_calls += 1;
    }

    /// Records error-message display calls from Sudoku.handleEvent.
    pub fn showError(self: *@This(), _: []const u8) !void {
        self.error_calls += 1;
    }

    /// Records questions and returns scripted yes/no answers.
    pub fn ask(self: *@This(), _: flow_mod.Ask) !bool {
        self.replace_prompts += 1;
        if (self.replace_idx >= self.replace_answers.len) return true;
        const answer = self.replace_answers[self.replace_idx];
        self.replace_idx += 1;
        return answer;
    }

    /// Feeds pre-scripted command results into Sudoku.turn for deterministic flow tests.
    pub fn getCommandInput(
        self: *@This(),
        _: []const []const u8,
        _: bool,
        _: bool,
        _: config.Difficulty,
        _: logger.Severity,
        _: config.ViewTheme,
        _: bool,
        _: bool,
        _: bool,
        _: ?facade_mod.Selection,
    ) !command.ParseCommandResult {
        if (self.idx >= self.steps.len) return .{ .valid = .{ .quit = {} } };
        const step = self.steps[self.idx];
        self.idx += 1;
        return step;
    }

    /// No-op progress sink for deterministic tests that do not assert gen progress output.
    pub fn reportGenProgress(_: *@This(), _: puzzle_gen.GenProgressEvent) !void {}

    /// No-op lifecycle hook to satisfy the Facade contract in tests.
    pub fn deinit(_: *@This()) void {}
};

/// In-memory file transport: bare names resolve under `DIR`, absolute paths stay as given.
pub const MemoryTransport = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMap([]u8),
    /// Paths written through the transport, in order (setup `put`s are not recorded).
    written: std.ArrayListUnmanaged([]u8) = .empty,

    /// Folder bare names resolve into.
    pub const DIR = "/virtual";

    /// Empty store; files are owned copies.
    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{ .gpa = gpa, .files = std.StringHashMap([]u8).init(gpa) };
    }

    /// Frees every stored file and recorded write path.
    pub fn deinit(self: *@This()) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.files.deinit();
        for (self.written.items) |path| self.gpa.free(path);
        self.written.deinit(self.gpa);
    }

    /// Seeds a file at `path` (an owned copy) without recording a write.
    pub fn put(self: *@This(), path: []const u8, bytes: []const u8) !void {
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        const value = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(value);
        const found = self.files.getEntry(path);
        if (found) |existing| {
            self.gpa.free(existing.key_ptr.*);
            self.gpa.free(existing.value_ptr.*);
            existing.key_ptr.* = key;
            existing.value_ptr.* = value;
            return;
        }
        try self.files.put(key, value);
    }

    /// Transport seam backed by this store.
    pub fn asTransport(self: *@This()) file_transport.FileTransport {
        return .{
            .context = @ptrCast(@alignCast(self)),
            .write = write,
            .readAll = readAll,
            .resolve = resolve,
            .free = free,
        };
    }

    fn asSelf(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) file_transport.TransportError!void {
        const self = asSelf(ctx);
        self.put(path, bytes) catch return file_transport.TransportError.OutOfMemory;
        const logged = self.gpa.dupe(u8, path) catch return file_transport.TransportError.OutOfMemory;
        self.written.append(self.gpa, logged) catch {
            self.gpa.free(logged);
            return file_transport.TransportError.OutOfMemory;
        };
    }

    fn readAll(ctx: *anyopaque, path: []const u8) file_transport.TransportError![]u8 {
        const self = asSelf(ctx);
        const bytes = self.files.get(path) orelse return file_transport.TransportError.FileNotFound;
        return self.gpa.dupe(u8, bytes) catch return file_transport.TransportError.OutOfMemory;
    }

    fn resolve(ctx: *anyopaque, name: []const u8) file_transport.TransportError![]u8 {
        const self = asSelf(ctx);
        if (std.mem.startsWith(u8, name, "/")) {
            return self.gpa.dupe(u8, name) catch return file_transport.TransportError.OutOfMemory;
        }
        return std.fmt.allocPrint(self.gpa, DIR ++ "/{s}", .{name}) catch return file_transport.TransportError.OutOfMemory;
    }

    fn free(ctx: *anyopaque, buf: []u8) void {
        const self = asSelf(ctx);
        self.gpa.free(buf);
    }
};
