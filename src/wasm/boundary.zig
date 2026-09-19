// Wasm JSON boundary — parse action payloads and serialize engine responses.
const std = @import("std");
const board = @import("../board/board.zig");
const cell = @import("../board/cell.zig");
const command = @import("../command.zig");
const config = @import("../config.zig");
const event_mod = @import("../event.zig");
const game_engine = @import("../engine/game_engine.zig");
const legend_mod = @import("../renderer/legend.zig");
const wire = @import("wire.zig");

pub const OutBuffer = struct {
    buf: []u8,
    len: *u32,

    pub fn reset(self: OutBuffer) void {
        self.len.* = 0;
        if (self.buf.len > 0) self.buf[0] = 0;
    }

    pub fn finishJson(self: OutBuffer) [:0]const u8 {
        if (self.len.* >= self.buf.len) self.len.* = @intCast(self.buf.len - 1);
        self.buf[self.len.*] = 0;
        return self.buf[0..self.len.* :0];
    }

    pub fn finishBytes(self: OutBuffer) []const u8 {
        return self.buf[0..self.len.*];
    }
};

var active_out: ?*OutBuffer = null;
var writer_stack: [512]u8 = undefined;

fn appendChunk(ctx: *OutBuffer, chunk: []const u8) std.Io.Writer.Error!void {
    const room = ctx.buf.len - ctx.len.*;
    if (chunk.len > room) return error.WriteFailed;
    @memcpy(ctx.buf[ctx.len.*..][0..chunk.len], chunk);
    ctx.len.* += @intCast(chunk.len);
}

fn jsonDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const ctx = active_out orelse return error.WriteFailed;
    try appendChunk(ctx, w.buffered());
    w.end = 0;

    var data_bytes: usize = 0;
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |s| {
            try appendChunk(ctx, s);
            data_bytes += s.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try appendChunk(ctx, pattern);
            data_bytes += pattern.len;
        }
    }
    return data_bytes;
}

fn jsonWriter(out: *OutBuffer) std.Io.Writer {
    active_out = out;
    return .{
        .vtable = &.{ .drain = jsonDrain },
        .buffer = writer_stack[0..],
    };
}

fn writeJson(out: *OutBuffer, comptime fmt: []const u8, args: anytype) !void {
    out.reset();
    var w = jsonWriter(out);
    try std.Io.Writer.print(&w, fmt, args);
    try std.Io.Writer.flush(&w);
}

fn writeJsonString(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.encodeJsonString(text, .{}, w);
}

const JsonAction = struct {
    action: []const u8,
    row: ?u8 = null,
    col: ?u8 = null,
    digit: ?u8 = null,
    theme: ?[]const u8 = null,
    enabled: ?bool = null,
};

pub fn parseAction(json_text: []const u8) !command.Command {
    const parsed = try std.json.parseFromSlice(JsonAction, std.heap.page_allocator, json_text, .{});
    defer parsed.deinit();

    const row: ?u4 = if (parsed.value.row) |r| blk: {
        if (r > 8) return error.InvalidCoordinate;
        break :blk @intCast(r);
    } else null;
    const col: ?u4 = if (parsed.value.col) |c| blk: {
        if (c > 8) return error.InvalidCoordinate;
        break :blk @intCast(c);
    } else null;

    if (std.ascii.eqlIgnoreCase(parsed.value.action, "fill")) {
        const r = row orelse return error.MissingField;
        const c = col orelse return error.MissingField;
        const d = parsed.value.digit orelse return error.MissingField;
        if (d < 1 or d > 9) return error.InvalidDigit;
        return .{ .fill = .{
            .row = r,
            .col = c,
            .digit = cell.rawToCellValue(d),
        } };
    }
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "clear")) {
        const r = row orelse return error.MissingField;
        const c = col orelse return error.MissingField;
        return .{ .clear = .{ .row = r, .col = c } };
    }
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "undo")) return .{ .undo = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "redo")) return .{ .redo = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "quit")) return .{ .quit = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "set_theme")) {
        const theme_name = parsed.value.theme orelse return error.MissingField;
        if (std.ascii.eqlIgnoreCase(theme_name, "light")) return .{ .set_theme = .light };
        if (std.ascii.eqlIgnoreCase(theme_name, "dark")) return .{ .set_theme = .dark };
        return error.InvalidTheme;
    }
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "set_region")) {
        const enabled = parsed.value.enabled orelse return error.MissingField;
        return .{ .set_region = enabled };
    }

    return error.UnknownAction;
}

