// Shell adapter: puzzle_gen progress events → Facade (session writer).
const std = @import("std");
const facade_mod = @import("../../core/renderer/facade.zig");
const command = @import("../../core/command.zig");
const config = @import("../../core/config.zig");
const legend_mod = @import("../../core/renderer/legend.zig");
const logger = @import("../../core/logger.zig");
const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");
const flow_step = @import("../../core/flow/step.zig");

const log = logger.Logger(.gen_progress);

/// Forwards generator progress from puzzle-gen to the active native Facade.
pub fn playProgressToFacade(gen_event: puzzle_gen.GenProgressEvent, ctx: ?*anyopaque) void {
    const facade: *const facade_mod.Facade = @ptrCast(@alignCast(ctx.?));
    facade.reportGenProgress(gen_event) catch |err| {
        log.warn("generation progress not shown: {s}", .{@errorName(err)});
    };
}

const ProgressRecorder = struct {
    called: bool = false,
    last: ?puzzle_gen.GenProgressEvent = null,

    fn render(_: *anyopaque, _: facade_mod.Frame) facade_mod.Error!void {}
    fn showLegend(_: *anyopaque, _: legend_mod.Legend) facade_mod.Error!void {}
    fn promptMessage(_: *anyopaque, prompt: flow_step.PromptMessage) facade_mod.Error!usize {
        return prompt.defaultAnswer();
    }
    fn getCommandInput(
        _: *anyopaque,
        _: []const []const u8,
        _: config.Config,
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
        .promptMessage_fn = ProgressRecorder.promptMessage,
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
