// Wasm JSON boundary — parse action payloads and serialize engine responses.
const std = @import("std");
const board = @import("../core/board/board.zig");
const cell = @import("../core/board/cell.zig");
const command = @import("../core/command.zig");
const config = @import("../core/config.zig");
const config_table = @import("../core/config_table.zig");
const logger = @import("../core/logger.zig");
const event_mod = @import("../core/event.zig");
const game_engine = @import("../core/engine/game_engine.zig");
const frame_mod = @import("../core/frame.zig");
const puzzle_gen = @import("../core/puzzle_gen/mod.zig");
const about = @import("../core/about.zig");
const legend_mod = @import("../core/renderer/legend.zig");
const wire = @import("wire.zig");
const flow = @import("../core/flow/mod.zig");
const config_store = @import("../core/config_store.zig");
const file_policy = @import("../core/file_policy.zig");
const startup_policy = @import("../core/startup/policy.zig");
const flow_command = @import("../core/flow/command.zig");
const flow_config = @import("../core/flow/config.zig");
const flow_export = @import("../core/flow/export.zig");

const system_error_json = "{\"ok\":false,\"error\":\"system\"}";

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

fn appendChunk(ctx: *OutBuffer, chunk: []const u8) std.Io.Writer.Error!void {
    const room = ctx.buf.len - ctx.len.*;
    if (chunk.len > room) return error.WriteFailed;
    @memcpy(ctx.buf[ctx.len.*..][0..chunk.len], chunk);
    ctx.len.* += @intCast(chunk.len);
}

const JsonWriter = struct {
    out: *OutBuffer,
    stack: [512]u8 = undefined,
    writer: std.Io.Writer = undefined,

    fn init(out: *OutBuffer, self: *JsonWriter) void {
        self.out = out;
        self.writer = .{
            .vtable = &.{ .drain = drain },
            .buffer = self.stack[0..],
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *JsonWriter = @alignCast(@fieldParentPtr("writer", w));
        try appendChunk(self.out, w.buffered());
        w.end = 0;

        var data_bytes: usize = 0;
        if (data.len > 0) {
            for (data[0 .. data.len - 1]) |s| {
                try appendChunk(self.out, s);
                data_bytes += s.len;
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                try appendChunk(self.out, pattern);
                data_bytes += pattern.len;
            }
        }
        return data_bytes;
    }
};

fn writeJsonString(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.encodeJsonString(text, .{}, w);
}

const JsonAction = struct {
    action: []const u8,
    row: ?u8 = null,
    col: ?u8 = null,
    digit: ?u8 = null,
    difficulty: ?[]const u8 = null,
    /// `set_config`: the Config field's name and its new value (a bool, or a choice's name).
    field: ?[]const u8 = null,
    value: ?std.json.Value = null,
};

/// Longest field or choice name a `set_config` action may carry.
const CHANGE_TEXT_CAP = 64;
// A `set_config` change is read by the command flow after `parseAction` frees its JSON, so its text is kept here.
var change_field_buf: [CHANGE_TEXT_CAP]u8 = undefined;
var change_choice_buf: [CHANGE_TEXT_CAP]u8 = undefined;

fn keepText(buf: []u8, text: []const u8) ![]const u8 {
    if (text.len > buf.len) return error.TextTooLong;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

/// The change a `set_config` action names; core checks the field and value.
fn parseChange(action: JsonAction) !config_table.Change {
    const field = try keepText(&change_field_buf, action.field orelse return error.MissingField);
    const value = config_table.valueFromJson(action.value orelse return error.MissingField) orelse return error.InvalidValue;
    return .{ .field = field, .value = switch (value) {
        .on => value,
        .choice => |name| .{ .choice = try keepText(&change_choice_buf, name) },
    } };
}

fn parseDifficulty(name: []const u8) !config.Difficulty {
    return config_table.parseChoice(config.Difficulty, "difficulty", name) catch error.InvalidDifficulty;
}

/// Load actions carry no path or line: core asks the page for the file or clipboard text.
pub fn parseAction(json_text: []const u8) !command.Command {
    const parsed = try std.json.parseFromSlice(JsonAction, std.heap.page_allocator, json_text, .{});
    defer parsed.deinit();
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "set_config")) return .{ .set_config = try parseChange(parsed.value) };

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
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "toggle_pencil_mode")) return .{ .toggle_pencil_mode = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "clear")) {
        const r = row orelse return error.MissingField;
        const c = col orelse return error.MissingField;
        return .{ .clear = .{ .row = r, .col = c } };
    }
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "select")) {
        const r = row orelse return error.MissingField;
        const c = col orelse return error.MissingField;
        return .{ .select = .{ .row = r, .col = c } };
    }
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "deselect")) return .{ .deselect = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "undo")) return .{ .undo = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "redo")) return .{ .redo = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "quit")) return .{ .quit = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "new")) {
        const difficulty = if (parsed.value.difficulty) |name| try parseDifficulty(name) else null;
        return .{ .new = .{ .difficulty = difficulty } };
    }
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "open")) return .{ .open = .{ .path = null } };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "import")) return .{ .import = .{ .path = null } };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "paste")) return .{ .paste = .{ .line = null } };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "save")) return .{ .save = .{ .path = null } };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "save_as")) return .{ .save_as = .{ .path = null } };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "export")) return .{ .@"export" = .{ .path = null } };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "copy")) return .{ .copy = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "solve")) return .{ .solve_for_me = {} };
    if (std.ascii.eqlIgnoreCase(parsed.value.action, "hint")) {
        if ((row == null) != (col == null)) return error.MissingField;
        return .{ .hint = .{ .row = row, .col = col } };
    }

    return error.UnknownAction;
}

