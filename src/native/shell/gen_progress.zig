// Shell adapter: puzzle_gen progress events → Facade (session writer).
const facade_mod = @import("../../renderer/facade.zig");
const puzzle_gen = @import("../../puzzle_gen/mod.zig");

pub fn playProgressToFacade(event: puzzle_gen.GenProgressEvent, ctx: ?*anyopaque) void {
    const facade: *const facade_mod.Facade = @ptrCast(@alignCast(ctx.?));
    facade.reportGenProgress(event) catch {};
}