pub fn writeOkJson(out: OutBuffer) !void {
    var mutable = out;
    try writeJson(&mutable, "{{\"ok\":true}}", .{});
}

pub fn writeErrorJson(out: OutBuffer, msg: []const u8) !void {
    var mutable = out;
    out.reset();
    var w = jsonWriter(&mutable);
    try std.Io.Writer.writeAll(&w, "{\"ok\":false,\"error\":");
    try writeJsonString(&w, msg);
    try std.Io.Writer.writeAll(&w, "}");
    try std.Io.Writer.flush(&w);
}

pub fn writeEventJson(out: OutBuffer, ev: event_mod.Event) !void {
    var mutable = out;
    out.reset();
    var w = jsonWriter(&mutable);
    switch (ev) {
        .error_msg => |msg| {
            try std.Io.Writer.writeAll(&w, "{\"ok\":false,\"error\":");
            try writeJsonString(&w, msg);
            try std.Io.Writer.writeAll(&w, "}");
        },
        .ok => |data| {
            const snap = wire.GameSnapshot.fromView(data.board_view);
            try std.Io.Writer.writeAll(&w, "{\"ok\":true,\"is_quit\":");
            try std.Io.Writer.print(&w, "{any},\"msg\":", .{data.is_quit});
            if (data.msg) |m| {
                try writeJsonString(&w, m);
                try std.Io.Writer.writeAll(&w, ",");
            } else {
                try std.Io.Writer.writeAll(&w, "null,");
            }
            try std.Io.Writer.writeAll(&w, "\"state\":");
            try writeSnapshotJson(&w, snap);
            try std.Io.Writer.writeAll(&w, "}");
        },
    }
    try std.Io.Writer.flush(&w);
}

pub fn writeLegendJson(out: OutBuffer, legend: legend_mod.Legend) !void {
    var mutable = out;
    try writeJson(
        &mutable,
        "{{\"fill\":{any},\"clear\":{any},\"quit\":{any},\"undo\":{any},\"redo\":{any},\"save\":{any},\"open\":{any},\"new\":{any},\"save_as\":{any}}}",
        .{
            legend.fill,
            legend.clear,
            legend.quit,
            legend.undo,
            legend.redo,
            legend.save,
            legend.open,
            legend.new,
            legend.save_as,
        },
    );
}

pub fn writeWireConfigJson(out: OutBuffer, wire_cfg: wire.WireConfig) !void {
    const theme_name: []const u8 = switch (wire_cfg.theme) {
        .dark => "dark",
        .light => "light",
    };
    var mutable = out;
    try writeJson(
        &mutable,
        "{{\"difficulty\":{d},\"log_level\":{d},\"theme\":\"{s}\",\"show_region\":{any}}}",
        .{
            @backingInt(wire_cfg.difficulty),
            @backingInt(wire_cfg.log_level),
            theme_name,
            wire_cfg.show_region,
        },
    );
}

pub fn writeSnapshotJson(w: *std.Io.Writer, snap: wire.GameSnapshot) !void {
    try std.Io.Writer.writeAll(w, "{\"cells\":[");
    for (snap.cells, 0..) |c, i| {
        if (i > 0) try std.Io.Writer.writeAll(w, ",");
        try std.Io.Writer.print(
            w,
            "{{\"value\":{d},\"given\":{any},\"conflict\":{any}}}",
            .{ c.value, c.given, c.conflict },
        );
    }
    try std.Io.Writer.writeAll(w, "]}");
}

