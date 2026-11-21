// Terminal e2e suite: the real input path (Host.createForTest → parser → engine)
// driving core through the shell's Sudoku loop. Runs in verify-slow, not verify.
// Each test is named "core_e2e: <Gherkin mnemonic>" so the "core_e2e" filter selects it.
const std = @import("std");
const shell = @import("../../native/shell/shell.zig");
const host_mod = @import("../../native/host.zig");
const file_transport = @import("../../native/shell/file_transport.zig");
const config = @import("../../core/config.zig");
const config_store = @import("../../core/config_store.zig");
const game_engine = @import("../../core/engine/game_engine.zig");
const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");
const frame_mod = @import("../../core/frame.zig");
const file_policy = @import("../../core/file_policy.zig");
const board = @import("../../core/board/board.zig");
const cell = @import("../../core/board/cell.zig");
const styler_t = @import("../../native/ascii/styler.zig");
const parser = @import("../../native/ascii/parser.zig");

const Sudoku = shell.Sudoku;
const Host = host_mod.Host;

test "core_e2e: given_empty_cell_when_filled_then_digit_lands" {
    // Arrange: fresh engine via Sudoku.init through real AsciiRenderer
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    const responses = [_][]const u8{
        "fill A3 4",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    // Act: run the full loop — fill A3 with 4 via prefix dispatch, then quit
    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    // Assert (a): engine has undo available after mutation.
    {
        const avail = sudoku.engine.getLegend(sudoku.cfg.auto_save);
        try std.testing.expect(avail.undo);
    }

    // Assert (b): cell at chess coord A3 -> row 2, col 0 is four.
    {
        try std.testing.expectEqual(cell.CellValue.four, sudoku.engine.state.board.getCellValue(@as(u4, 2), @as(u4, 0)));
    }
}

test "core_e2e: given_auto_pencil_on_when_pencil_toggled_then_candidates_draw_and_back" {
    // Arrange: fresh engine through the real AsciiRenderer, raw text in.
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    // menu -> 14 (Settings) -> 8 (Auto Pencil) turns the setting on;
    // P toggles the Pencil switch, so candidates draw, then digits only; quit ends the loop.
    const responses = [_][]const u8{
        "menu", "14", "8",
        "P",    "P",  "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();

    // One turn() consumes the whole Menu -> Settings -> Auto Pencil chain,
    // since the menu and settings sheets read their picks inside getCommandInput.
    try std.testing.expect(!try sudoku.turn()); // menu -> 14 -> 8
    try std.testing.expect(sudoku.cfg.auto_pencil);

    // First P: the Pencil switch comes on, so every empty cell draws its candidates.
    try std.testing.expect(!try sudoku.turn()); // P
    try std.testing.expect(sudoku.engine.is_pencil);
    {
        const frame = frame_mod.build(&sudoku.engine, sudoku.cfg, null);
        const drawn = frame.drawnMarks();
        var any_marks = false;
        for (drawn) |m| {
            if (m != 0) any_marks = true;
        }
        try std.testing.expect(any_marks);
    }

    // Second P: the switch goes off, so no cell draws marks.
    try std.testing.expect(!try sudoku.turn()); // P
    try std.testing.expect(!sudoku.engine.is_pencil);
    {
        const frame = frame_mod.build(&sudoku.engine, sudoku.cfg, null);
        for (frame.drawnMarks()) |m| try std.testing.expectEqual(@as(board.MarkSet, 0), m);
    }

    // Quit ends the loop.
    try std.testing.expect(try sudoku.turn());
}

test "core_e2e: given_open_file_when_saved_then_same_path_reused" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    const io = std.testing.io;
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), config.Config.default());
    defer original.deinit();
    const tmp_path = "/tmp/sudoku_e2e_open_save_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    const setup_transport = file_transport.NativeTransport.make(io);
    const save_buf = try original.toSaveFormat(std.heap.page_allocator);
    defer std.heap.page_allocator.free(save_buf);
    try setup_transport.write(setup_transport.context, tmp_path, save_buf);

    // menu → open → path → menu → save → quit (no filename line after save)
    const responses = [_][]const u8{
        "m",
        "2",
        tmp_path,
        "m",
        "1",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();

    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    const on_disk = setup_transport.readAll(setup_transport.context, tmp_path) catch return error.TestFailed;
    defer setup_transport.free(setup_transport.context, on_disk);
    try std.testing.expect(on_disk.len > 0);
}

