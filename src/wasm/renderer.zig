//! Web renderer — the facade surface for the browser deployment. Methods exist
//! with the vtable signatures; the page (WasmHost) is the I/O substrate.
const std = @import("std");
const command = @import("../command.zig");
const cell = @import("../board/cell.zig");
const board = @import("../board/board.zig");
const legend = @import("../renderer/legend.zig");
const facade_mod = @import("../renderer/facade.zig");
const wasm_host = @import("host.zig");
const wasm_transport = @import("transport.zig");
const ascii_mod = @import("../native/ascii/renderer.zig");
const styler_mod = @import("../native/ascii/styler.zig");
const parser_mod = @import("../native/ascii/parser.zig");
const disambiguate_mod = @import("../native/ascii/disambiguate.zig");

const testing = std.testing;
const A = testing.allocator;

pub const WasmRenderer = struct {
    alloc: std.mem.Allocator,
    host: *const wasm_host.WasmHost,

    pub fn init(alloc: std.mem.Allocator, host: *const wasm_host.WasmHost) WasmRenderer {
        return .{ .alloc = alloc, .host = host };
    }

    pub fn render(self: *WasmRenderer, view: board.Board.BoardView, status_msg: ?[]const u8) facade_mod.Error!void {
        _ = status_msg; // reserved for a status bar, same as the native ascii renderer
        var buf: [1024]u8 = undefined;
        var n: usize = 0;
        n = appendInto(&buf, n, ascii_mod.columnHeader()) catch return facade_mod.Error.System;
        n = appendInto(&buf, n, ascii_mod.topBorder()) catch return facade_mod.Error.System;

        var styler: styler_mod.PlainStyler = .{};
        for (0..9) |row| {
            var rowBuf: [256]u8 = undefined;
            const line = styler.formatRow(row, view, &rowBuf) catch return facade_mod.Error.System;
            n = appendInto(&buf, n, line) catch return facade_mod.Error.System;
            if (row == 2 or row == 5) {
                n = appendInto(&buf, n, ascii_mod.midBorder()) catch return facade_mod.Error.System;
            }
        }

        n = appendInto(&buf, n, ascii_mod.bottomBorder()) catch return facade_mod.Error.System;
        self.host.writeScreen(buf[0..n]);
    }

    pub fn showLegend(self: *WasmRenderer, commands: legend.Legend) facade_mod.Error!void {
        var names: [9][]const u8 = undefined;
        const count = commands.getNames(&names);

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();

        const entries = disambiguate_mod.getMinimumPrefixes(arena.allocator(), names[0..count]) catch return facade_mod.Error.System;
        const str = legend.formatLegend(arena.allocator(), entries) catch return facade_mod.Error.System;

        var buf: [1024]u8 = undefined;
        var n: usize = 0;
        n = appendInto(&buf, n, "  Command: ") catch return facade_mod.Error.System;
        n = appendInto(&buf, n, str) catch return facade_mod.Error.System;
        n = appendInto(&buf, n, "\n") catch return facade_mod.Error.System;
        self.host.writeScreen(buf[0..n]);
    }

    pub fn showError(self: *WasmRenderer, msg: []const u8) facade_mod.Error!void {
        // The page owns the "Press Enter" prompt — never block on readLine here.
        self.host.writeScreen(msg);
    }

    pub fn getCommandInput(self: *const WasmRenderer, names: []const []const u8) error{ReadEOF}!command.ParseCommandResult {
        const line = self.host.readLine() orelse return error.ReadEOF;
        if (names.len == 0) {
            return .{ .error_msg = "no commands available" };
        }
        return parser_mod.parseWithCommands(line, names);
    }

    /// Self-destroy contract: the facade deinit chains to this and is
    /// the renderer's only destruction path.
    pub fn deinit(self: *WasmRenderer) void {
        self.alloc.destroy(self);
    }
};

/// Grow a bounded stack buffer; the overflow error is folded into
/// facade_mod.Error.System by the callers.
fn appendInto(buf: []u8, n: usize, s: []const u8) error{BufferOverflow}!usize {
    if (n + s.len > buf.len) return error.BufferOverflow;
    @memcpy(buf[n .. n + s.len], s);
    return n + s.len;
}

// ────────────────────── test mocks (page stand-ins) ──────────────────────
var out_mock: [4096]u8 = undefined;
var out_len: u32 = 0;
var line_mock: [64]u8 = undefined;
var line_len: u32 = 0;
var name_mock: [64]u8 = undefined;
var name_len: u32 = 0;

fn reset() void {
    out_len = 0;
    line_mock = undefined;
    line_len = 0;
    name_mock = undefined;
    name_len = 0;
}

fn serveLine(s: []const u8) void {
    @memcpy(line_mock[0..s.len], s);
    line_len = @intCast(s.len);
}