/// Success JSON with an 81-char puzzle line (`generatePuzzle` worker handoff).
pub fn writeOkLineJson(out: OutBuffer, line: []const u8) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    try std.Io.Writer.writeAll(&jw.writer, "{\"ok\":true,\"line\":");
    try writeJsonString(&jw.writer, line);
    try std.Io.Writer.writeAll(&jw.writer, "}");
    try std.Io.Writer.flush(&jw.writer);
}

pub fn writeOkMsgJson(out: OutBuffer, msg: []const u8) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    try std.Io.Writer.writeAll(&jw.writer, "{\"ok\":true,\"msg\":");
    try writeJsonString(&jw.writer, msg);
    try std.Io.Writer.writeAll(&jw.writer, "}");
    try std.Io.Writer.flush(&jw.writer);
}

fn writeErrorJsonTo(w: *std.Io.Writer, msg: []const u8) !void {
    try std.Io.Writer.writeAll(w, "{\"ok\":false,\"error\":");
    try writeJsonString(w, msg);
    try std.Io.Writer.writeAll(w, "}");
}

pub fn writeErrorJson(out: OutBuffer, msg: []const u8) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    try writeErrorJsonTo(&jw.writer, msg);
    try std.Io.Writer.flush(&jw.writer);
}

/// Last-resort JSON when structured encoding fails; fits any nonempty out buffer.
pub fn writeSystemErrorJson(out: OutBuffer) void {
    out.reset();
    const n = @min(system_error_json.len, out.buf.len);
    @memcpy(out.buf[0..n], system_error_json[0..n]);
    out.len.* = @intCast(n);
    if (n < out.buf.len) out.buf[n] = 0;
}

/// Writes Event JSON: `{ok, is_quit, msg, state}` or an error object; `state` is `engine`'s frame under `cfg`.
pub fn writeEventJson(out: OutBuffer, ev: event_mod.Event, engine: *game_engine.GameEngine, cfg: config.Config) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    switch (ev) {
        .error_msg => |msg| try writeErrorJsonTo(&jw.writer, msg),
        .ok => |data| {
            const frame = frame_mod.build(engine, cfg, data.msg);
            try std.Io.Writer.writeAll(&jw.writer, "{\"ok\":true,\"is_quit\":");
            try std.Io.Writer.print(&jw.writer, "{any},\"msg\":", .{data.is_quit});
            if (frame.status) |m| {
                try writeJsonString(&jw.writer, m);
                try std.Io.Writer.writeAll(&jw.writer, ",");
            } else {
                try std.Io.Writer.writeAll(&jw.writer, "null,");
            }
            try std.Io.Writer.writeAll(&jw.writer, "\"state\":");
            try wire.writeGameSnapshotJson(&jw.writer, wire.GameSnapshot.fromFrame(frame));
            try std.Io.Writer.writeAll(&jw.writer, "}");
        },
    }
    try std.Io.Writer.flush(&jw.writer);
}

/// Flow the web runs outside a player command (`flowStart` payload): startup and the final snapshot.
pub const FlowStart = union(enum) {
    autosave_flush,
    /// The host's current file, or null when it has none.
    startup: ?StartupFile,
};

/// Where the host serves its current file, and the name to label and save it under.
pub const StartupFile = struct {
    path: []const u8,
    name: []const u8,
};

