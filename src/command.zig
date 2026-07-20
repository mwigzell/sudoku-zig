const std = @import("std");
const cell_module = @import("cell.zig");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

const FillData = struct { row: u4, col: u4, digit: cell_module.CellValue };
const ClearData = struct { row: u4, col: u4 };
pub const CommandTag = enum { fill, clear, quit };

/// Command a player can issue to the game.
pub const Command = union(CommandTag) {
    fill: FillData,
    clear: ClearData,
    quit: void,
};

pub const ParseResultTag = enum { valid, invalid_message };

/// Result of parsing one line.
pub const ParseCommandResult = union(ParseResultTag) {
    valid: Command,
    invalid_message: []const u8,
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const coordError: ParseCommandResult = .{
    .invalid_message = "coordinate must be a letter (A-I) followed by a number (1-9)",
};

/// Trim → tokenize → dispatch verb → unknown-fallback.
pub fn parse(input_line: []const u8) ParseCommandResult {
    const trimmed = std.mem.trim(u8, input_line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{.invalid_message = "empty input"};

    var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    const verb = it.next() orelse return .{.invalid_message = "missing verb"};

    if (std.ascii.eqlIgnoreCase(verb, "quit")) {
        return parseQuit();
    }
    if (std.ascii.eqlIgnoreCase(verb, "fill")) {
        const coord_str = it.next() orelse return .{.invalid_message = "fill requires coordinate"};
        const digit_s = it.next() orelse return .{.invalid_message = "fill requires digit"};
        return parseFill(coord_str, digit_s);
    }
    if (std.ascii.eqlIgnoreCase(verb, "clear")) {
        const coord_s = it.next() orelse return .{.invalid_message = "clear requires coordinate"};
        return parseClear(coord_s);
    }

    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command: {s}", .{verb}) catch unreachable;
    return .{.invalid_message = msg};
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
    return .{.invalid_message = msg};
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

test "parse empty line → .invalid_message" {
    const res = parse("   ");
    if (res == .invalid_message) {
        try std.testing.expectEqualStrings(res.invalid_message, "empty input");
    } else {
        return error.TestFailed;
    }
}

test "parse unknown verb → .invalid_message describing the issue" {
    const res = parse("foobar");
    if (res != .invalid_message) return error.TestFailed;
}

test "parse fill with out-of-range column (J1) → .invalid_message" {
    const res = parse("fill J1 5");
    if (res != .invalid_message) return error.TestFailed;
}

test "parse fill with out-of-range row (A0) → .invalid_message" {
    const res = parse("fill A0 5");
    if (res != .invalid_message) return error.TestFailed;
}

test "parse fill A1 with non-digit value → .invalid_message" {
    const res = parse("fill A1 X");
    if (res != .invalid_message) return error.TestFailed;
}

test "parse fill with malformed coordinate (extra chars) → .invalid_message" {
    const res = parse("fill ABC 5");
    if (res != .invalid_message) return error.TestFailed;
}

test "parse clear with out-of-range column (J3) → .invalid_message" {
    const res = parse("clear J3");
    if (res != .invalid_message) return error.TestFailed;
}

test "parse clear with out-of-range row (C0) → .invalid_message" {
    const res = parse("clear C0");
    if (res != .invalid_message) return error.TestFailed;
}

test "parse clear with single-char coordinate → .invalid_message" {
    const res = parse("clear Z");
    if (res != .invalid_message) return error.TestFailed;
}
