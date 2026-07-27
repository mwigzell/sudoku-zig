
const std = @import("std");
const cell_module = @import("cell.zig");
const disambiguate = @import("disambiguate.zig");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const FillData = struct { row: u4, col: u4, digit: cell_module.CellValue };
pub const ClearData = struct { row: u4, col: u4 };
pub const SaveData = void;
pub const OpenData = struct { path: []const u8 };
pub const CommandTag = enum { fill, clear, quit, undo, redo, save, open };
/// Command a player can issue to the game.
pub const Command = union(CommandTag) {
    fill: FillData,
    clear: ClearData,
    quit: void,
    undo: void,
    redo: void,
    save: SaveData,
    open: OpenData,
};
pub const ParseResultTag = enum { valid, error_msg };

/// Result of parsing one line.
pub const ParseCommandResult = union(ParseResultTag) {
    valid: Command,
    error_msg: []const u8,
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const coordError: ParseCommandResult = .{
    .error_msg = "coordinate must be a letter (A-I) followed by a number (1-9)",
};

/// Trim → tokenize → re-dispatch through prefix dispatch (backward compat).
pub fn parse(input_line: []const u8) ParseCommandResult {
    const cmds = [_][]const u8{ "Fill", "Clear", "Quit", "Undo", "Redo", "Save", "Open" };
    return parseWithCommands(input_line, &cmds);
}


// ---------------------------------------------------------------------------
// Step 4 - Prefix dispatch
// ---------------------------------------------------------------------------

/// Case-insensitive prefix match up to `len` characters.
fn prefixMatch(a: []const u8, b: []const u8, len: usize) bool {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}


/// Dispatch resolved command name to its argument parser.
fn dispatchToParser(cmd_name: []const u8, it: anytype) ParseCommandResult {
    if (std.ascii.eqlIgnoreCase(cmd_name, "fill")) {
        const coord_str = it.next() orelse return .{.error_msg = "fill requires coordinate"};
        const digit_s = it.next() orelse return .{.error_msg = "fill requires digit"};
        return parseFill(coord_str, digit_s);
    }
    if (std.ascii.eqlIgnoreCase(cmd_name, "clear")) {
        const coord_s = it.next() orelse return .{.error_msg = "clear requires coordinate"};
        return parseClear(coord_s);
    }
    if (std.ascii.eqlIgnoreCase(cmd_name, "quit")) return parseQuit();
    if (std.ascii.eqlIgnoreCase(cmd_name, "undo")) return .{.valid = Command.undo};
    if (std.ascii.eqlIgnoreCase(cmd_name, "redo")) return .{.valid = Command.redo};
    if (std.ascii.eqlIgnoreCase(cmd_name, "save")) return parseSave();
    if (std.ascii.eqlIgnoreCase(cmd_name, "open")) {
        const path = it.next() orelse return .{.error_msg = "open requires file name"};
        return .{.valid = Command{.open = OpenData{.path = path}}};
    }

    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command: {s}", .{cmd_name}) catch unreachable;
    return .{.error_msg = msg};
}

/// Public entry point — accepts available command names for prefix dispatch.
pub fn parseWithCommands(input_line: []const u8, cmd_names: []const []const u8) ParseCommandResult {
    const trimmed = std.mem.trim(u8, input_line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{.error_msg = "empty input"};

    var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    const verb = it.next() orelse return .{.error_msg = "missing verb"};

const MaxMatchedCommands = 32;

    // Check each command for prefix match — collect matches to report ambiguity
    var matched_cmds: [MaxMatchedCommands][]const u8 = undefined;
    var match_count: usize = 0;
    for (cmd_names) |name| {
        const min_len = @min(verb.len, name.len);
        if (prefixMatch(verb, name, min_len)) {
            matched_cmds[match_count] = name;
            match_count += 1;
        }
    }
    switch (match_count) {
        0 => {
            var buf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "unknown command: {s}", .{verb}) catch unreachable;
            return .{.error_msg = msg};
        },
        1 => return dispatchToParser(matched_cmds[0], &it),
        else => {
            // Ambiguous — list matched commands
            return buildAmbiguityMessage(verb, matched_cmds[0..match_count]);
        },
    }
}
/// Quit takes no arguments.
fn parseQuit() ParseCommandResult {
    return .{.valid = Command.quit};
}

/// Save takes no arguments — just persist current game state.
fn parseSave() ParseCommandResult {
    return .{.valid = Command.save};
}
/// Fill requires a chess-style coordinate and a digit 1-9.
fn parseFill(coord_str: []const u8, digit_s: []const u8) ParseCommandResult {
    const pos = parseCoordinate(coord_str) orelse return coordError;
    const dch = digit_s[0];
    if (dch < '1' or dch > '9') return errorBadDigit(digit_s);

    return .{.valid = Command{
        .fill = FillData{
            .row = pos.row,
            .col = pos.col,
            .digit = cell_module.rawToCellValue(dch - '0'),
        },
    }};
}

/// Clear requires a chess-style coordinate.
fn parseClear(cmd_coord_s: []const u8) ParseCommandResult {
    const pos = parseCoordinate(cmd_coord_s) orelse return coordError;
    return .{.valid = Command{
        .clear = ClearData{.row = pos.row, .col = pos.col},
    }};
}

/// Parse a chess-style coordinate (e.g. "A1") into row/col indices 0-8.
fn parseCoordinate(s: []const u8) ?ClearData {
    if (s.len != 2) return null;
    const col_l = std.ascii.toLower(s[0]);
    const row_d = s[1];
    if (col_l < 'a' or col_l > 'i') return null;
    if (row_d < '1' or row_d > '9') return null;
    return .{.row = @intCast(row_d - '1'), .col = @intCast(col_l - 'a')};
}

/// Build an error result for a bad digit token.
fn errorBadDigit(val: []const u8) ParseCommandResult {
    var buf: [40]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid digit: '{s}'", .{val}) catch unreachable;
    return .{.error_msg = msg};
}
/// Build an ambiguity message listing which commands matched the typed prefix.
fn buildAmbiguityMessage(verb: []const u8, matched: []const []const u8) ParseCommandResult {
    var buf: [256]u8 = undefined;
    var offset: usize = 0;

    const prefix_msg = std.fmt.bufPrint(buf[offset..], "ambiguous command \"{s}\" — matches: ", .{verb}) catch unreachable;
    offset += prefix_msg.len;

    for (matched, 0..) |name, i| {
        if (i > 0) {
            const comma = std.fmt.bufPrint(buf[offset..], ", ", .{}) catch unreachable;
            offset += comma.len;
        }
        const name_msg = std.fmt.bufPrint(buf[offset..], "{s}", .{name}) catch unreachable;
        offset += name_msg.len;
    }

    return .{.error_msg = buf[0..offset]};
}

// ---------------------------------------------------------------------------
// Tests — T1: parser returns correct tagged unions
// ---------------------------------------------------------------------------

test "parse fill command A1 7 → .valid with row 0, col 0, digit seven" {
    const res = parse("fill A1 7");
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqual(@as(u4, 0), res.valid.fill.row);
    try std.testing.expectEqual(@as(u4, 0), res.valid.fill.col);
    try std.testing.expectEqual(cell_module.CellValue.seven, res.valid.fill.digit);
}

test "parse clear command C3 → .valid clear at row 2 col 2" {
    const res = parse("clear C3");
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqual(@as(u4, 2), res.valid.clear.row);
    try std.testing.expectEqual(@as(u4, 2), res.valid.clear.col);
}

test "parse quit → .valid quit" {
    const res = parse("quit");
    if (res != .valid) return error.TestFailed;
}

test "parse empty line → .error_msg" {
    const res = parse("   ");
    if (res == .error_msg) {
        try std.testing.expectEqualStrings(res.error_msg, "empty input");
    } else {
        return error.TestFailed;
    }
}

test "parse unknown verb → .error_msg describing the issue" {
    const res = parse("foobar");
    if (res != .error_msg) return error.TestFailed;
}

test "parse fill with out-of-range column (J1) → .error_msg" {
    const res = parse("fill J1 5");
    if (res != .error_msg) return error.TestFailed;
}

test "parse fill with out-of-range row (A0) → .error_msg" {
    const res = parse("fill A0 5");
    if (res != .error_msg) return error.TestFailed;
}

test "parse fill A1 with non-digit value → .error_msg" {
    const res = parse("fill A1 X");
    if (res != .error_msg) return error.TestFailed;
}

test "parse fill with malformed coordinate (extra chars) → .error_msg" {
    const res = parse("fill ABC 5");
    if (res != .error_msg) return error.TestFailed;
}

test "parse clear with out-of-range column (J3) → .error_msg" {
    const res = parse("clear J3");
    if (res != .error_msg) return error.TestFailed;
}

test "parse clear with out-of-range row (C0) → .error_msg" {
    const res = parse("clear C0");
    if (res != .error_msg) return error.TestFailed;
}

test "parse clear with single-char coordinate → .error_msg" {
    const res = parse("clear Z");
    if (res != .error_msg) return error.TestFailed;
}

test "parse error cases return .error_msg tag (not .invalid_message)" {
    // This test proves the rename: all error paths use .error_msg.
    const empty = parse("");
    if (empty != .error_msg) return error.TestFailed;  // was .invalid_message

    const unknown = parse("foobar");
    if (unknown != .error_msg) return error.TestFailed;

    const bad_coord = parse("fill J1 5");
    if (bad_coord != .error_msg) return error.TestFailed;

    const bad_digit = parse("fill A1 X");
    if (bad_digit != .error_msg) return error.TestFailed;
}

test "parse undo command (upper U) → .valid .undo" {
    const res = parse("U");
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "undo");
}