const JsonFlowStart = struct {
    flow: []const u8,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

/// Parse `{flow, name?, path?}`; slices live in `arena`.
pub fn parseFlowStart(arena: std.mem.Allocator, json_text: []const u8) !FlowStart {
    const v = try std.json.parseFromSliceLeaky(JsonFlowStart, arena, json_text, .{});
    const kind = std.meta.stringToEnum(std.meta.Tag(FlowStart), v.flow) orelse return error.UnknownFlow;
    return switch (kind) {
        .autosave_flush => .autosave_flush,
        .startup => .{ .startup = if (v.path) |path| .{ .path = path, .name = v.name orelse return error.MissingField } else null },
    };
}

const JsonFlowInput = struct {
    input: []const u8,
    name: ?[]const u8 = null,
    exists: ?bool = null,
    index: ?usize = null,
    ok: ?bool = null,
    cancelled: ?bool = null,
    taken: ?bool = null,
    line: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parse one step result (`flowNext` payload); slices live in `arena`.
pub fn parseFlowInput(arena: std.mem.Allocator, json_text: []const u8) !flow.Input {
    const v = try std.json.parseFromSliceLeaky(JsonFlowInput, arena, json_text, .{});
    const kind = std.meta.stringToEnum(std.meta.Tag(flow.Input), v.input) orelse return error.UnknownInput;
    return switch (kind) {
        .start => .start,
        .default_target => .{ .default_target = v.name orelse return error.MissingField },
        .pressed => .{ .pressed = v.index orelse return error.MissingField },
        .wrote => .{ .wrote = if (v.ok == true)
            .{ .ok = v.name orelse return error.MissingField }
        else if (v.exists == true)
            .exists
        else if (v.cancelled == true)
            .cancelled
        else if (v.taken == true)
            .{ .taken = .{ .name = v.name orelse return error.MissingField } }
        else
            .{ .failed = v.@"error" orelse return error.MissingField } },
        // A successful read carries bytes, so it arrives through `flowRead`, not as JSON.
        .read => if (v.cancelled == true)
            .{ .read = .cancelled }
        else if (v.ok == false)
            .{ .read = .{ .failed = v.@"error" orelse return error.MissingField } }
        else
            error.MissingField,
        .generated => .{ .generated = if (v.ok == true)
            .{ .line = v.line orelse return error.MissingField }
        else if (v.cancelled == true)
            .cancelled
        else
            .{ .failed = v.@"error" orelse return error.MissingField } },
        .persisted => .{ .persisted = try parseOutcome(v) },
        .copied => .{ .copied = try parseOutcome(v) },
        .ack => .ack,
    };
}

fn parseOutcome(v: JsonFlowInput) !flow.step.Outcome {
    if (v.ok == true) return .ok;
    return .{ .failed = v.@"error" orelse return error.MissingField };
}

/// Step JSON: `{"step": <tag>, ...payload}`.
pub fn writeStepJson(out: OutBuffer, step: flow.Step) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    const w = &jw.writer;
    try std.Io.Writer.writeAll(w, "{\"step\":");
    try writeJsonString(w, @tagName(step));
    switch (step) {
        .resolve_default_target, .done, .reclaim_file, .copy_puzzle, .paste_puzzle => {},
        .save, .save_as, .autosave => |target| {
            try std.Io.Writer.writeAll(w, ",\"name\":");
            try writeJsonString(w, target.name);
            try std.Io.Writer.print(w, ",\"replace\":{any}", .{target.replace});
        },
        .flush, .export_puzzle => |name| {
            try std.Io.Writer.writeAll(w, ",\"name\":");
            try writeJsonString(w, name);
        },
        .show_status => |text| {
            try std.Io.Writer.writeAll(w, ",\"text\":");
            try writeJsonString(w, text);
        },
        // `default` and `dismiss` are core's rules for which button Enter and dismissing answer.
        .prompt_message => |p| {
            try std.Io.Writer.writeAll(w, ",\"type\":");
            try writeJsonString(w, @tagName(p.type));
            try std.Io.Writer.writeAll(w, ",\"title\":");
            try writeJsonString(w, p.title);
            try std.Io.Writer.writeAll(w, ",\"text\":");
            try writeJsonString(w, p.text);
            try std.Io.Writer.writeAll(w, ",\"buttons\":[");
            for (p.buttons, 0..) |label, i| {
                if (i > 0) try std.Io.Writer.writeAll(w, ",");
                try writeJsonString(w, label);
            }
            try std.Io.Writer.print(w, "],\"default\":{d},\"dismiss\":", .{p.defaultAnswer()});
            if (p.dismissAnswer()) |d| try std.Io.Writer.print(w, "{d}", .{d}) else try std.Io.Writer.writeAll(w, "null");
        },
        .restore => |path| {
            try std.Io.Writer.writeAll(w, ",\"path\":");
            try writeJsonString(w, path);
        },
        .open, .import_puzzle => |path| {
            try std.Io.Writer.writeAll(w, ",\"path\":");
            try writeOptionalJsonString(w, path);
        },
        .show_game => |g| {
            try std.Io.Writer.writeAll(w, ",\"text\":");
            try writeOptionalJsonString(w, g.frame.status);
            try std.Io.Writer.writeAll(w, ",\"file\":");
            try writeOptionalJsonString(w, g.file);
            try std.Io.Writer.writeAll(w, ",\"state\":");
            try wire.writeGameSnapshotJson(w, wire.GameSnapshot.fromFrame(g.frame));
            try std.Io.Writer.writeAll(w, ",\"legend\":");
            try writeLegendTo(w, g.legend);
            try std.Io.Writer.writeAll(w, ",\"config\":");
            try config_store.writeConfigJson(w, g.config);
            if (g.loaded) try std.Io.Writer.writeAll(w, ",\"loaded\":true");
        },
        .generate_game => |d| {
            try std.Io.Writer.writeAll(w, ",\"difficulty\":");
            try writeJsonString(w, @tagName(d));
        },
        .forget_current_file => |f| {
            try std.Io.Writer.writeAll(w, ",\"path\":");
            try writeJsonString(w, f.path);
            try std.Io.Writer.print(w, ",\"delete\":{any}", .{f.delete});
        },
        .persist_config => |cfg| {
            try std.Io.Writer.writeAll(w, ",\"config\":");
            try config_store.writeConfigJson(w, cfg);
        },
    }
    try std.Io.Writer.writeAll(w, "}");
    try std.Io.Writer.flush(w);
}

fn writeOptionalJsonString(w: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |v| try writeJsonString(w, v) else try std.Io.Writer.writeAll(w, "null");
}

/// About metadata JSON; `debug_build` is the serving host's build mode.
pub fn writeAboutJson(out: OutBuffer, debug_build: bool) !void {
    const info = about.get(debug_build);
    var mutable = out;
    mutable.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    try std.Io.Writer.writeAll(&jw.writer, "{\"name\":");
    try writeJsonString(&jw.writer, info.name);
    try std.Io.Writer.writeAll(&jw.writer, ",\"version\":");
    try writeJsonString(&jw.writer, info.version);
    try std.Io.Writer.writeAll(&jw.writer, ",\"commit\":");
    try writeJsonString(&jw.writer, info.commit);
    try std.Io.Writer.writeAll(&jw.writer, ",\"build_date\":");
    try writeJsonString(&jw.writer, info.build_date);
    try std.Io.Writer.writeAll(&jw.writer, ",\"copyright\":");
    try writeJsonString(&jw.writer, info.copyright);
    try std.Io.Writer.writeAll(&jw.writer, ",\"licence\":");
    try writeJsonString(&jw.writer, info.licence);
    try std.Io.Writer.writeAll(&jw.writer, ",\"summary\":");
    try writeJsonString(&jw.writer, info.summary);
    try std.Io.Writer.writeAll(&jw.writer, ",\"logo\":[");
    for (info.logo, 0..) |line, i| {
        if (i > 0) try std.Io.Writer.writeAll(&jw.writer, ",");
        try writeJsonString(&jw.writer, line);
    }
    try std.Io.Writer.writeAll(&jw.writer, "]}");
    try std.Io.Writer.flush(&jw.writer);
}

const TextEntry = struct { key: []const u8, text: []const u8 };

fn writeTextTableJson(out: OutBuffer, entries: []const TextEntry) !void {
    var mutable = out;
    mutable.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    for (entries, 0..) |e, i| {
        try std.Io.Writer.writeAll(&jw.writer, if (i == 0) "{" else ",");
        try writeJsonString(&jw.writer, e.key);
        try std.Io.Writer.writeAll(&jw.writer, ":");
        try writeJsonString(&jw.writer, e.text);
    }
    try std.Io.Writer.writeAll(&jw.writer, "}");
    try std.Io.Writer.flush(&jw.writer);
}

/// Generating dialog text from core, keyed for the web dialog.
pub fn writeGenTextJson(out: OutBuffer) !void {
    try writeTextTableJson(out, &.{
        .{ .key = "title", .text = puzzle_gen.GENERATING_TITLE },
        .{ .key = "busy", .text = puzzle_gen.GENERATING_MSG },
        .{ .key = "done", .text = puzzle_gen.GENERATING_DONE_MSG },
        .{ .key = "cancelling", .text = puzzle_gen.GENERATING_CANCELLING_MSG },
        .{ .key = "fast_strip", .text = puzzle_gen.FAST_STRIP_MSG },
        .{ .key = "dig_hole", .text = puzzle_gen.DIG_HOLE_MSG },
    });
}

/// Core's dialog and status text keyed by constant name, so JS tests compare against core rather than copies.
pub fn writeCoreTextJson(out: OutBuffer) !void {
    try writeTextTableJson(out, &.{
        .{ .key = "ERROR_TITLE", .text = flow.step.ERROR_TITLE },
        .{ .key = "OK_LABEL", .text = flow.step.OK_LABEL },
        .{ .key = "SAVED_TO_FMT", .text = file_policy.SAVED_TO_FMT },
        .{ .key = "WRITE_CANCELLED_MSG", .text = file_policy.WRITE_CANCELLED_MSG },
        .{ .key = "REPLACE_CONFIRM_TITLE", .text = file_policy.REPLACE_CONFIRM_TITLE },
        .{ .key = "REPLACE_CONFIRM_FMT", .text = file_policy.REPLACE_CONFIRM_FMT },
        .{ .key = "REPLACE_CONFIRM_OK_LABEL", .text = file_policy.REPLACE_CONFIRM_OK_LABEL },
        .{ .key = "REPLACE_CONFIRM_CANCEL_LABEL", .text = file_policy.REPLACE_CONFIRM_CANCEL_LABEL },
        .{ .key = "TAKEN_TITLE", .text = file_policy.TAKEN_TITLE },
        .{ .key = "TAKEN_FMT", .text = file_policy.TAKEN_FMT },
        .{ .key = "TAKEN_PICK_LABEL", .text = file_policy.TAKEN_PICK_LABEL },
        .{ .key = "TAKEN_NEW_NAME_LABEL", .text = file_policy.TAKEN_NEW_NAME_LABEL },
        .{ .key = "SAVE_WHILE_AUTO_SAVE_MSG", .text = file_policy.SAVE_WHILE_AUTO_SAVE_MSG },
        .{ .key = "SAVE_FAILED_MSG", .text = flow.save.SAVE_FAILED_MSG },
        .{ .key = "RESTORE_FAILED_FMT", .text = flow.startup.RESTORE_FAILED_FMT },
        .{ .key = "UNEXPECTED_INPUT_MSG", .text = flow.step.UNEXPECTED_INPUT_MSG },
        .{ .key = "GENERATE_FAILED_MSG", .text = flow.step.GENERATE_FAILED_MSG },
        .{ .key = "IMPORT_FAILED_MSG", .text = flow_command.IMPORT_FAILED_MSG },
        .{ .key = "PASTE_FAILED_MSG", .text = flow_command.PASTE_FAILED_MSG },
        .{ .key = "LOAD_ENDED_STATUS", .text = flow_command.LOAD_ENDED_STATUS },
        .{ .key = "PERSIST_FAILED_MSG", .text = flow_config.PERSIST_FAILED_MSG },
        .{ .key = "UNKNOWN_FIELD_MSG", .text = config_table.UNKNOWN_FIELD_MSG },
        .{ .key = "BAD_VALUE_MSG", .text = config_table.BAD_VALUE_MSG },
        .{ .key = "EXPORTED_TO_FMT", .text = flow_export.EXPORTED_TO_FMT },
        .{ .key = "EXPORT_FAILED_MSG", .text = flow_export.EXPORT_FAILED_MSG },
        .{ .key = "COPIED_MSG", .text = flow_export.COPIED_MSG },
        .{ .key = "COPY_FAILED_MSG", .text = flow_export.COPY_FAILED_MSG },
        .{ .key = "IDLE_STARTUP_STATUS", .text = startup_policy.IDLE_STARTUP_STATUS },
        .{ .key = "NEW_GAME_STARTED_MSG", .text = game_engine.NEW_GAME_STARTED_MSG },
        .{ .key = "OPENED_FMT", .text = game_engine.OPENED_FMT },
        .{ .key = "PASTED_MSG", .text = game_engine.PASTED_MSG },
        .{ .key = "PUZZLE_LENGTH_MSG", .text = game_engine.PUZZLE_LENGTH_MSG },
        .{ .key = "PUZZLE_CELL_MSG", .text = game_engine.PUZZLE_CELL_MSG },
    });
}

pub fn writeLegendJson(out: OutBuffer, legend: legend_mod.Legend) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    try writeLegendTo(&jw.writer, legend);
    try std.Io.Writer.flush(&jw.writer);
}

