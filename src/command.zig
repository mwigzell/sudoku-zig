const cell_module = @import("board/cell.zig");

// ---------------------------------------------------------------------------
// Command Data Types — domain-neutral, consumed by GameEngine.exec()
// ---------------------------------------------------------------------------

pub const FillData = struct { row: u4, col: u4, digit: cell_module.CellValue };
pub const ClearData = struct { row: u4, col: u4 };
pub const SaveData = struct { path: ?[]const u8 };

pub const OpenData = struct { path: ?[]const u8 };
pub const NewData = struct { puzzle: ?[]const u8 };

pub const CommandTag = enum { fill, clear, quit, undo, redo, save, open, new, save_as };

/// Command a player can issue to the game.
pub const Command = union(CommandTag) {
    fill: FillData,
    clear: ClearData,
    quit: void,
    undo: void,
    redo: void,
    save: SaveData,
    open: OpenData,
    new: NewData,
    save_as: SaveData,
};

pub const ParseResultTag = enum { valid, error_msg };

/// Result of parsing one line.
pub const ParseCommandResult = union(ParseResultTag) {
    valid: Command,
    error_msg: []const u8,
};

// ---------------------------------------------------------------------------
// Comptime command registration table (Issue 30)
// ---------------------------------------------------------------------------

pub const CommandTableEntry = struct {
    tag: CommandTag,
    name: []const u8,
};

/// Ordered comptime list of all supported commands.
pub const Commands = &[_]CommandTableEntry{
    .{ .tag = .fill, .name = "Fill" },
    .{ .tag = .clear, .name = "Clear" },
    .{ .tag = .quit, .name = "Quit" },
    .{ .tag = .undo, .name = "Undo" },
    .{ .tag = .redo, .name = "Redo" },
    .{ .tag = .save, .name = "Save" },
    .{ .tag = .open, .name = "Open" },
    .{ .tag = .new, .name = "New" },
    .{ .tag = .save_as, .name = "SaveAs" },
};

/// Look up the display name for a command tag from the comptime table.
pub fn getName(tag: CommandTag) []const u8 {
    for (Commands) |entry|
        if (entry.tag == tag) return entry.name;
    @panic("unreachable: unknown command tag");
}

// ---------------------------------------------------------------------------
// Dialog results — renderer returns these after user interaction
// ---------------------------------------------------------------------------

/// Result of a save dialog interaction.
pub const SaveFileResult = union(enum) {
    FileName: []u8, // Owned allocated filename to save to
    Cancelled,
};

/// Result of an open dialog interaction.
pub const OpenFileResult = SaveFileResult;

/// Result of a new-game puzzle dialog interaction.
pub const PuzzleResult = union(enum) {
    PuzzleString: []u8, // Owned puzzle string — renderer decides source
    Cancelled,
};

// ---------------------------------------------------------------------------
// Tests — types are correct and getName works
// ---------------------------------------------------------------------------

const std = @import("std");

test "CommandTag enum has 9 variants" {
    const info = @typeInfo(CommandTag).@"enum";
    try std.testing.expectEqual(@as(usize, 9), info.field_names.len);
}

test "getName returns correct display name for each tag" {
    try std.testing.expectEqualStrings("Fill", getName(.fill));
    try std.testing.expectEqualStrings("Clear", getName(.clear));
    try std.testing.expectEqualStrings("Quit", getName(.quit));
    try std.testing.expectEqualStrings("Undo", getName(.undo));
    try std.testing.expectEqualStrings("Redo", getName(.redo));
    try std.testing.expectEqualStrings("Save", getName(.save));
    try std.testing.expectEqualStrings("Open", getName(.open));
    try std.testing.expectEqualStrings("SaveAs", getName(.save_as));
}

test "comptime invariant: CommandTag enum fields == Commands table length" {
    const enum_field_count = @typeInfo(CommandTag).@"enum".field_names.len;
    try std.testing.expectEqual(enum_field_count, Commands.len);
}
