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

pub fn parse(input_line: []const u8) ParseCommandResult {
    const trimmed = std.mem.trim(u8, input_line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .invalid_message = "empty input" };

    var it = std.mem.tokenizeAny(u8, trimmed, &std.ascii.whitespace);
    const verb = it.next() orelse return .{ .invalid_message = "missing verb" };

        if (std.ascii.eqlIgnoreCase(verb, "quit")) {
            return .{ .valid = Command{ .quit = {} } };
        }

    if (std.ascii.eqlIgnoreCase(verb, "fill")) {
        const coord_str = it.next() orelse return .{ .invalid_message = "fill requires coordinate" };
        const digit_s = it.next() orelse return .{ .invalid_message = "fill requires digit" };

        if (coord_str.len != 2) return coordError;
        const col_l = std.ascii.toLower(coord_str[0]);
        const row_d = coord_str[1];
        const c: u4 = @intCast(col_l - 'a');
        if (c > 8) return errorColOutOfRange(coord_str);
        const r: u4 = @intCast(row_d - '1');
        if (r > 8) return errorRowOutOfRange(coord_str);

        const dch = digit_s[0];
        if (dch < '1' or dch > '9') {
            return errorBadDigit(digit_s);
        }
        const fill_data = Command{
            .fill = FillData{ .row = r, .col = c, .digit = cell_module.rawToCellValue(dch - '0') },
        };
        return .{.valid = fill_data};
    }

    if (std.ascii.eqlIgnoreCase(verb, "clear")) {
        const coord_s = it.next() orelse return .{ .invalid_message = "clear requires coordinate" };
        if (coord_s.len != 2) return coordError;
        const c: u4 = @intCast(std.ascii.toLower(coord_s[0]) - 'a');
        const r: u4 = @intCast(coord_s[1] - '1');
        if (r > 8) return errorRowOutOfRange(coord_s);

        const clear_data: ClearData = .{.row = r, .col = c};
        return .{
            .valid = Command{.clear = clear_data},
        };
    }

    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command: {s}", .{verb}) catch unreachable;
    return .{ .invalid_message = msg };
}

fn errorColOutOfRange(coord: []const u8) ParseCommandResult {
    var buf: [40]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "column out of range: {s}", .{coord}) catch unreachable;
    return .{ .invalid_message = msg };
}

fn errorRowOutOfRange(coord: []const u8) ParseCommandResult {
    var buf: [40]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "row out of range: {s}", .{coord}) catch unreachable;
    return .{ .invalid_message = msg };
}

fn errorBadDigit(val: []const u8) ParseCommandResult {
    var buf: [40]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid digit: '{s}'", .{val}) catch unreachable;
    return .{ .invalid_message = msg };
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

test "parse fill with out-of-range coordinates (J1) → .invalid_message" {
    const res = parse("fill J1 5");
    if (res != .invalid_message) return error.TestFailed;
    try std.testing.expectEqualStrings(res.invalid_message, "column out of range: J1");
}

test "parse fill A1 with non-digit value → .invalid_message" {
    const res = parse("fill A1 X");
    if (res != .invalid_message) return error.TestFailed;
    try std.testing.expectEqualStrings(res.invalid_message, "invalid digit: 'X'");
}

test "parse fill with malformed coordinate (extra chars) → .invalid_message" {
    const res = parse("fill ABC 5");
    if (res != .invalid_message) return error.TestFailed;
}

test "parse clear with single-char coordinate → .invalid_message" {
    const res = parse("clear Z");
    if (res != .invalid_message) return error.TestFailed;
}