fn mock_line_in(buf: [*]u8, cap: u32) callconv(.c) u32 {
    const n = @min(line_len, cap);
    @memcpy(buf[0..n], line_mock[0..n]);
    line_len = 0; // one line served — a second call reads EOF.
    return n;
}
fn mock_bytes_out(bytes: [*]const u8, len: u32) callconv(.c) void {
    @memcpy(out_mock[0..len], bytes[0..len]);
    out_len = len;
}
fn mock_picker(buf: [*]u8, cap: u32) callconv(.c) u32 {
    const n = @min(name_len, cap);
    @memcpy(buf[0..n], name_mock[0..n]);
    name_len = n;
    return n;
}

fn testHost() *const wasm_host.WasmHost {
    const host = A.create(wasm_host.WasmHost) catch unreachable;
    host.* = wasm_host.WasmHost.make(
        mock_line_in,
        mock_bytes_out,
        mock_picker,
        wasm_transport.test_file_write,
        wasm_transport.test_file_read,
    );
    return host;
}

test "wasm_renderer: getCommandInput parses a fill line from the page" {
    reset();
    serveLine("fill A3 4");
    const host = testHost();
    defer A.destroy(host);
    var r = A.create(WasmRenderer) catch unreachable;
    defer A.destroy(r);
    r.* = WasmRenderer.init(A, host);
    const result = try r.getCommandInput(&.{ "Fill", "Clear", "Quit" });
    switch (result) {
        .valid => |cmd| switch (cmd) {
            .fill => |fill| {
                try testing.expectEqual(@as(u4, 2), fill.row);
                try testing.expectEqual(@as(u4, 0), fill.col);
                try testing.expectEqual(cell.CellValue.four, fill.digit);
            },
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }
}

test "wasm_renderer: getCommandInput maps a garbage verb to error_msg" {
    reset();
    serveLine("florp A3 4");
    const host = testHost();
    defer A.destroy(host);
    var r = A.create(WasmRenderer) catch unreachable;
    defer A.destroy(r);
    r.* = WasmRenderer.init(A, host);
    const result = try r.getCommandInput(&.{ "Fill", "Clear", "Quit" });
    switch (result) {
        .error_msg => |msg| try testing.expect(msg.len > 0),
        else => try testing.expect(false),
    }
}

test "wasm_renderer: getCommandInput surfaces page EOF as ReadEOF" {
    reset(); // page serves no line at all
    const host = testHost();
    defer A.destroy(host);
    var r = A.create(WasmRenderer) catch unreachable;
    defer A.destroy(r);
    r.* = WasmRenderer.init(A, host);
    try testing.expectError(error.ReadEOF, r.getCommandInput(&.{"Fill"}));
}

test "wasm_renderer: render writes the full board through the page sink" {
    reset();
    const host = testHost();
    defer A.destroy(host);
    var r = A.create(WasmRenderer) catch unreachable;
    defer A.destroy(r);
    r.* = WasmRenderer.init(A, host);
    const b = board.Board.init();
    try r.render(b.asView(), null);
    try testing.expectEqualStrings(
        "   A B C │ D E F │ G H I \n" ++
            " ╭───────┼───────┼───────╮\n" ++
            "1│       │       │       │\n" ++
            "2│       │       │       │\n" ++
            "3│       │       │       │\n" ++
            " ├───────┼───────┼───────┤\n" ++
            "4│       │       │       │\n" ++
            "5│       │       │       │\n" ++
            "6│       │       │       │\n" ++
            " ├───────┼───────┼───────┤\n" ++
            "7│       │       │       │\n" ++
            "8│       │       │       │\n" ++
            "9│       │       │       │\n" ++
            " ╰───────┴───────┴───────╯\n",
        out_mock[0..out_len],
    );
}

test "wasm_renderer: showLegend writes the command legend through the page sink" {
    reset();
    const host = testHost();
    defer A.destroy(host);
    var r = A.create(WasmRenderer) catch unreachable;
    defer A.destroy(r);
    r.* = WasmRenderer.init(A, host);
    const cmds = legend.Legend{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .save = false,
        .open = false,
        .new = false,
        .save_as = false,
    };
    try r.showLegend(cmds);
    try testing.expect(std.mem.indexOf(u8, out_mock[0..out_len], "Command:") != null);
    try testing.expect(std.mem.indexOf(u8, out_mock[0..out_len], "(F)ill") != null);
    try testing.expect(std.mem.indexOf(u8, out_mock[0..out_len], "(C)lear") != null);
    try testing.expect(std.mem.indexOf(u8, out_mock[0..out_len], "(Q)uit") != null);
}

test "wasm_renderer: showError writes the message through the page sink" {
    reset();
    const host = testHost();
    defer A.destroy(host);
    var r = A.create(WasmRenderer) catch unreachable;
    defer A.destroy(r);
    r.* = WasmRenderer.init(A, host);
    try r.showError("something went wrong");
    try testing.expect(std.mem.indexOf(u8, out_mock[0..out_len], "something went wrong") != null);
}