pub fn writeStateJson(out: OutBuffer, view: board.Board.BoardView) !void {
    var mutable = out;
    out.reset();
    var w = jsonWriter(&mutable);
    try writeSnapshotJson(&w, wire.GameSnapshot.fromView(view));
    try std.Io.Writer.flush(&w);
}

test "parseAction fill maps row col digit" {
    const cmd = try parseAction("{\"action\":\"fill\",\"row\":2,\"col\":0,\"digit\":3}");
    switch (cmd) {
        .fill => |f| {
            try std.testing.expectEqual(@as(u4, 2), f.row);
            try std.testing.expectEqual(@as(u4, 0), f.col);
            try std.testing.expectEqual(cell.CellValue.three, f.digit);
        },
        else => return error.TestFailed,
    }
}

test "parseAction rejects unknown action" {
    const result = parseAction("{\"action\":\"xyzzy\"}");
    try std.testing.expectError(error.UnknownAction, result);
}

test "writeEventJson ok embeds state snapshot" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 2, .digit = .seven } });

    var buf: [8192]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeEventJson(out, engine.exec(.{ .undo = {} }));

    const json = out.finishJson();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\"") != null);
}

test "parseAction set_theme and set_region" {
    const theme_cmd = try parseAction("{\"action\":\"set_theme\",\"theme\":\"light\"}");
    switch (theme_cmd) {
        .set_theme => |theme| try std.testing.expectEqual(config.ViewTheme.light, theme),
        else => return error.TestFailed,
    }

    const region_cmd = try parseAction("{\"action\":\"set_region\",\"enabled\":true}");
    switch (region_cmd) {
        .set_region => |enabled| try std.testing.expect(enabled),
        else => return error.TestFailed,
    }
}

test "writeWireConfigJson emits WireConfig wire shape" {
    var buf: [512]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeWireConfigJson(out, .{
        .difficulty = .medium,
        .log_level = .info,
        .theme = .light,
        .show_region = true,
    });
    const json = out.finishJson();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"difficulty\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"theme\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"show_region\":true") != null);
}

const ErrorWire = struct {
    ok: bool,
    @"error": []const u8,
};

const OkEventWire = struct {
    ok: bool,
    is_quit: bool,
    msg: ?[]const u8 = null,
};

test "writeErrorJson escapes quotes and newlines" {
    var buf: [512]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeErrorJson(out, "say \"hello\"\nline2");

    const parsed = try std.json.parseFromSlice(ErrorWire, std.testing.allocator, out.finishJson(), .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("say \"hello\"\nline2", parsed.value.@"error");
}

test "writeEventJson error_msg escapes special characters" {
    var buf: [512]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeEventJson(out, .{ .error_msg = "bad \"input\"\nretry" });

    const parsed = try std.json.parseFromSlice(ErrorWire, std.testing.allocator, out.finishJson(), .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("bad \"input\"\nretry", parsed.value.@"error");
}

test "writeEventJson ok msg escapes special characters" {
    var engine = try game_engine.GameEngine.init(@import("../puzzle_gen.zig").PuzzleGen.default(), @import("../config.zig").Config.default());
    defer engine.deinit();

    var buf: [8192]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    const ev = event_mod.Event{ .ok = .{
        .board_view = engine.eventBoard(),
        .is_quit = false,
        .msg = "saved \"game\"\nok",
    } };
    try writeEventJson(out, ev);

    const parsed = try std.json.parseFromSlice(OkEventWire, std.testing.allocator, out.finishJson(), .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings("saved \"game\"\nok", parsed.value.msg.?);
}

test "writeLegendJson reflects undo availability" {
    var buf: [512]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeLegendJson(out, .{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .save = true,
        .open = true,
        .new = true,
        .save_as = true,
    });
    const json = out.finishJson();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"undo\":false") != null);
}