test "parse undo command (lower u) → .valid .undo" {
    const res = parse("u");
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "undo");
}

test "parse redo command (upper R) → .valid .redo" {
    const res = parse("R");
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "redo");
}

test "parse redo command (lower r) → .valid .redo" {
    const res = parse("r");
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "redo");
}

// ---------------------------------------------------------------------------



test "parseWithCommands: partial prefix resolves to Fill" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Quit" };
    const res = parseWithCommands("f A1 7", &cmds);
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "fill");
    try std.testing.expectEqual(@as(u4, 0), res.valid.fill.row);
}

test "parseWithCommands: u resolves to Undo naturally" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Undo", "Quit" };
    const res = parseWithCommands("u", &cmds);
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "undo");
}

test "parseWithCommands: r resolves to Redo naturally" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Redo", "Quit" };
    const res = parseWithCommands("r", &cmds);
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "redo");
}

test "parseWithCommands: single-char q resolves to Quit" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Undo", "Redo", "Quit" };
    const res = parseWithCommands("q", &cmds);
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "quit");
}

test "parseWithCommands: unknown verb returns error_msg" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Quit" };
    const res = parseWithCommands("foobar", &cmds);
    if (res != .error_msg) return error.TestFailed;
}

test "parseWithCommands: fill missing arguments still errors" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Quit" };
    const res = parseWithCommands("fi A1", &cmds);
    if (res != .error_msg) return error.TestFailed;
}


