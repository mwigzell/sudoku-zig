// Wasm deployment entry — the app itself, other main(). Same shared core as
// the native binary: bootstrap Config in, the page's capability imports bound
// into WasmHost/WasmTransport, the shared Sudoku loop driven between them.
const std = @import("std");
const config = @import("src/config.zig");
const sudoku_mod = @import("src/sudoku.zig");
const wasm_host = @import("src/host/wasm_host.zig");
const wasm_renderer = @import("src/renderer/wasm/wasm_renderer.zig");
const wasm_transport = @import("src/engine/wasm_transport.zig");
const facade_mod = @import("src/renderer/facade.zig");

// The boundary: each supplied value is its own import. A new Config value the
// page supplies = one import + one override line below; renderer choices never
// cross (native only, Config.default() stands).
extern fn bootstrap_difficulty() u32;
extern fn page_line_in(buf: [*]u8, cap: u32) callconv(.c) u32;
extern fn page_bytes_out(bytes: [*]const u8, len: u32) callconv(.c) void;
extern fn page_picker(buf: [*]u8, cap: u32) callconv(.c) u32;
extern fn page_file_write(name: [*]const u8, name_len: u32, bytes: [*]const u8, bytes_len: u32) callconv(.c) void;
extern fn page_file_read(name: [*]const u8, name_len: u32, buf: [*]u8, cap: u32) callconv(.c) u32;

pub fn main() void {
    var cfg = config.Config.default();
    cfg.difficulty = @enumFromInt(bootstrap_difficulty());

    // Page capabilities bound into the shared substrate + the wasm transport arm.
    const host = wasm_host.WasmHost.make(page_line_in, page_bytes_out, page_picker, page_file_write, page_file_read);
    const transport = wasm_transport.WasmTransport.make(page_file_write, page_file_read);

    // The module's own linear-memory heap; nothing crosses in from the page.
    const A = std.heap.page_allocator;
    const renderer = A.create(wasm_renderer.WasmRenderer) catch unreachable;
    renderer.* = wasm_renderer.WasmRenderer.init(A, &host);
    var facade = facade_mod.Make(wasm_renderer.WasmRenderer).make(renderer);

    var game = sudoku_mod.Sudoku.init(cfg, facade, transport) catch {
        facade.deinit();
        return;
    };

    game.run() catch {};

    game.deinit();
    facade.deinit();
}
