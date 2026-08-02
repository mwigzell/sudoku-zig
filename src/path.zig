

const std = @import("std");

fn getHomeDir(gpa: std.mem.Allocator) ![]u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const entry_raw = std.c.environ[i] orelse break;
        const entry = std.mem.sliceTo(entry_raw, 0);
        if (std.mem.indexOfScalarPos(u8, entry, 0, '=')) |eq| {
            if (eq == 4 and std.mem.eql(u8, entry[0..eq], "HOME")) {
                return gpa.dupe(u8, entry[eq + 1 ..]);
            }
        }
    }
    return error.EnvironmentVariableMissing;


}
test "getHomeDir returns HOME" {
    const gpa = std.heap.page_allocator;
    const home = try getHomeDir(gpa);
    defer gpa.free(home);

    // Invariant: starts with /home/ or /root
    std.debug.assert(home.len > 0);
    std.debug.assert(std.mem.startsWith(u8, home, "/"));
    std.debug.assert(!std.mem.eql(u8, home, ""));
}
