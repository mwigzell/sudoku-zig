const std = @import("std");

/// Count non-overlapping occurrences of needle in haystack.
pub fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < haystack.len) {
        const idx = std.mem.indexOf(u8, haystack[start..], needle) orelse break;
        count += 1;
        start += idx + needle.len;
    }
    return count;
}
