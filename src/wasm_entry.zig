// Wasm deploy entry — structured JSON exports for the browser shell.
// Boundary failures propagate to JS only via out_buf JSON, never stderr.
const std = @import("std");
const game_engine = @import("engine/game_engine.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const logger = @import("logger.zig");
const boundary = @import("wasm/boundary.zig");
const wire = @import("wasm/wire.zig");
const config = @import("config.zig");

const OutCap = 65536;
var out_buf: [OutCap]u8 = undefined;
var out_len: u32 = 0;

var engine: game_engine.GameEngine = undefined;
var have_engine: bool = false;

fn outBuffer() boundary.OutBuffer {
    return .{ .buf = &out_buf, .len = &out_len };
}

fn returnJson(out: boundary.OutBuffer) u32 {
    return @intFromPtr(out.finishJson().ptr);
}

fn writeErrorBestEffort(out: boundary.OutBuffer, msg: []const u8) void {
    boundary.writeErrorJson(out, msg) catch {
        boundary.writeSystemErrorJson(out);
    };
}

fn exportError(out: boundary.OutBuffer, msg: []const u8) u32 {
    writeErrorBestEffort(out, msg);
    return returnJson(out);
}

fn exportWriteFailed(out: boundary.OutBuffer) u32 {
    writeErrorBestEffort(out, "response write failed");
    return returnJson(out);
}

fn engineOrError(out: boundary.OutBuffer) ?*game_engine.GameEngine {
    if (!have_engine) {
        writeErrorBestEffort(out, "not initialized");
        return null;
    }
    return &engine;
}

/// Start a fresh game from WireConfig difficulty and log level.
export fn init(difficulty: u32, log_level: u32) callconv(.c) u32 {
    const out = outBuffer();
    const wire_cfg = wire.WireConfig.fromWire(@intCast(difficulty), @intCast(log_level)) orelse {
        return exportError(out, "invalid wire config");
    };

    logger.min_level = wire_cfg.log_level;

    var preserved_theme = config.ViewTheme.dark;
    var preserved_region = false;
    if (have_engine) {
        preserved_theme = engine.cfg.theme;
        preserved_region = engine.cfg.show_region;
        engine.deinit();
    }

    var game_cfg = wire_cfg.toConfig();
    game_cfg.theme = preserved_theme;
    game_cfg.show_region = preserved_region;

    const puzzle_str = puzzle_gen.PuzzleGen.generate(game_cfg.difficulty);
    engine = game_engine.GameEngine.init(puzzle_str, game_cfg) catch {
        return exportError(out, "engine init failed");
    };
    have_engine = true;

    boundary.writeOkJson(out) catch return exportWriteFailed(out);
    return returnJson(out);
}

/// Run one gameplay action described by a JSON payload in wasm memory.
export fn exec(in_ptr: u32, in_len: u32) callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return returnJson(out);

    const json = @as([*]const u8, @ptrFromInt(in_ptr))[0..in_len];
    const cmd = boundary.parseAction(json) catch {
        return exportError(out, "invalid action");
    };

    const ev = eng.exec(cmd);
    boundary.writeEventJson(out, ev) catch return exportWriteFailed(out);
    return returnJson(out);
}

/// Product metadata for Help/About as JSON.
export fn getAbout() callconv(.c) u32 {
    const out = outBuffer();
    boundary.writeAboutJson(out) catch return exportWriteFailed(out);
    return returnJson(out);
}

/// Current command availability flags as JSON.
export fn getLegend() callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return returnJson(out);
    boundary.writeLegendJson(out, eng.getLegend()) catch return exportWriteFailed(out);
    return returnJson(out);
}

/// Current nominal config as WireConfig JSON.
export fn getConfig() callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return returnJson(out);
    const wire_cfg = wire.WireConfig.fromConfig(eng.getConfig());
    boundary.writeWireConfigJson(out, wire_cfg) catch return exportWriteFailed(out);
    return returnJson(out);
}

/// Current board snapshot as JSON (GameSnapshot wire shape).
export fn getState() callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return returnJson(out);
    boundary.writeStateJson(out, eng.eventBoard()) catch return exportWriteFailed(out);
    return returnJson(out);
}

/// Serialize full game state to SUD0 bytes in the shared out buffer.
/// Success: byte length. Failure: JSON status ptr (same convention as other exports).
export fn serialize() callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return returnJson(out);

    const bytes = eng.toSaveFormat(std.heap.page_allocator) catch {
        return exportError(out, "serialize failed");
    };
    defer std.heap.page_allocator.free(bytes);

    if (bytes.len > out.buf.len) {
        return exportError(out, "serialize buffer overflow");
    }
    out.reset();
    @memcpy(out.buf[0..bytes.len], bytes);
    out.len.* = @intCast(bytes.len);
    return @intCast(bytes.len);
}

/// Replace game state from SUD0 bytes in wasm memory; returns JSON status ptr.
export fn deserialize(in_ptr: u32, in_len: u32) callconv(.c) u32 {
    const out = outBuffer();
    const eng = engineOrError(out) orelse return returnJson(out);

    const bytes = @as([*]const u8, @ptrFromInt(in_ptr))[0..in_len];
    eng.loadSaveFormat(bytes) catch {
        return exportError(out, "deserialize failed");
    };

    boundary.writeOkJson(out) catch return exportWriteFailed(out);
    return returnJson(out);
}

/// Pointer to the shared out buffer (JSON NUL-terminated or SUD0 bytes from serialize).
export fn outPtr() callconv(.c) u32 {
    return @intFromPtr(&out_buf);
}

pub fn main() void {}