test "core_e2e: given_save_as_when_written_then_file_and_board_agree" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    // Canned responses: command → dialog filename → quit
    const responses = [_][]const u8{
        "m",
        "6",
        "test_save_as.sud",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
}

test "core_e2e: given_save_as_failure_when_attempted_then_current_file_kept" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);
    const bad_path = "/tmp/sudoku_missing_parent_dir/deny.sud";

    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    const responses = [_][]const u8{
        "m",
        "6",
        bad_path,
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    var app = try Sudoku.init(cfg, facade, file_transport.NativeTransport.make(io), host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    const current = try config_store.loadCurrentFile(std.testing.allocator, io, data_path);
    defer if (current) |p| std.testing.allocator.free(p);
    try std.testing.expect(current == null);
}

test "core_e2e: given_a_game_when_new_then_board_and_history_reset" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    // feed fill (adds to history), then new (should clear it), then quit
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "5", // menu → New
        "2", // difficulty dialog → Medium (fresh generated puzzle)
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    // history should be empty after new command clears it
    try std.testing.expectEqual(@as(usize, 0), sudoku_instance.engine.state.history.entries.items.len);
}

test "core_e2e: given_import_when_valid_then_board_loads_and_history_clears" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
        .auto_save = false,
    };

    const board_mod = @import("../../core/board/board.zig");
    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_e2e_import_ok_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    const puzzle_line = puzzle_gen.PuzzleGen.hard();
    const setup_transport = file_transport.NativeTransport.make(io);
    try setup_transport.write(setup_transport.context, tmp_path, puzzle_line);

    // fill (adds history) → menu → Import → path → quit
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "3",
        tmp_path,
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    const expected = board_mod.fromPuzzle(puzzle_line) catch unreachable;
    try std.testing.expect(board_mod.equal(sudoku_instance.engine.state.board, expected));
    try std.testing.expectEqual(@as(usize, 0), sudoku_instance.engine.state.history.entries.items.len);
}

test "core_e2e: given_import_when_invalid_then_board_and_history_intact" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    std.Io.Dir.deleteFileAbsolute(std.testing.io, "/tmp/sudoku_e2e_import_fail_test.txt") catch {};
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "3",
        "/tmp/sudoku_e2e_import_fail_test.txt",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    // history survived
    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
    // filled cell A3 (row 2, col 0) still holds seven
    try std.testing.expectEqual(cell.CellValue.seven, sudoku_instance.engine.state.board.getCellValue(2, 0));
}

test "core_e2e: given_export_when_run_then_one_line_file_written" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    const io = std.testing.io;
    const tmp_path = "/tmp/sudoku_e2e_export_ok_test.txt";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // fill (adds history) → menu → Export → path → quit
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "4",
        tmp_path,
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
    const expected = sudoku_instance.engine.toPuzzle();
    const bytes = transport.readAll(transport.context, tmp_path) catch return error.TestFailed;
    defer transport.free(transport.context, bytes);
    try std.testing.expectEqual(@as(usize, 81), bytes.len);
    try std.testing.expectEqualSlices(u8, &expected, bytes[0..81]);
    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
}

test "core_e2e: given_copy_when_run_then_puzzle_printed_history_untouched" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };

    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "12",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;

    const expected = sudoku_instance.engine.toPuzzle();
    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, &expected) != null);
    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
    try std.testing.expectEqual(cell.CellValue.seven, sudoku_instance.engine.state.board.getCellValue(2, 0));
}

