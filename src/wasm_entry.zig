// Wasm deploy entry — structured JSON exports for the browser shell (#31).
const std = @import("std");
const game_engine = @import("engine/game_engine.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const logger = @import("logger.zig");
const boundary = @import("wasm/boundary.zig");
const wire = @import("wasm/wire.zig");

const OutCap = 65536;
var out_buf: [OutCap]u8 = undefined;
var out_len: u32 = 0;

var engine: game_engine.GameEngine = undefined;
var have_engine: bool = false;

fn outBuffer() boundary.OutBuffer {
    return .{ .buf = &out_buf, .len = &out_len };
}

fn engineOrError(out: boundary.OutBuffer) ?*game_engine.GameEngine {
    if (!have_engine) {
        boundary.writeErrorJson(out, "not initialized") catch {};
        return null;
    }
    return &engine;
}

/// Bootstrap a fresh game from wire difficulty + log level (see wire.BootstrapConfig).
export fn init(difficulty: u32, log_level: u32) callconv(.c) u32 {
    const out = outBuffer();
    const cfg = wire.BootstrapConfig.fromWire(@intCast(difficulty), @intCast(log_level)) orelse {
        boundary.writeErrorJson(out, "invalid bootstrap config") catch {};
        return @intFromPtr(out.finishJson().ptr);
    };

    logger.min_level = cfg.log_level;
    if (have_engine) engine.deinit();

    const puzzle_str = puzzle_gen.PuzzleGen.generate(cfg.difficulty.toPuzzleDifficulty());
    engine = game_engine.GameEngine.init(puzzle_str) catch {
        boundary.writeErrorJson(out, "engine init failed") catch {};
        return @intFromPtr(out.finishJson().ptr);
    };
    have_engine = true;

    boundary.writeOkJson(out) catch {
        boundary.writeErrorJson(out, "response write failed") catch {};
    };
    return @intFromPtr(out.finishJson().ptr);
}

/// Run one gameplay action described by a JSON payload in wasm memory.
export fn exec(in_ptr: u32, in_len: u32) callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return @intFromPtr(out.finishJson().ptr);

    const json = @as([*]const u8, @ptrFromInt(in_ptr))[0..in_len];
    const cmd = boundary.parseAction(json) catch {
        boundary.writeErrorJson(out, "invalid action") catch {};
        return @intFromPtr(out.finishJson().ptr);
    };

    const ev = eng.exec(cmd);
    boundary.writeEventJson(out, ev) catch {
        boundary.writeErrorJson(out, "response write failed") catch {};
    };
    return @intFromPtr(out.finishJson().ptr);
}

/// Current command availability flags as JSON.
export fn getLegend() callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return @intFromPtr(out.finishJson().ptr);
    boundary.writeLegendJson(out, eng.getLegend()) catch {
        boundary.writeErrorJson(out, "response write failed") catch {};
    };
    return @intFromPtr(out.finishJson().ptr);
}

/// Current board snapshot as JSON (GameSnapshot wire shape).
export fn getState() callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return @intFromPtr(out.finishJson().ptr);
    boundary.writeStateJson(out, eng.eventBoard()) catch {
        boundary.writeErrorJson(out, "response write failed") catch {};
    };
    return @intFromPtr(out.finishJson().ptr);
}

/// Serialize full game state to SUD0 bytes in the shared out buffer; returns byte length.
export fn serialize() callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return 0;

    const bytes = eng.toSaveFormat(std.heap.page_allocator) catch {
        out.reset();
        return 0;
    };
    defer std.heap.page_allocator.free(bytes);

    if (bytes.len > out.buf.len) {
        out.reset();
        return 0;
    }
    out.reset();
    @memcpy(out.buf[0..bytes.len], bytes);
    out.len.* = @intCast(bytes.len);
    return @intCast(bytes.len);
}

/// Replace game state from SUD0 bytes in wasm memory; returns JSON status ptr.
export fn deserialize(in_ptr: u32, in_len: u32) callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return @intFromPtr(out.finishJson().ptr);

    const bytes = @as([*]const u8, @ptrFromInt(in_ptr))[0..in_len];
    eng.loadSaveFormat(bytes) catch {
        boundary.writeErrorJson(out, "deserialize failed") catch {};
        return @intFromPtr(out.finishJson().ptr);
    };

    boundary.writeOkJson(out) catch {
        boundary.writeErrorJson(out, "response write failed") catch {};
    };
    return @intFromPtr(out.finishJson().ptr);
}

/// Pointer to the shared out buffer (JSON NUL-terminated or SUD0 bytes from serialize).
export fn outPtr() callconv(.c) u32 {
    return @intFromPtr(&out_buf);
}

pub fn main() void {}
