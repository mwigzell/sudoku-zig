const std = @import("std");
const cell = @import("cell.zig");
const renderer = @import("renderer.zig");
const puzzle_gen = @import("puzzle_gen.zig");

/// Board dimension — a standard Sudoku grid is 9×9.
pub const DIMENSION_SIZE: u8 = 9;
pub const CELL_COUNT = DIMENSION_SIZE * DIMENSION_SIZE;

/// The canonical 9×9 Sudoku board state, backed by flat `[81]Cell` storage.
pub const Board = struct {
    cells: [CELL_COUNT]cell.Cell,

    /// Create an empty Board (all zeros, nothing given).
    pub fn init() Board {
        var b: Board = undefined;
        for (0..BOARD_CELL_COUNT) |i| {
            b.cells[i] = cell.Cell.init(.zero, false);
        }
        return b;
    }

    /// Return a mutable pointer to the Cell at (row, col).
    pub fn cellAt(self: *Board, row: u4, col: u4) *cell.Cell {
        const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
        return &self.cells[idx];
    }

    /// Set the value of a cell. Does not change its given flag.
    pub fn setCell(self: *Board, row: u4, col: u4, value: cell.CellValue) void {
        self.cellAt(row, col).value = value;
    }

    /// Clear a cell back to empty and reset its given flag.
    pub fn clearCell(self: *Board, row: u4, col: u4) void {
        self.cellAt(row, col).* = cell.Cell.init(.zero, false);
    }

    /// Walk the flat cells and produce a render-ready snapshot of every cell's
    /// value, lock state, and conflict flag. Returns an owned RenderSnapshot;
    /// safe to discard after renderer consumes it.
    pub fn assembleRenderSnapshot(self: *Board) renderer.RenderSnapshot {
        var snap: renderer.RenderSnapshot = undefined;
        for (0..DIMENSION_SIZE) |row| {
            for (0..DIMENSINION_SIZE) |col| {
                const idx: usize = @as(usize, @intCast(row)) * DIMENSION_SIZE + @as(usize, @intCast(col));
                snap.cells[row][col] = renderer.RenderCell{
                    .value = self.cells[idx].value,
                    .locked = self.cells[idx].given,
                    .conflicting = false, // validator not yet shipped
                };
            }
        }
        return snap;
    }
};

/// Errors returned when parsing puzzle data into a Board.
pub const BoardError = error{
    /// A cell value outside the 0–9 range was found.
    BadCellValue,
    /// The one-line string is not exactly 81 characters.
    WrongLength,
    /// An unrecognised character appeared in the one-line string.
    InvalidCharacter,
};

/// Construct a Board from a flat 81-element u8 array.
/// Values 0 mean empty/unlocked; values 1–9 are given digits and locked.
/// Returns an error if any cell value is outside 0–9.
pub fn fromFlat(flat: [81]u8) BoardError!Board {
    for (flat) |v| {
        if (v > 9) return BoardError.BadCellValue;
    }

    var b = Board.init();
    for (flat, 0..) |v, i| {
        const globalRow: u4 = @intCast(@divTrunc(i, 9));
        const globalCol: u4 = @intCast(@mod(i, 9));
        if (v != 0) {
            const idx: usize = @as(usize, @intCast(globalRow)) * DIMENSION_SIZE + @as(usize, @intCast(globalCol));
            b.cells[idx] = cell.Cell.init(cell.rawToCellValue(v), true);
        }
    }
    return b;
}

/// Construct a Board from a one-line Sudoku string like "53..7........6.....98..".
/// Digits '1'–'9' are locked givens; '.' or '0' are empty/unlocked.
/// Returns an error if the string is not exactly 81 characters
/// or contains any character outside those ranges.
pub fn fromOneLineString(oneLine: []const u8) BoardError!Board {
    if (oneLine.len != 81) return BoardError.WrongLength;

    var flat: [81]u8 = undefined;
    for (oneLine, 0..) |ch, i| {
        flat[i] = switch (ch) {
            '.' => 0,
            '0' => 0,
            '1'...'9' => ch - '0',
            else => return BoardError.InvalidCharacter,
        };
    }
    return fromFlat(flat);
}

