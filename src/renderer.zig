const cell = @import("cell.zig");

/// A single cell's render-relevant state.
/// Copied from the live Board into RenderSnapshot for renderer consumption.
pub const RenderCell = struct {
    value: cell.CellValue,
    locked: bool,
    conflicting: bool,
};

/// Flat 9×9 snapshot of board state.
/// Owned by the callee — safe to discard after render completes.
pub const RenderSnapshot = struct {
    cells: [9][9]RenderCell,
};
