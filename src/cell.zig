const std = @import("std");

/// Possible values for a single Sudoku cell. 0 means empty; 1–9 is the digit placed.
pub const CellValue = enum(u4) {
    zero,   // empty
    one,    // digit 1
    two,    // digit 2
    three,  // digit 3
    four,   // digit 4
    five,   // digit 5
    six,    // digit 6
    seven,  // digit 7
    eight,  // digit 8
    nine,   // digit 9
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

/// A single position on the 9×9 board holding a value and a given flag.
pub const Cell = struct {
    value: CellValue,
    given: bool,

    /// Create a Cell with explicit initial value and given flag.
    pub fn init(initial_value: CellValue, is_given: bool) Cell {
        return .{
            .value = initial_value,
            .given = is_given,
        };
    }

    /// Return the display character for this cell's value (0x20 for empty, '1'–'9' otherwise).
    pub fn charOf(self: @This()) u8 {
        return displayChar(self.value);
    }
};

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Cell: init produces non-given cell with given value" {
    const c = Cell.init(.zero, false);
    try std.testing.expect(c.value == .zero);
    try std.testing.expect(!c.given);
}

test "Cell: given cell retains its digit" {
    const c = Cell.init(.eight, true);
    try std.testing.expect(c.value == .eight);
    try std.testing.expect(c.given);
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
    var c = Cell.init(.zero, false);
    try std.testing.expectEqual(0x20, c.charOf());

    c.value = .four;
    try std.testing.expectEqual('4', c.charOf());

    c.value = .nine;
    try std.testing.expectEqual('9', c.charOf());
}
