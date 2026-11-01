// Shared test check that text a dialog shows reads as a full sentence.
const std = @import("std");

/// Fails unless `text` starts with a capital letter and ends with `.` or `?`.
pub fn expectSentence(text: []const u8) !void {
    if (isSentence(text)) return;
    std.debug.print("not a sentence: \"{s}\"\n", .{text});
    return error.TestExpectedSentence;
}

fn isSentence(text: []const u8) bool {
    return text.len > 1 and std.ascii.isUpper(text[0]) and (text[text.len - 1] == '.' or text[text.len - 1] == '?');
}

test "isSentence accepts sentences and rejects fragments" {
    try std.testing.expect(isSentence("There is nothing to undo."));
    try std.testing.expect(isSentence("Do you want to replace it?"));
    try std.testing.expect(!isSentence("save failed"));
    try std.testing.expect(!isSentence("game.sud already exists. Do you want to replace it?"));
    try std.testing.expect(!isSentence("Nothing to undo"));
}