test "parseWithCommands: ambiguous prefix returns error_msg listing matched commands" {
    const cmds = [_][]const u8{ "Redo", "Repeat", "Fill", "Quit" };
    const res = parseWithCommands("Re", &cmds);
    try std.testing.expect(res == .error_msg);
    // Error message should mention which commands matched (Redo and Repeat)
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg, "Redo") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_msg, "Repeat") != null);
}


test "parseWithCommands: Fi A1 3 resolves to Fill (mixed case prefix)" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Quit" };
    const res = parseWithCommands("Fi A1 3", &cmds);
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "fill");
    try std.testing.expectEqual(@as(u4, 0), res.valid.fill.row);
    try std.testing.expectEqual(@as(u4, 0), res.valid.fill.col);
    try std.testing.expectEqual(cell_module.CellValue.three, res.valid.fill.digit);
}

test "parseWithCommands: FI B2 5 resolves to Fill (all caps prefix)" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Quit" };
    const res = parseWithCommands("FI B2 5", &cmds);
    if (res != .valid) return error.TestFailed;
    try std.testing.expectEqualStrings(@tagName(res.valid), "fill");
    try std.testing.expectEqual(@as(u4, 1), res.valid.fill.row);
    try std.testing.expectEqual(@as(u4, 1), res.valid.fill.col);
    try std.testing.expectEqual(cell_module.CellValue.five, res.valid.fill.digit);
}
test "parse save command → .valid .save" {
    const res = parse("save");
    try std.testing.expect(res == .valid);
    try std.testing.expectEqualStrings(@tagName(res.valid), "save");
}
test "parse open command with bare name → .valid with correct path" {
    const res = parse("open my_game");
    try std.testing.expect(res == .valid);
    try std.testing.expectEqualStrings(@tagName(res.valid), "open");
    try std.testing.expectEqualStrings(res.valid.open.path, "my_game");
}
test "save with trailing tokens still returns .save" {
    const res = parse("save extra");
    try std.testing.expect(res == .valid);
    try std.testing.expectEqualStrings(@tagName(res.valid), "save");
}
test "open with missing path returns .error_msg" {
    const res = parse("open");
    try std.testing.expect(res == .error_msg);
}
test "open with absolute path → .valid with full path" {
    const res = parse("open /home/user/game.dat");
    try std.testing.expect(res == .valid);
    try std.testing.expectEqualStrings(@tagName(res.valid), "open");
    try std.testing.expectEqualStrings(res.valid.open.path, "/home/user/game.dat");
}
test "parseWithCommands: sa resolves to Save with Save in commands" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Quit", "Undo", "Redo", "Save", "Open" };
    const res = parseWithCommands("sa", &cmds);
    try std.testing.expect(res == .valid);
    try std.testing.expectEqualStrings(@tagName(res.valid), "save");
}

test "parseWithCommands: op resolves to Open with Open in commands" {
    const cmds = [_][]const u8{ "Fill", "Clear", "Quit", "Undo", "Redo", "Save", "Open" };
    const res = parseWithCommands("op my_save", &cmds);
    try std.testing.expect(res == .valid);
    try std.testing.expectEqualStrings(@tagName(res.valid), "open");
    try std.testing.expectEqualStrings(res.valid.open.path, "my_save");
}