test "core_e2e: given_export_failure_when_attempted_then_board_intact" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };
    std.Io.Dir.deleteFileAbsolute(std.testing.io, "/tmp/sudoku_e2e_export_missing_dir/x.txt") catch {};
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "4",
        "/tmp/sudoku_e2e_export_missing_dir/x.txt",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku_instance = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku_instance.deinit();
    try sudoku_instance.showGame();
    while (true) if (try sudoku_instance.turn()) break;
    try std.testing.expectEqual(@as(usize, 1), sudoku_instance.engine.state.history.entries.items.len);
    try std.testing.expectEqual(cell.CellValue.seven, sudoku_instance.engine.state.board.getCellValue(2, 0));
}

test "core_e2e: given_open_when_ok_status_then_non_blocking_next_line_is_command" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };
    const io = std.testing.io;
    const gpa = std.heap.page_allocator;
    const tmp_path = "/tmp/sudoku_status_nonblocking_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
    var original = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), config.Config.default());
    defer original.deinit();
    const setup_transport = file_transport.NativeTransport.make(io);
    const save_buf = try original.toSaveFormat(gpa);
    defer gpa.free(save_buf);
    try setup_transport.write(setup_transport.context, tmp_path, save_buf);
    const b = original.state.board;
    const pick: struct { r: u4, c: u4 } = blk: {
        for (0..9) |r| {
            for (0..9) |c| {
                const ru = @as(u4, @intCast(r));
                const cu = @as(u4, @intCast(c));
                if (b.isGiven(ru, cu) or b.getCellValue(ru, cu) != cell.CellValue.zero) continue;
                const seven_bits: u32 = (@as(u32, 1) << 6);
                if (b.getBoxDigitBits(@intCast(@divTrunc(r, 3)), @intCast(@divTrunc(c, 3))) & seven_bits != 0) continue;
                var clash = false;
                for (0..9) |k| {
                    if (b.getCellValue(ru, @as(u4, @intCast(k))) == cell.CellValue.seven or
                        b.getCellValue(@as(u4, @intCast(k)), cu) == cell.CellValue.seven)
                    {
                        clash = true;
                        break;
                    }
                }
                if (clash) continue;
                break :blk .{ .r = ru, .c = cu };
            }
        }
        unreachable; // every generated puzzle leaves a clean cell
    };
    const ci: u8 = @intCast(pick.c);
    const col_letters = "ABCDEFGHI";
    const col_letter = col_letters[ci % 9];
    const fill_cmd = try std.fmt.allocPrint(gpa, "fill {c}{d} 7", .{ col_letter, pick.r + 1 });
    defer gpa.free(fill_cmd);
    const responses = [_][]const u8{
        "m",
        "2",
        tmp_path,
        fill_cmd,
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();
    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;
    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    const opened_status = " is open.";
    // 1. Status message is displayed ...
    try std.testing.expect(std.mem.indexOf(u8, contents, opened_status) != null);
    // 2. ... without the interactive ack prompt ...
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") == null);
    // 3. ... inside a line-graphics frame (side border, or a top edge on the line above).
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var prev: ?[]const u8 = null;
    var framed = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, opened_status) != null) {
            framed = std.mem.indexOf(u8, line, "│") != null or
                (prev != null and std.mem.indexOf(u8, prev.?, "┌") != null);
            break;
        }
        prev = line;
    }
    try std.testing.expect(framed);
    // 4. The line after the status is read as the next command: the fill lands.
    try std.testing.expectEqual(cell.CellValue.seven, sudoku.engine.state.board.getCellValue(pick.r, pick.c));
}

