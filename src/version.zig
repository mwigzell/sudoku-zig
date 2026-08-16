const std = @import("std");

/// App version — the product itself, distinct from SaveFileVersion
/// (engine/save_format.zig) which versions the save-file wire format.
pub const major: u16 = 0;
pub const minor: u16 = 1;
pub const patch: u16 = 0;

pub const string: []const u8 = std.fmt.comptimePrint(
    "{d}.{d}.{d}",
    .{ major, minor, patch },
);

test "string matches component parts" {
    try std.testing.expectEqualStrings("0.1.0", string);
    const expected = std.fmt.comptimePrint("{d}.{d}.{d}", .{ major, minor, patch });
    try std.testing.expectEqualStrings(expected, string);
}