fn writeLegendTo(w: *std.Io.Writer, legend: legend_mod.Legend) !void {
    try std.Io.Writer.print(
        w,
        "{{\"fill\":{any},\"clear\":{any},\"hint\":{any},\"quit\":{any},\"undo\":{any},\"redo\":{any},\"save\":{any},\"open\":{any},\"new\":{any},\"import\":{any},\"export\":{any},\"copy\":{any},\"paste\":{any},\"save_as\":{any},\"solve\":{any}}}",
        .{
            legend.fill,
            legend.clear,
            legend.hint,
            legend.quit,
            legend.undo,
            legend.redo,
            legend.save,
            legend.open,
            legend.new,
            legend.import,
            legend.@"export",
            legend.copy,
            legend.paste,
            legend.save_as,
            legend.solve,
        },
    );
}

/// The player's Config as JSON, in `config.json`'s shape (`getConfig`).
pub fn writeConfigJson(out: OutBuffer, cfg: config.Config) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    try config_store.writeConfigJson(&jw.writer, cfg);
    try std.Io.Writer.flush(&jw.writer);
}

/// Core's config table as JSON (`getConfigTable`): `{on, off, rows}` — the words for an on/off value,
/// then one row per saved field in Settings order, `{field, label, choices}` (`choices` null for on/off).
pub fn writeConfigTableJson(out: OutBuffer) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    var s: std.json.Stringify = .{ .writer = &jw.writer };
    try s.beginObject();
    try s.objectField("on");
    try s.write(config_table.ON_LABEL);
    try s.objectField("off");
    try s.write(config_table.OFF_LABEL);
    try s.objectField("rows");
    try s.beginArray();
    for (config_table.rows) |row| {
        try s.beginObject();
        try s.objectField("field");
        try s.write(row.field);
        try s.objectField("label");
        try s.write(row.label);
        try s.objectField("choices");
        switch (row.kind) {
            .on_off => try s.write(null),
            .choices => |choices| try s.write(choices),
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try std.Io.Writer.flush(&jw.writer);
}

/// What the generation worker asks for: the difficulty, the log level it runs at and its entropy.
pub const GenRequest = struct {
    difficulty: config.Difficulty,
    log_level: logger.Severity,
    seed: u32,
};

/// Parse a `generatePuzzle` request; choices are named as in `config.json`.
pub fn parseGenRequest(json_text: []const u8) !GenRequest {
    const parsed = try std.json.parseFromSlice(GenRequest, std.heap.page_allocator, json_text, .{});
    defer parsed.deinit();
    return parsed.value;
}

/// Writes the snapshot JSON of `frame` (`getState`).
pub fn writeStateJson(out: OutBuffer, frame: frame_mod.Frame) !void {
    var mutable = out;
    out.reset();
    var jw: JsonWriter = undefined;
    JsonWriter.init(&mutable, &jw);
    try wire.writeGameSnapshotJson(&jw.writer, wire.GameSnapshot.fromFrame(frame));
    try std.Io.Writer.flush(&jw.writer);
}

test "parseAction select carries its cell; deselect has none" {
    const sel = try parseAction("{\"action\":\"select\",\"row\":4,\"col\":7}");
    try std.testing.expectEqual(@as(u4, 4), sel.select.row);
    try std.testing.expectEqual(@as(u4, 7), sel.select.col);
    try std.testing.expectError(error.MissingField, parseAction("{\"action\":\"select\",\"row\":4}"));
    try std.testing.expect(try parseAction("{\"action\":\"deselect\"}") == .deselect);
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

test "parseAction hint maps optional row col" {
    const bare = try parseAction("{\"action\":\"hint\"}");
    try std.testing.expect(bare == .hint);
    try std.testing.expect(bare.hint.row == null and bare.hint.col == null);

    const targeted = try parseAction("{\"action\":\"hint\",\"row\":2,\"col\":4}");
    try std.testing.expect(targeted == .hint);
    try std.testing.expectEqual(@as(?u4, 2), targeted.hint.row);
    try std.testing.expectEqual(@as(?u4, 4), targeted.hint.col);

    const d1 = try parseAction("{\"action\":\"hint\",\"row\":0,\"col\":3}");
    try std.testing.expectEqual(@as(?u4, 0), d1.hint.row);
    try std.testing.expectEqual(@as(?u4, 3), d1.hint.col);
}

test "parseAction writes carry no path; core chooses the name" {
    try std.testing.expect((try parseAction("{\"action\":\"save\"}")).save.path == null);
    try std.testing.expect((try parseAction("{\"action\":\"save_as\"}")).save_as.path == null);
    try std.testing.expect((try parseAction("{\"action\":\"export\"}")).@"export".path == null);
    try std.testing.expect((try parseAction("{\"action\":\"copy\"}")) == .copy);
}

test "parseAction loads carry no path or line; new takes an optional difficulty" {
    try std.testing.expect((try parseAction("{\"action\":\"open\"}")).open.path == null);
    try std.testing.expect((try parseAction("{\"action\":\"import\"}")).import.path == null);
    try std.testing.expect((try parseAction("{\"action\":\"paste\"}")).paste.line == null);
    try std.testing.expect((try parseAction("{\"action\":\"new\"}")).new.difficulty == null);
    try std.testing.expectEqual(config.Difficulty.hard, (try parseAction("{\"action\":\"new\",\"difficulty\":\"hard\"}")).new.difficulty.?);
    try std.testing.expectError(error.InvalidDifficulty, parseAction("{\"action\":\"new\",\"difficulty\":\"wild\"}"));
}

test "parseAction solve maps to solve_for_me" {
    const cmd = try parseAction("{\"action\":\"solve\"}");
    try std.testing.expect(cmd == .solve_for_me);
}

test "writeEventJson ok embeds state snapshot" {
    var engine = try game_engine.GameEngine.init(@import("../core/puzzle_gen/mod.zig").PuzzleGen.default(), @import("../core/config.zig").Config.default());
    defer engine.deinit();
    _ = engine.exec(.{ .fill = .{ .row = 0, .col = 2, .digit = .seven } });

    var buf: [8192]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    const undone = engine.exec(.{ .undo = {} });
    try writeEventJson(out, undone, &engine, config.Config.default());

    const json = out.finishJson();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\"") != null);
}