test "core_e2e: given_bare_fill_when_error_status_then_enter_is_ack_not_command" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
    };
    // bare fill → .error_msg; the empty line is the user's ack Enter; quit ends the loop.
    const responses = [_][]const u8{ "fill", "", "quit" };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();
    try sudoku.showGame();
    var terminated = false;
    while (true) {
        if (try sudoku.turn()) {
            terminated = true;
            break;
        }
    }
    try std.testing.expect(terminated);
    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    // routed through promptMessage: the error text is in the output
    try std.testing.expect(std.mem.indexOf(u8, contents, parser.FILL_USAGE_MSG) != null);
    // interactive ack prompt present
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") != null);
    // the ack Enter was consumed by the ack, not re-parsed as a command
    try std.testing.expect(std.mem.indexOf(u8, contents, parser.EMPTY_INPUT_MSG) == null);
    // exactly one ack — the ack line did not re-enter the parser loop
    var ack_count: usize = 0;
    var rest = contents;
    while (std.mem.indexOfPos(u8, rest, 0, "Press Enter to continue...")) |i| {
        ack_count += 1;
        rest = rest[i + "Press Enter to continue...".len ..];
    }
    try std.testing.expectEqual(@as(usize, 1), ack_count);
}

test "core_e2e: given_show_region_off_when_filled_then_no_shading" {
    const region_on = styler_t.REGION_ON;
    const cfg: config.Config = .{
        .difficulty = .hard,
        .renderers = .{ .preferred = .ansi, .fallback = .ansi },
        .log_level = .info,
        .show_marks = false, // the small board's bottom border marks where each board ends
    };
    const gpa = std.heap.page_allocator;
    var probe = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.hard(), cfg);
    defer probe.deinit();
    const b = probe.state.board;
    const pick: struct { r: u4, c: u4 } = blk: {
        for (0..9) |r| {
            for (0..9) |c| {
                const ru = @as(u4, @intCast(r));
                const cu = @as(u4, @intCast(c));
                if (b.isGiven(ru, cu) or b.getCellValue(ru, cu) != cell.CellValue.zero) continue;
                const seven_bits: u32 = (@as(u32, 1) << 6);
                if (b.getBoxDigitBits(@intCast(@divTrunc(r, 3)), @intCast(@divTrunc(c, 3))) & seven_bits != 0) continue;
                var clash = false;
                for (0..9) |k| {
                    if (b.getCellValue(ru, @as(u4, @intCast(k))) == cell.CellValue.seven or
                        b.getCellValue(@as(u4, @intCast(k)), cu) == cell.CellValue.seven)
                    {
                        clash = true;
                        break;
                    }
                }
                if (clash) continue;
                break :blk .{ .r = ru, .c = cu };
            }
        }
        unreachable;
    };
    const col_letters = "ABCDEFGHI";
    const fill_cmd = try std.fmt.allocPrint(gpa, "fill {c}{d} 7", .{ col_letters[pick.c], pick.r + 1 });
    defer gpa.free(fill_cmd);
    const responses = [_][]const u8{ fill_cmd, "m", "7", "quit" };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    const board_marker = "╰───────┴───────┴───────╯";
    const first_board_end = std.mem.indexOf(u8, contents, board_marker) orelse return error.TestFailed;
    const after_fill = contents[0 .. first_board_end + board_marker.len];
    try std.testing.expect(std.mem.indexOf(u8, after_fill, region_on) == null);
    try std.testing.expect(sudoku.engine.selected != null);
    try std.testing.expect(sudoku.cfg.show_region);
    try std.testing.expect(std.mem.indexOf(u8, contents, region_on) != null);
}

test "core_e2e: given_settings_when_difficulty_changed_then_config_persists" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const cfg = config.Config.default();
    const responses = [_][]const u8{ "menu\n", "14\n", "2\n", "3\n", "quit\n" };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expectEqual(config.Difficulty.hard, app.cfg.difficulty);
    const restored = try config_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expectEqual(config.Difficulty.hard, restored.difficulty);
}

