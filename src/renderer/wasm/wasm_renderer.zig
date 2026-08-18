//! Stub web renderer — canned responses prove the Facade vtable accepts a
//! second concrete renderer before the real browser layer exists.

const std = @import("std");
const testing = std.testing;
const command = @import("../../command.zig");
const cell = @import("../../board/cell.zig");
const board = @import("../../board.zig");
const legend = @import("../legend.zig");
const facade_mod = @import("../facade.zig");

/// Canned-response renderer for the web slot. Every method exists so the
/// Facade vtable flows through a second concrete type; responses are stubs.
pub const WasmRenderer = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) WasmRenderer {
        return .{ .alloc = alloc };
    }

    pub fn render(self: *WasmRenderer, view: board.Board.BoardView, status_msg: ?[]const u8) facade_mod.Error!void {
        _ = self;
        _ = view;
        _ = status_msg;
    }

    pub fn showLegend(self: *WasmRenderer, commands: legend.Legend) facade_mod.Error!void {
        _ = self;
        _ = commands;
    }

    pub fn showError(self: *WasmRenderer, msg: []const u8) facade_mod.Error!void {
        _ = self;
        _ = msg;
    }

    /// Stub input: one fixed fill command, always valid.
    pub fn getCommandInput(self: *const WasmRenderer, _names: []const []const u8) facade_mod.Error!command.ParseCommandResult {
        _ = self;
        _ = _names;
        return .{ .valid = .{
            .fill = .{ .row = 0, .col = 0, .digit = cell.CellValue.one },
        } };
    }

    /// Self-destroy contract: the facade deinit chains to this and is
    /// the renderer's only destruction path.
    pub fn deinit(self: *WasmRenderer) void {
        self.alloc.destroy(self);
    }
};

test "WasmRenderer facade: getCommandInput always returns the hardcoded fill" {
    const alloc = testing.allocator;
    // No writer: the web slot outputs through the browser bridge, not the
    // host I/O session. init takes the allocator only (destroys itself).
    const r_ptr = try alloc.create(WasmRenderer);
    defer alloc.destroy(r_ptr);
    r_ptr.* = WasmRenderer.init(alloc);
    const r = r_ptr;
    const F = facade_mod.Make(WasmRenderer);
    var f = F.make(r);

    const names = [_][]const u8{ "Fill", "Clear", "Quit" };
    const result = try f.getCommandInput(&names);
    switch (result) {
        .valid => |cmd| {
            switch (cmd) {
                .fill => |fill| {
                    try std.testing.expectEqual(@as(u4, 0), fill.row);
                    try std.testing.expectEqual(@as(u4, 0), fill.col);
                    try std.testing.expectEqual(cell.CellValue.one, fill.digit);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}
