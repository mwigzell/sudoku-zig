// Wasm deploy entry — the app itself, distinct from main(). Same shared core
// as the native binary: the bootstrap's Config in, the page's capability
// imports bound to WasmHost/WasmTransport, and the shared Sudoku's
// game driven between the two. The game lives for the process: main()
// boots it and shows the first screen, step() advances one command at
// time per page event.
const std = @import("std");
const config = @import("config.zig");
const sudoku_mod = @import("sudoku.zig");
const wasm_host = @import("host/wasm_host.zig");
const wasm_renderer = @import("renderer/wasm/wasm_renderer.zig");
const wasm_transport = @import("engine/wasm_transport.zig");
const facade_mod = @import("renderer/facade.zig");

// The boundary: each supplied value is its own import. A new Config value the
// page supplies = one import + one override line below; renderer choices never
// cross (native only, Config.default() stands).
extern fn bootstrap_difficulty() u32;
extern fn page_line_in(buf: [*]u8, cap: u32) callconv(.c) u32;
extern fn page_bytes_out(bytes: [*]const u8, len: u32) callconv(.c) void;
extern fn page_picker(buf: [*]u8, cap: u32) callconv(.c) u32;
extern fn page_file_write(name: [*]const u8, name_len: u32, bytes: [*]const u8, bytes_len: u32) callconv(.c) void;
extern fn page_file_read(name: [*]const u8, name_len: u32, buf: [*]u8, cap: u32) callconv(.c) u32;

// The game lives for the wasm process: main() boots it here, step() turns it.
var host: wasm_host.WasmHost = undefined;
var facade: facade_mod.Facade = undefined;
var game: sudoku_mod.Sudoku = undefined;

pub fn main() void {
    var cfg = config.Config.default();
    cfg.difficulty = @enumFromInt(bootstrap_difficulty());

    // Bind the page's capabilities into the shared substrate + the wasm transport arm.
    host = wasm_host.WasmHost.make(page_line_in, page_bytes_out, page_picker, page_file_write, page_file_read);
    const transport = wasm_transport.WasmTransport.make(page_file_write, page_file_read);

    // The module's own linear memory heap; nothing is passed from the page.
    const A = std.heap.page_allocator;
    const renderer = A.create(wasm_renderer.WasmRenderer) catch unreachable;
    renderer.* = wasm_renderer.WasmRenderer.init(A, &host);
    facade = facade_mod.Make(wasm_renderer.WasmRenderer).make(renderer);

    game = sudoku_mod.Sudoku.init(cfg, facade, transport) catch {
        facade.deinit();
        return;
    };

    // The first screen (board + legend) is handed to the page; each command turn after that
    // is supplied by step().
    _ = game.renderer.render(game.engine.eventBoard(), null) catch {};
    _ = game.renderer.showLegend(game.engine.getLegend()) catch {};
}

/// One command turn: the page's line in, the resulting screen byte sequence out
/// to the sink. 1 if the session is finished (quit — or the turn errored, and since
/// the page only branches on this flag, an error collapses to finished), 0 to continue.
export fn step(line_ptr: [*]u8, line_len: u32) u32 {
    wasm_host.WasmHost.queueLine(line_ptr[0..line_len]);
    const done = game.wasm_run() catch true;
    return @intFromBool(done);
}
