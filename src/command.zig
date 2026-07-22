const std = @import("std");
const cell_module = @import("cell.zig");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const FillData = struct { row: u4, col: u4, digit: cell_module.CellValue };
pub const ClearData = struct { row: u4, col: u4 };
pub const CommandTag = enum { fill, clear, quit, undo, redo };

/// Command a player can issue to the game.
pub const Command = union(CommandTag) {
    fill: FillData,
    clear: ClearData,
    quit: void,
    undo: void,
    redo: void,
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

/// Trim → tokenize → dispatch verb → unknown-fallback.
pub fn parse(input_line: []const u8) ParseCommandResult {
    const trimmed = std.mem.trim(u8, input_line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{.error_msg = "empty input"};

    var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    const verb = it.next() orelse return .{.error_msg = "missing verb"};


    if (trimmed.len == 1) {
        const c = std.ascii.toUpper(trimmed[0]);
        switch (c) {
            'U' => {
                return .{.valid = Command.undo};
            },
            'R' => {
                return .{.valid = Command.redo};
            },
            else => {},
        }
    }
    if (std.ascii.eqlIgnoreCase(verb, "quit")) {
        return parseQuit();
    }
    if (std.ascii.eqlIgnoreCase(verb, "fill")) {
        const coord_str = it.next() orelse return .{.error_msg = "fill requires coordinate"};
        const digit_s = it.next() orelse return .{.error_msg = "fill requires digit"};
        return parseFill(coord_str, digit_s);
    }
    if (std.ascii.eqlIgnoreCase(verb, "clear")) {
        const coord_s = it.next() orelse return .{.error_msg = "clear requires coordinate"};
        return parseClear(coord_s);
    }

    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command: {s}", .{verb}) catch unreachable;
    return .{.error_msg = msg};
}

/// Quit takes no arguments.
fn parseQuit() ParseCommandResult {
    return .{.valid = Command.quit};
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
