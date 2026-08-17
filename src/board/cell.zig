const std = @import("std");

/// Possible values for a single Sudoku cell. 0 means empty; 1–9 is the digit placed.
pub const CellValue = enum(u4) {
    zero, // empty
    one, // digit 1
    two, // digit 2
    three, // digit 3
    four, // digit 4
    five, // digit 5
    six, // digit 6
    seven, // digit 7
    eight, // digit 8
    nine, // digit 9
};

/// Map a raw u8 (0–9) to the corresponding CellValue.
pub fn rawToCellValue(raw: u8) CellValue {
    return switch (raw) {
        0 => .zero,
        1 => .one,
        2 => .two,
        3 => .three,
        4 => .four,
        5 => .five,
        6 => .six,
        7 => .seven,
        8 => .eight,
        9 => .nine,
        else => unreachable,
    };
}

/// Display character for a CellValue (space for empty, '1'–'9' otherwise).
pub fn displayChar(cv: CellValue) u8 {
    return switch (cv) {
        .zero => 0x20,
        else => @as(u8, @intFromEnum(cv)) + '0',
    };
}

/// A single position on the board holding a value.
/// "Given" status lives in Board.given_bits — Cell is dumb data only.
pub const Cell = struct {
    value: CellValue,

    /// Create a Cell with an initial value.
    pub fn init(initial_value: CellValue) Cell {
        return .{ .value = initial_value };
    }

    /// Return the display character for this cell's value (0x20 for empty, '1'–'9' otherwise).
    pub fn charOf(self: @This()) u8 {
        return displayChar(self.value);
    }
};

// ---------------------------------------------------------------------------
// Tests (co-located)
// ---------------------------------------------------------------------------

test "Cell: init produces empty cell" {
    const c = Cell.init(.zero);
    try std.testing.expect(c.value == .zero);
}

test "Cell: retains its digit after init" {
    const c = Cell.init(.eight);
    try std.testing.expect(c.value == .eight);
}

test "rawToCellValue maps 0..9 to correct CellValue enum members" {
    const expected: []const CellValue = &.{
        .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine,
    };

    for (0..10) |i| {
        try std.testing.expect(expected[i] == rawToCellValue(@intCast(i)));
    }
}

test "Cell charOf returns display character" {
    var c = Cell.init(.zero);
    try std.testing.expectEqual(0x20, c.charOf());

    c.value = .four;
    try std.testing.expectEqual('4', c.charOf());

    c.value = .nine;
    try std.testing.expectEqual('9', c.charOf());
}
