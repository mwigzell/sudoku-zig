//! Legend entity — which commands a game state can show, and their names in
//! main-line order. The terminal's own line formatting lives in the terminal.

const std = @import("std");
const command = @import("../command.zig");

/// Wasm `getLegend()` JSON property for File → Export (`export` is a Zig keyword — use `Legend.@"export"`).
pub const wire_export_json_key = "export";

/// Legend entity — which commands are displayable in the current game state.
pub const Legend = struct {
    fill: bool,
    clear: bool,
    hint: bool = false,
    quit: bool,
    undo: bool,
    redo: bool,
    /// Rewind to Bookmark: on only when a bookmark sits behind the current move.
    rewind: bool = false,
    menu: bool,
    save: bool,
    open: bool,
    new: bool,
    save_as: bool,
    /// Session menu: import a one-line puzzle file (web).
    import: bool = false,
    /// Session menu: export current grid as a one-line puzzle file (web). Wire key: `wire_export_json_key`.
    @"export": bool = false,
    /// Edit menu: copy current grid as a one-line puzzle string (web clipboard).
    copy: bool = false,
    /// Edit menu: paste a one-line puzzle from the clipboard (web).
    paste: bool = false,
    /// Menu Solve. Off when the board is full or has any conflict.
    solve: bool = false,
    /// Terminal line: toggle a pencil mark (web and Android toggle marks with Pencil mode).
    pencil: bool = false,

    /// Fill `names` with main-line terminal commands (play loop + menu entry).
    pub fn getNames(self: Legend, names: *[command.Commands.len][]const u8) usize {
        var count: usize = 0;
        if (self.fill) {
            names[count] = command.getName(.fill);
            count += 1;
        }
        if (self.pencil) {
            names[count] = command.getName(.pencil);
            count += 1;
        }
        if (self.clear) {
            names[count] = command.getName(.clear);
            count += 1;
        }
        if (self.hint) {
            names[count] = command.getName(.hint);
            count += 1;
        }
        if (self.quit) {
            names[count] = command.getName(.quit);
            count += 1;
        }
        if (self.undo) {
            names[count] = command.getName(.undo);
            count += 1;
        }
        if (self.redo) {
            names[count] = command.getName(.redo);
            count += 1;
        }
        // Bookmark is always offered: pinning the position you are on is always possible.
        names[count] = command.getName(.bookmark);
        count += 1;
        // Rewind joins the line only when a bookmark sits behind the current move.
        if (self.rewind) {
            names[count] = command.getName(.rewind);
            count += 1;
        }
        if (self.menu) {
            names[count] = command.getName(.menu);
            count += 1;
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Tests (co-located)
// ---------------------------------------------------------------------------

/// A main-line legend with every command on; `rewind` is the only thing the tests vary.
fn mainLineLegend(rewind: bool) Legend {
    return .{
        .fill = true,
        .pencil = true,
        .clear = true,
        .hint = true,
        .quit = true,
        .undo = true,
        .redo = true,
        .menu = true,
        .save = true,
        .open = true,
        .new = true,
        .save_as = true,
        .rewind = rewind,
    };
}

/// Whether the drawn line holds `wanted`.
fn hasName(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, wanted)) return true;
    return false;
}

test "getNames: main line offers menu not session commands" {
    var names: [command.Commands.len][]const u8 = undefined;
    const count = (Legend{
        .fill = true,
        .pencil = true,
        .clear = true,
        .hint = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .menu = true,
        .save = true,
        .open = true,
        .new = true,
        .save_as = true,
    }).getNames(&names);
    try std.testing.expectEqual(@as(usize, 7), count);
    try std.testing.expectEqualStrings("Pencil", names[1]);
    try std.testing.expectEqualStrings("Hint", names[3]);
    try std.testing.expectEqualStrings("Bookmark", names[5]);
    try std.testing.expectEqualStrings("Menu", names[6]);
}

test "getNames: Bookmark is always offered, Rewind only when it can act" {
    var names: [command.Commands.len][]const u8 = undefined;
    const offered = mainLineLegend(true).getNames(&names);
    try std.testing.expect(hasName(names[0..offered], "Bookmark"));
    try std.testing.expect(hasName(names[0..offered], "Rewind"));
    // Rewind reads next to Undo and Redo, ahead of the Menu entry that stays last.
    try std.testing.expectEqualStrings("Rewind", names[8]);
    try std.testing.expectEqualStrings("Menu", names[offered - 1]);

    const plain = mainLineLegend(false).getNames(&names);
    try std.testing.expectEqual(offered - 1, plain);
    try std.testing.expect(hasName(names[0..plain], "Bookmark"));
    try std.testing.expect(!hasName(names[0..plain], "Rewind"));
    try std.testing.expectEqualStrings("Menu", names[plain - 1]);
}
