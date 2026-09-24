// Command vocabulary of the game — data tags + parse entry point.
const cell_module = @import("board/cell.zig");
const config = @import("config.zig");

// ---------------------------------------------------------------------------
// Command Data Types — domain-neutral, consumed by GameEngine.exec()
// ---------------------------------------------------------------------------

pub const FillData = struct { row: u4, col: u4, digit: cell_module.CellValue };
pub const ClearData = struct { row: u4, col: u4 };
pub const SaveData = struct { path: ?[]const u8 };

pub const OpenData = struct { path: ?[]const u8 };
pub const NewData = struct { puzzle: ?[]const u8 };
pub const ImportData = struct { path: ?[]const u8 };

pub const CommandTag = enum { fill, clear, quit, undo, redo, menu, save, open, import, new, save_as, solve_for_me, set_theme, set_region };

/// Command a player can issue to the game.
pub const Command = union(CommandTag) {
    fill: FillData,
    clear: ClearData,
    quit: void,
    undo: void,
    redo: void,
    menu: void,
    save: SaveData,
    open: OpenData,
    import: ImportData,
    new: NewData,
    save_as: SaveData,
    solve_for_me: void,
    set_theme: config.ViewTheme,
    set_region: bool,
};

pub const ParseResultTag = enum { valid, error_msg };

/// Result of parsing one line.
pub const ParseCommandResult = union(ParseResultTag) {
    valid: Command,
    error_msg: []const u8,
};

// ---------------------------------------------------------------------------
// Comptime command registration table
// ---------------------------------------------------------------------------

pub const CommandTableEntry = struct {
    tag: CommandTag,
    name: []const u8,
};

/// Main-line terminal legend and prefix dispatch.
pub const Commands = &[_]CommandTableEntry{
    .{ .tag = .fill, .name = "Fill" },
    .{ .tag = .clear, .name = "Clear" },
    .{ .tag = .quit, .name = "Quit" },
    .{ .tag = .undo, .name = "Undo" },
    .{ .tag = .redo, .name = "Redo" },
    .{ .tag = .menu, .name = "Menu" },
};

/// Session commands reachable from the terminal menu (not main-line legend).
pub const SessionCommands = &[_]CommandTableEntry{
    .{ .tag = .save, .name = "Save" },
    .{ .tag = .open, .name = "Open" },
    .{ .tag = .import, .name = "Import" },
    .{ .tag = .new, .name = "New" },
    .{ .tag = .save_as, .name = "SaveAs" },
    .{ .tag = .solve_for_me, .name = "Solve" },
};

/// Look up the display name for a command tag from the comptime tables.
pub fn getName(tag: CommandTag) []const u8 {
    for (Commands) |entry|
        if (entry.tag == tag) return entry.name;
    for (SessionCommands) |entry|
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

/// Result of an import dialog interaction.
pub const ImportFileResult = SaveFileResult;
/// The outcome of a difficulty dialog at New — the user picks a level and the engine generates.
pub const PuzzleResult = union(enum) {
    PuzzleString: []u8, // Owned puzzle string for the chosen difficulty
    Cancelled,
};

// ---------------------------------------------------------------------------
// Tests — types are correct and getName works
// ---------------------------------------------------------------------------

const std = @import("std");

test "CommandTag enum has 14 variants" {
    const info = @typeInfo(CommandTag).@"enum";
    try std.testing.expectEqual(@as(usize, 14), info.field_names.len);
}

test "getName returns correct display name for each tag" {
    try std.testing.expectEqualStrings("Fill", getName(.fill));
    try std.testing.expectEqualStrings("Clear", getName(.clear));
    try std.testing.expectEqualStrings("Quit", getName(.quit));
    try std.testing.expectEqualStrings("Undo", getName(.undo));
    try std.testing.expectEqualStrings("Redo", getName(.redo));
    try std.testing.expectEqualStrings("Menu", getName(.menu));
    try std.testing.expectEqualStrings("Save", getName(.save));
    try std.testing.expectEqualStrings("Open", getName(.open));
    try std.testing.expectEqualStrings("Import", getName(.import));
    try std.testing.expectEqualStrings("SaveAs", getName(.save_as));
    try std.testing.expectEqualStrings("Solve", getName(.solve_for_me));
}

test "comptime invariant: CommandTag covers terminal line plus session and view prefs" {
    const enum_field_count = @typeInfo(CommandTag).@"enum".field_names.len;
    // Commands + SessionCommands + set_theme/set_region cover all CommandTag variants.
    try std.testing.expectEqual(enum_field_count, Commands.len + SessionCommands.len + 2);
}