test "parseAction set_config carries the field and a bool or a choice name" {
    const region = (try parseAction("{\"action\":\"set_config\",\"field\":\"show_region\",\"value\":true}")).set_config;
    try std.testing.expectEqualStrings("show_region", region.field);
    try std.testing.expect(region.value.on);
    const theme = (try parseAction("{\"action\":\"set_config\",\"field\":\"theme\",\"value\":\"light\"}")).set_config;
    try std.testing.expectEqualStrings("theme", theme.field);
    try std.testing.expectEqualStrings("light", theme.value.choice);
    try std.testing.expect(try parseAction("{\"action\":\"toggle_pencil_mode\"}") == .toggle_pencil_mode);
    try std.testing.expectError(error.MissingField, parseAction("{\"action\":\"set_config\",\"field\":\"theme\"}"));
    try std.testing.expectError(error.InvalidValue, parseAction("{\"action\":\"set_config\",\"field\":\"theme\",\"value\":3}"));
}

test "the config table JSON lists every row with its label and choices" {
    var buf: [2048]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeConfigTableJson(out);
    const json = out.finishJson();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(config_table.ON_LABEL, parsed.value.object.get("on").?.string);
    const rows = parsed.value.object.get("rows").?.array.items;
    try std.testing.expectEqual(config_table.rows.len, rows.len);
    for (config_table.rows, rows) |want, got| {
        try std.testing.expectEqualStrings(want.field, got.object.get("field").?.string);
        try std.testing.expectEqualStrings(want.label, got.object.get("label").?.string);
        const choices = got.object.get("choices").?;
        switch (want.kind) {
            .on_off => try std.testing.expect(choices == .null),
            .choices => |c| try std.testing.expectEqualStrings(c[0].name, choices.array.items[0].object.get("name").?.string),
        }
    }
}

