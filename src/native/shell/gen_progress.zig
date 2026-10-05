// Shell adapter: puzzle_gen progress events → Facade (session writer).
const std = @import("std");
const facade_mod = @import("../../renderer/facade.zig");
const board = @import("../../board/board.zig");
const command = @import("../../command.zig");
const config = @import("../../config.zig");
const event_mod = @import("../../event.zig");
const legend_mod = @import("../../renderer/legend.zig");
const logger = @import("../../logger.zig");
const puzzle_gen = @import("../../puzzle_gen/mod.zig");

/// Forwards generator progress from puzzle-gen to the active native Facade.
pub fn playProgressToFacade(gen_event: puzzle_gen.GenProgressEvent, ctx: ?*anyopaque) void {
    const facade: *const facade_mod.Facade = @ptrCast(@alignCast(ctx.?));
    facade.reportGenProgress(gen_event) catch {};
}

const ProgressRecorder = struct {
    called: bool = false,
    last: ?puzzle_gen.GenProgressEvent = null,

    fn render(_: *anyopaque, _: board.Board.BoardView, _: ?[]const u8, _: ?event_mod.CellCoord) facade_mod.Error!void {}
    fn showLegend(_: *anyopaque, _: legend_mod.Legend) facade_mod.Error!void {}
    fn showError(_: *anyopaque, _: []const u8) facade_mod.Error!void {}
    fn getCommandInput(
        _: *anyopaque,
        _: []const []const u8,
        _: bool,
        _: bool,
        _: config.Difficulty,
        _: logger.Severity,
        _: config.ViewTheme,
        _: bool,
        _: bool,
        _: bool,
        _: ?event_mod.CellCoord,
    ) facade_mod.Error!command.ParseCommandResult {
        return .{ .valid = .{ .quit = {} } };
    }
    fn reportGenProgress(ctx: *anyopaque, gen_event: puzzle_gen.GenProgressEvent) facade_mod.Error!void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.last = gen_event;
    }
    fn deinit(_: *anyopaque) void {}
};

fn makeFacade(rec: *ProgressRecorder) facade_mod.Facade {
    return .{
        .context = @ptrCast(@alignCast(rec)),
        .render_fn = ProgressRecorder.render,
        .showLegend_fn = ProgressRecorder.showLegend,
        .showError_fn = ProgressRecorder.showError,
        .getCommandInput_fn = ProgressRecorder.getCommandInput,
        .report_gen_progress_fn = ProgressRecorder.reportGenProgress,
        .deinit_fn = ProgressRecorder.deinit,
    };
}

test "playProgressToFacade forwards event to Facade.reportGenProgress" {
    var recorder = ProgressRecorder{};
    var facade = makeFacade(&recorder);

    playProgressToFacade(.{ .attempt = .{ .n = 3, .max = 16 } }, @ptrCast(&facade));

    try std.testing.expect(recorder.called);
    const got = recorder.last.?;
    switch (got) {
        .attempt => |a| {
            try std.testing.expectEqual(@as(u16, 3), a.n);
            try std.testing.expectEqual(@as(u16, 16), a.max);
        },
        else => return error.TestUnexpectedResult,
    }
}