test "core_e2e: given_settings_when_warning_changed_then_config_persists" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    const cfg = config.Config.default();
    const responses = [_][]const u8{ "menu\n", "14\n", "1\n", "quit\n" };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expect(app.cfg.warn_solvability);
    const restored = try config_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expect(restored.warn_solvability);
}

test "core_e2e: given_settings_when_auto_flags_changed_then_config_persists" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(data_path);

    var cfg = config.Config.default();
    cfg.auto_restore = false;
    cfg.auto_new = false;
    cfg.auto_save = false;
    const responses = [_][]const u8{
        "menu\n", "14\n", "5\n", // auto_restore on
        "menu\n", "14\n", "6\n", // auto_new on
        "menu\n", "14\n", "7\n", // auto_save on
        "quit\n",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var app = try Sudoku.init(cfg, facade, transport, host.writer(), .{ .io = io, .data_dir = data_path, .visible_save_dir = data_path });
    defer app.deinit();

    try app.showGame();
    while (true) if (try app.turn()) break;

    try std.testing.expect(app.cfg.auto_restore);
    try std.testing.expect(app.cfg.auto_new);
    try std.testing.expect(app.cfg.auto_save);

    const restored = try config_store.loadOrDefault(std.testing.allocator, io, data_path);
    try std.testing.expect(restored.auto_restore);
    try std.testing.expect(restored.auto_new);
    try std.testing.expect(restored.auto_save);
}