test "the test-only Config field crosses the wire: in the table, set by set_config, written and read back" {
    const field = "test_probe";
    var buf: [2048]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeConfigTableJson(out);
    try std.testing.expect(std.mem.indexOf(u8, out.finishJson(), "\"field\":\"" ++ field ++ "\"") != null);

    var cfg = config.Config.default();
    try config_table.apply(&cfg, (try parseAction("{\"action\":\"set_config\",\"field\":\"" ++ field ++ "\",\"value\":true}")).set_config);
    len = 0;
    try writeConfigJson(out, cfg);
    const json = out.finishJson();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"" ++ field ++ "\":true") != null);

    var read_back = config.Config.default();
    try config_store.applyConfigJson(std.testing.allocator, &read_back, json);
    try std.testing.expect(read_back.test_probe);
}

test "parseGenRequest reads the difficulty and log level by name" {
    const req = try parseGenRequest("{\"difficulty\":\"hard\",\"log_level\":\"warn\",\"seed\":7}");
    try std.testing.expectEqual(config.Difficulty.hard, req.difficulty);
    try std.testing.expectEqual(logger.Severity.warn, req.log_level);
    try std.testing.expectEqual(@as(u32, 7), req.seed);
}

test "writeConfigJson writes the Config as config.json does: bools, choices by name" {
    var buf: [512]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    var cfg = config.Config.default();
    cfg.difficulty = .medium;
    cfg.show_region = true;
    try writeConfigJson(out, cfg);
    const json = out.finishJson();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"difficulty\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"log_level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"show_region\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "renderers") == null);
}

const ErrorWire = struct {
    ok: bool,
    @"error": []const u8,
};

const OkLineWire = struct {
    ok: bool,
    line: []const u8,
};

const OkEventWire = struct {
    ok: bool,
    is_quit: bool,
    msg: ?[]const u8 = null,
};

test "writeSystemErrorJson emits parseable system error" {
    var buf: [64]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    writeSystemErrorJson(out);

    const parsed = try std.json.parseFromSlice(ErrorWire, std.testing.allocator, out.finishJson(), .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("system", parsed.value.@"error");
}

test "writeErrorJson failure leaves room for system fallback json" {
    var buf: [32]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try std.testing.expectError(error.WriteFailed, writeErrorJson(
        out,
        "this message cannot fit in thirty two bytes of json output",
    ));
    writeSystemErrorJson(out);

    const parsed = try std.json.parseFromSlice(ErrorWire, std.testing.allocator, out.finishJson(), .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("system", parsed.value.@"error");
}

test "writeOkLineJson emits parseable puzzle line" {
    var buf: [256]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    const line = "003020600900305001001806400008102900700000008006708200002609500800203009005010300";
    try writeOkLineJson(out, line);

    const parsed = try std.json.parseFromSlice(OkLineWire, std.testing.allocator, out.finishJson(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings(line, parsed.value.line);
}

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
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), config.Config.default());
    defer engine.deinit();
    var buf: [512]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeEventJson(out, .{ .error_msg = "bad \"input\"\nretry" }, &engine, config.Config.default());

    const parsed = try std.json.parseFromSlice(ErrorWire, std.testing.allocator, out.finishJson(), .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("bad \"input\"\nretry", parsed.value.@"error");
}

test "writeEventJson ok msg escapes special characters" {
    var engine = try game_engine.GameEngine.init(@import("../core/puzzle_gen/mod.zig").PuzzleGen.default(), @import("../core/config.zig").Config.default());
    defer engine.deinit();

    var buf: [8192]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    const ev = event_mod.Event{ .ok = .{
        .board_view = engine.eventBoard(),
        .is_quit = false,
        .msg = "saved \"game\"\nok",
    } };
    try writeEventJson(out, ev, &engine, config.Config.default());

    const parsed = try std.json.parseFromSlice(OkEventWire, std.testing.allocator, out.finishJson(), .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings("saved \"game\"\nok", parsed.value.msg.?);
}

const AboutWire = struct {
    name: []const u8,
    version: []const u8,
    commit: []const u8,
    build_date: []const u8,
    copyright: []const u8,
    licence: []const u8,
    summary: []const u8,
    logo: []const []const u8,
};

test "writeAboutJson exposes product metadata" {
    var buf: [1024]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeAboutJson(out, true);

    const parsed = try std.json.parseFromSlice(AboutWire, std.testing.allocator, out.finishJson(), .{});
    defer parsed.deinit();
    const info = about.get(true);
    try std.testing.expectEqualStrings(info.name, parsed.value.name);
    try std.testing.expectEqualStrings(info.version, parsed.value.version);
    try std.testing.expectEqualStrings(info.commit, parsed.value.commit);
    try std.testing.expectEqualStrings(info.build_date, parsed.value.build_date);
    try std.testing.expectEqualStrings(info.copyright, parsed.value.copyright);
    try std.testing.expectEqualStrings(info.licence, parsed.value.licence);
    try std.testing.expectEqualStrings(info.summary, parsed.value.summary);
    try std.testing.expect(parsed.value.logo.len > 0);
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
        .menu = true,
        .save = true,
        .open = true,
        .new = true,
        .save_as = true,
    });
    const json = out.finishJson();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"undo\":false") != null);
}

