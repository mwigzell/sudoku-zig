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

/// A single position on the 9×9 board holding a value and a locked flag.
pub const Cell = struct {
    value: CellValue,
    locked: bool,

    /// Create a Cell with given initial value; locked defaults to false.
    pub fn init(initial_value: CellValue) Cell {
        return .{
            .value = initial_value,
            .locked = false,
        };
    }

    /// Return the display character for this cell's value (0x20 for empty, '1'–'9' otherwise).
    pub fn charOf(self: @This()) u8 {
        return switch (self.value) {
            .zero => 0x20,
            else => @as(u8, @intFromEnum(self.value)) + '0',
        };
    }
};

// ---------------------------------------------------------------------------
// Tests (co-located, Ziglings 105 style)
// ---------------------------------------------------------------------------

test "Cell: init produces unlocked cell with given value" {
    const c = Cell.init(.zero);
    try std.testing.expect(c.value == .zero);
    try std.testing.expect(!c.locked);
}

test "Cell: locked given cell retains its digit" {
    var c = Cell.init(.eight);
    c.locked = true;
    try std.testing.expect(c.value == .eight);
    try std.testing.expect(c.locked);
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