test "core_e2e: given_a_save_when_reopened_then_snapshot_restores" {
    const io = std.testing.io;
    const cfg = config.Config.default();
    const tmp_path = "/tmp/sudoku_e2e_save_reopen_test.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // menu → Settings → Auto Save (off), so the later fill does not autosave over
    // the saved snapshot; then fill A3 7 → save_as → fill A3 1 → open → quit.
    const responses = [_][]const u8{
        "m",
        "14",
        "7",
        "fill A3 7",
        "m",
        "6",
        tmp_path,
        "fill A3 1",
        "m",
        "2",
        tmp_path,
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    // The reopened file restores the saved seven, overwriting the later fill.
    try std.testing.expectEqual(cell.CellValue.seven, sudoku.engine.state.board.getCellValue(2, 0));
}

test "core_e2e: given_import_when_exported_then_round_trip_matches" {
    const io = std.testing.io;
    const cfg = config.Config.default();
    const in_path = "/tmp/sudoku_e2e_import_roundtrip_in.txt";
    const out_path = "/tmp/sudoku_e2e_import_roundtrip_out.txt";
    // The import's absolute path drifts the transport data dir to /tmp, so the
    // import autosave writes sudoku.sud there; clean it up like the other files.
    const autosave_path = "/tmp/sudoku.sud";
    defer std.Io.Dir.deleteFileAbsolute(io, in_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, out_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, autosave_path) catch {};
    const puzzle_line = puzzle_gen.PuzzleGen.hard();
    const setup_transport = file_transport.NativeTransport.make(io);
    try setup_transport.write(setup_transport.context, in_path, puzzle_line);

    // import → export → quit
    const responses = [_][]const u8{
        "m",    "3", in_path,
        "m",    "4", out_path,
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    // The exported file round-trips the imported puzzle line.
    const bytes = transport.readAll(transport.context, out_path) catch return error.TestFailed;
    defer transport.free(transport.context, bytes);
    try std.testing.expectEqualSlices(u8, puzzle_line, bytes);
}

test "core_e2e: given_a_game_when_new_with_puzzle_then_board_replaced_history_cleared" {
    const cfg = config.Config.default();

    // fill A3 7 (adds history) → new at Medium → quit
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "5",
        "2",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    // The new board is the medium fixture and the mutation history is cleared.
    const expected = try board.fromPuzzle(puzzle_gen.PuzzleGen.medium());
    try std.testing.expect(board.equal(sudoku.engine.state.board, expected));
    try std.testing.expectEqual(@as(usize, 0), sudoku.engine.state.history.entries.items.len);
}

test "core_e2e: given_a_game_when_new_without_puzzle_then_generates_at_difficulty" {
    const cfg = config.Config.default();

    // fill A3 7 (adds history) → new at Easy → quit
    const responses = [_][]const u8{
        "fill A3 7",
        "m",
        "5",
        "1",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    // New generated at the chosen difficulty, cleared history, and spoke its status.
    try std.testing.expectEqual(@as(usize, 0), sudoku.engine.state.history.entries.items.len);
    try std.testing.expectEqual(puzzle_gen.Difficulty.easy, sudoku.cfg.difficulty);
    try std.testing.expectEqualStrings(game_engine.NEW_GAME_STARTED_MSG, sudoku.engine.state.status.optional().?);
}

test "core_e2e: given_a_fill_when_undone_and_redone_then_digit_returns" {
    const cfg = config.Config.default();

    // fill A3 7 → undo → redo → quit; the redo re-applies the undone seven.
    const responses = [_][]const u8{
        "fill A3 7",
        "undo",
        "redo",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    try std.testing.expectEqual(cell.CellValue.seven, sudoku.engine.state.board.getCellValue(2, 0));
}

test "core_e2e: given_an_empty_cell_when_hinted_then_a_placement_is_reported" {
    const cfg = config.Config.default();

    // menu → 8 (Hint) → quit; the hint reports a placement sentence.
    const responses = [_][]const u8{
        "m",
        "8",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    const contents = std.Io.Writer.buffered(&host.session.writer.mock.writer);
    try std.testing.expect(std.mem.indexOf(u8, contents, " takes ") != null);
}

test "core_e2e: given_a_game_when_solved_then_board_is_complete" {
    const cfg = config.Config.default();

    // menu → 11 (Solve) → quit; the board is complete afterwards.
    const responses = [_][]const u8{
        "m",
        "11",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    try std.testing.expect(sudoku.engine.state.board.isSolved());
}

test "core_e2e: given_a_move_when_bookmarked_then_bookmark_is_set" {
    const cfg = config.Config.default();

    // fill A3 7 → bookmark → quit; the bookmark pins move 1.
    const responses = [_][]const u8{
        "fill A3 7",
        "bookmark",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    try std.testing.expectEqual(@as(?u16, 1), sudoku.engine.state.bookmark);
}

test "core_e2e: given_a_bookmark_when_rewound_then_board_returns" {
    const cfg = config.Config.default();

    // fill A3 7 → bookmark → fill B1 4 → rewind → quit; the rewind drops the later fill.
    const responses = [_][]const u8{
        "fill A3 7",
        "bookmark",
        "fill B1 4",
        "rewind",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    try std.testing.expectEqual(cell.CellValue.seven, sudoku.engine.state.board.getCellValue(2, 0));
    try std.testing.expectEqual(cell.CellValue.zero, sudoku.engine.state.board.getCellValue(0, 1));
}

test "core_e2e: given_a_cell_with_auto_pencil_off_when_pencil_mark_toggled_then_mark_flips" {
    const cfg = config.Config.default();

    // pencil A1 5 → pencil A1 5 → quit; the mark toggles on then off in the empty cell.
    const responses = [_][]const u8{
        "pencil A1 5",
        "pencil A1 5",
        "quit",
    };
    var host = Host.createForTest(cfg, &responses);
    defer host.deinit();
    var facade = try host.facade();
    defer facade.deinit();
    const transport = file_transport.NativeTransport.make(std.testing.io);
    var sudoku = try Sudoku.init(cfg, facade, transport, host.writer(), null);
    defer sudoku.deinit();

    try sudoku.showGame();
    while (true) if (try sudoku.turn()) break;

    try std.testing.expectEqual(@as(board.MarkSet, 0), sudoku.engine.state.board.marksAt(0, 0));
}