test "writeLegendJson maps Legend export flag to wire export key" {
    var buf: [512]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeLegendJson(out, .{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .menu = true,
        .save = true,
        .open = true,
        .new = true,
        .@"export" = true,
        .save_as = true,
    });
    const json = out.finishJson();
    const wire_key = legend_mod.wire_export_json_key;
    try std.testing.expectEqualStrings("export", wire_key);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"export\":true") != null);
}

test "writeLegendJson includes paste flag" {
    var buf: [512]u8 = undefined;
    var len: u32 = 0;
    const out: OutBuffer = .{ .buf = &buf, .len = &len };
    try writeLegendJson(out, .{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .menu = true,
        .save = true,
        .open = true,
        .new = true,
        .paste = true,
        .save_as = true,
    });
    const json = out.finishJson();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"paste\":true") != null);
}

test "flow start parses each web flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.UnknownFlow, parseFlowStart(a, "{\"flow\":\"save\",\"name\":\"game.sud\"}"));
    try std.testing.expectError(error.UnknownFlow, parseFlowStart(a, "{\"flow\":\"autosave\"}"));
    try std.testing.expect((try parseFlowStart(a, "{\"flow\":\"autosave_flush\"}")) == .autosave_flush);
    try std.testing.expect((try parseFlowStart(a, "{\"flow\":\"startup\"}")).startup == null);
    const startup = (try parseFlowStart(a, "{\"flow\":\"startup\",\"path\":\"/current-file\",\"name\":\"g.sud\"}")).startup.?;
    try std.testing.expectEqualStrings("/current-file", startup.path);
    try std.testing.expectEqualStrings("g.sud", startup.name);
    try std.testing.expectError(error.MissingField, parseFlowStart(a, "{\"flow\":\"startup\",\"path\":\"/current-file\"}"));
    try std.testing.expectError(error.UnknownFlow, parseFlowStart(a, "{\"flow\":\"copy\"}"));
    try std.testing.expectError(error.UnknownFlow, parseFlowStart(a, "{\"flow\":\"nope\"}"));
}

test "flow input parses every step result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 2), (try parseFlowInput(a, "{\"input\":\"pressed\",\"index\":2}")).pressed);
    try std.testing.expectEqualStrings("d.sud", (try parseFlowInput(a, "{\"input\":\"default_target\",\"name\":\"d.sud\"}")).default_target);
    try std.testing.expectEqualStrings("w.sud", (try parseFlowInput(a, "{\"input\":\"wrote\",\"ok\":true,\"name\":\"w.sud\"}")).wrote.ok);
    try std.testing.expect((try parseFlowInput(a, "{\"input\":\"wrote\",\"ok\":false,\"cancelled\":true}")).wrote == .cancelled);
    try std.testing.expect((try parseFlowInput(a, "{\"input\":\"wrote\",\"ok\":false,\"exists\":true}")).wrote == .exists);
    try std.testing.expectEqualStrings("boom", (try parseFlowInput(a, "{\"input\":\"wrote\",\"ok\":false,\"error\":\"boom\"}")).wrote.failed);
    try std.testing.expectEqualStrings("123", (try parseFlowInput(a, "{\"input\":\"generated\",\"ok\":true,\"line\":\"123\"}")).generated.line);
    try std.testing.expect((try parseFlowInput(a, "{\"input\":\"generated\",\"ok\":false,\"cancelled\":true}")).generated == .cancelled);
    try std.testing.expectEqualStrings("x", (try parseFlowInput(a, "{\"input\":\"generated\",\"ok\":false,\"error\":\"x\"}")).generated.failed);
    try std.testing.expect((try parseFlowInput(a, "{\"input\":\"persisted\",\"ok\":true}")).persisted == .ok);
    try std.testing.expectEqualStrings("503", (try parseFlowInput(a, "{\"input\":\"persisted\",\"ok\":false,\"error\":\"503\"}")).persisted.failed);
    const taken = (try parseFlowInput(a, "{\"input\":\"wrote\",\"ok\":false,\"taken\":true,\"name\":\"sudoku.sud\"}")).wrote.taken;
    try std.testing.expectEqualStrings("sudoku.sud", taken.name);
    try std.testing.expect((try parseFlowInput(a, "{\"input\":\"copied\",\"ok\":true}")).copied == .ok);
    try std.testing.expectEqualStrings("denied", (try parseFlowInput(a, "{\"input\":\"copied\",\"ok\":false,\"error\":\"denied\"}")).copied.failed);
    try std.testing.expect((try parseFlowInput(a, "{\"input\":\"ack\"}")) == .ack);
    try std.testing.expect((try parseFlowInput(a, "{\"input\":\"read\",\"ok\":false,\"cancelled\":true}")).read == .cancelled);
    try std.testing.expectEqualStrings("no", (try parseFlowInput(a, "{\"input\":\"read\",\"ok\":false,\"error\":\"no\"}")).read.failed);
    try std.testing.expectError(error.MissingField, parseFlowInput(a, "{\"input\":\"read\",\"ok\":true}"));
}

test "step JSON carries the tag and its payload" {
    var buf: [8192]u8 = undefined;
    var len: u32 = 0;
    const out = OutBuffer{ .buf = &buf, .len = &len };
    try writeStepJson(out, .{ .prompt_message = .{ .type = .warning, .title = "T", .text = "Q?", .buttons = &.{ "A", "B", "C" }, .cancel = 0 } });
    try std.testing.expectEqualStrings("{\"step\":\"prompt_message\",\"type\":\"warning\",\"title\":\"T\",\"text\":\"Q?\",\"buttons\":[\"A\",\"B\",\"C\"],\"default\":2,\"dismiss\":0}", out.finishJson());
    try writeStepJson(out, .{ .prompt_message = .{ .type = .information, .title = "T", .text = "Q?", .buttons = &.{ "A", "B" } } });
    try std.testing.expectEqualStrings("{\"step\":\"prompt_message\",\"type\":\"information\",\"title\":\"T\",\"text\":\"Q?\",\"buttons\":[\"A\",\"B\"],\"default\":1,\"dismiss\":null}", out.finishJson());
    try writeStepJson(out, .{ .save_as = .{ .name = "a.sud", .replace = false } });
    try std.testing.expectEqualStrings("{\"step\":\"save_as\",\"name\":\"a.sud\",\"replace\":false}", out.finishJson());
    try writeStepJson(out, .{ .autosave = .{ .name = "a.sud", .replace = true } });
    try std.testing.expectEqualStrings("{\"step\":\"autosave\",\"name\":\"a.sud\",\"replace\":true}", out.finishJson());
    try writeStepJson(out, .{ .flush = "sudoku.sud" });
    try std.testing.expectEqualStrings("{\"step\":\"flush\",\"name\":\"sudoku.sud\"}", out.finishJson());
    try writeStepJson(out, .{ .export_puzzle = "p.txt" });
    try std.testing.expectEqualStrings("{\"step\":\"export_puzzle\",\"name\":\"p.txt\"}", out.finishJson());
    try writeStepJson(out, .reclaim_file);
    try std.testing.expectEqualStrings("{\"step\":\"reclaim_file\"}", out.finishJson());
    try writeStepJson(out, .copy_puzzle);
    try std.testing.expectEqualStrings("{\"step\":\"copy_puzzle\"}", out.finishJson());
    try writeStepJson(out, .done);
    try std.testing.expectEqualStrings("{\"step\":\"done\"}", out.finishJson());
    try writeStepJson(out, .{ .restore = "/current-file" });
    try std.testing.expectEqualStrings("{\"step\":\"restore\",\"path\":\"/current-file\"}", out.finishJson());
    var shown_engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.easy(), config.Config.default());
    defer shown_engine.deinit();
    shown_engine.selected = .{ .row = 1, .col = 2 };
    var shown = flow.step.showGame(&shown_engine, config.Config.default(), null, "g.sud");
    try writeStepJson(out, shown);
    const shown_json = out.finishJson();
    try std.testing.expect(std.mem.startsWith(u8, shown_json, "{\"step\":\"show_game\",\"text\":null,\"file\":\"g.sud\",\"state\":{"));
    try std.testing.expect(std.mem.indexOf(u8, shown_json, ",\"legend\":{\"fill\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown_json, ",\"config\":{\"difficulty\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown_json, "\"selected\":{\"row\":1,\"col\":2}") != null);
    shown.show_game.loaded = true;
    try writeStepJson(out, shown);
    try std.testing.expect(std.mem.endsWith(u8, out.finishJson(), ",\"loaded\":true}"));
    try writeStepJson(out, .{ .import_puzzle = null });
    try std.testing.expectEqualStrings("{\"step\":\"import_puzzle\",\"path\":null}", out.finishJson());
    try writeStepJson(out, .{ .open = "g.sud" });
    try std.testing.expectEqualStrings("{\"step\":\"open\",\"path\":\"g.sud\"}", out.finishJson());
    try writeStepJson(out, .paste_puzzle);
    try std.testing.expectEqualStrings("{\"step\":\"paste_puzzle\"}", out.finishJson());
    try writeStepJson(out, .{ .generate_game = .hard });
    try std.testing.expectEqualStrings("{\"step\":\"generate_game\",\"difficulty\":\"hard\"}", out.finishJson());
    try writeStepJson(out, .{ .forget_current_file = .{ .path = "/current-file", .delete = true } });
    try std.testing.expectEqualStrings("{\"step\":\"forget_current_file\",\"path\":\"/current-file\",\"delete\":true}", out.finishJson());
    var cfg = config.Config.default();
    cfg.theme = .light;
    try writeStepJson(out, .{ .persist_config = cfg });
    const json = out.finishJson();
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"step\":\"persist_config\",\"config\":{\"difficulty\":"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"theme\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "current_file") == null);
}
