// Cross-entry parity scenarios, native side: each scenario in `src/test/parity/scenarios.json`
// runs through the real `Sudoku` loop (startup flow + `turn`) and must meet the shared expectations.
const std = @import("std");
const shell = @import("shell.zig");
const test_doubles = @import("test_doubles.zig");
const command = @import("../../core/command.zig");
const config = @import("../../core/config.zig");
const cell = @import("../../core/board/cell.zig");
const board = @import("../../core/board/board.zig");
const game_engine = @import("../../core/engine/game_engine.zig");
const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");
const settings_store = @import("../../core/settings_store.zig");
const test_defaults = @import("../../test/config_defaults.zig");

const SCENARIOS_PATH = "src/test/parity/scenarios.json";
const STARTUP_PATH_DIR = "/";
const IMPORT_PATH = "/puzzle.txt";

const CellAt = struct { row: u8, col: u8 };
const Move = struct { row: u8, col: u8, digit: u8 };
const Probe = struct { row: u8, col: u8, value: u8, given: bool };
const CurrentFile = struct { name: []const u8, puzzle_line: []const u8, moves: []const Move = &.{} };

const Step = struct {
    fill: ?Move = null,
    clear: ?CellAt = null,
    toggle_auto_save: ?bool = null,
    toggle_region: ?bool = null,
    set_theme: ?[]const u8 = null,
    fill_first_empty: ?bool = null,
    undo: ?bool = null,
    redo: ?bool = null,
    hint: ?bool = null,
    solve: ?bool = null,
    paste: ?[]const u8 = null,
    open: ?CurrentFile = null,
    import: ?[]const u8 = null,
    save: ?bool = null,
    copy: ?bool = null,
};

const ScenarioConfig = struct {
    auto_restore: bool = false,
    auto_new: bool = false,
    auto_save: bool = false,
    difficulty: ?[]const u8 = null,
};

const Settings = struct { auto_save: ?bool = null, show_region: ?bool = null, theme: ?[]const u8 = null };

const Legend = struct { undo: ?bool = null, redo: ?bool = null };

const Expect = struct {
    questions: usize,
    solved_after_startup: ?bool = null,
    written: []const []const u8,
    status: ?[]const u8,
    errors: usize = 0,
    settings: ?Settings = null,
    legend: ?Legend = null,
    probes: []const Probe,
};

/// An entry that cannot run the scenario yet; the drift check requires the gap and an open issue.
const Skip = struct { entry: []const u8, gap: []const u8, issue: u32 };

const NATIVE_ENTRY = "native";

const Scenario = struct {
    name: []const u8,
    skip: ?Skip = null,
    config: ScenarioConfig,
    current_file: ?CurrentFile = null,
    puzzle_line: ?[]const u8 = null,
    answers: []const bool,
    steps: []const Step,
    expect: Expect,
};

const Scenarios = struct { scenarios: []const Scenario };

fn scenarioConfig(sc: ScenarioConfig) !config.Config {
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = sc.auto_restore;
    cfg.auto_new = sc.auto_new;
    cfg.auto_save = sc.auto_save;
    if (sc.difficulty) |name| cfg.difficulty = std.meta.stringToEnum(config.Difficulty, name) orelse return error.UnknownDifficulty;
    return cfg;
}

/// Bytes of a saved game: `puzzle_line` with the player's `moves` on top.
fn savedGame(cfg: config.Config, file: CurrentFile) ![]u8 {
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    defer engine.deinit();
    _ = engine.newFromOneLinePuzzle(file.puzzle_line);
    for (file.moves) |m| {
        const event = engine.exec(.{ .fill = .{ .row = @intCast(m.row), .col = @intCast(m.col), .digit = cell.rawToCellValue(m.digit) } });
        if (event != .ok) return error.SetupMoveRejected;
    }
    return engine.toSaveFormat(std.testing.allocator);
}

/// First empty cell and the lowest digit that does not repeat in its row, column or box.
fn firstEmptyLegalFill(view: board.Board.BoardView) !command.FillData {
    for (0..9) |r| for (0..9) |c| {
        const row: u4 = @intCast(r);
        const col: u4 = @intCast(c);
        if (view.get(row, col) != .zero) continue;
        digit: for (1..10) |d| {
            const value = cell.rawToCellValue(@intCast(d));
            for (0..9) |i| {
                const k: u4 = @intCast(i);
                const box_row: u4 = @intCast(r / 3 * 3 + i / 3);
                const box_col: u4 = @intCast(c / 3 * 3 + i % 3);
                if (view.get(row, k) == value or view.get(k, col) == value or view.get(box_row, box_col) == value) continue :digit;
            }
            return .{ .row = row, .col = col, .digit = value };
        }
    };
    return error.NoLegalFill;
}

/// Put the step's picked file where the native shell reads it; returns its owned path.
fn putPicked(cfg: config.Config, transport: *test_doubles.MemoryTransport, step: Step) !?[]u8 {
    if (step.open) |file| {
        const bytes = try savedGame(cfg, file);
        defer std.testing.allocator.free(bytes);
        const path = try std.fs.path.join(std.testing.allocator, &.{ STARTUP_PATH_DIR, file.name });
        try transport.put(path, bytes);
        return path;
    }
    if (step.import) |line| {
        try transport.put(IMPORT_PATH, line);
        return try std.testing.allocator.dupe(u8, IMPORT_PATH);
    }
    return null;
}

fn stepCommand(app: *shell.Sudoku, step: Step, picked: ?[]const u8) !command.Command {
    if (step.open != null) return .{ .open = .{ .path = picked } };
    if (step.import != null) return .{ .import = .{ .path = picked } };
    if (step.save != null) return .{ .save = .{ .path = null } };
    if (step.copy != null) return .{ .copy = {} };
    if (step.fill) |m| return .{ .fill = .{ .row = @intCast(m.row), .col = @intCast(m.col), .digit = cell.rawToCellValue(m.digit) } };
    if (step.clear) |at| return .{ .clear = .{ .row = @intCast(at.row), .col = @intCast(at.col) } };
    if (step.toggle_auto_save != null) return .{ .toggle_auto_save = {} };
    if (step.toggle_region != null) return .{ .toggle_region = {} };
    if (step.set_theme) |name| return .{ .set_theme = std.meta.stringToEnum(config.ViewTheme, name) orelse return error.UnknownTheme };
    if (step.fill_first_empty != null) return .{ .fill = try firstEmptyLegalFill(app.engine.eventBoard()) };
    if (step.undo != null) return .{ .undo = {} };
    if (step.redo != null) return .{ .redo = {} };
    if (step.hint != null) return .{ .hint = .{} };
    if (step.solve != null) return .{ .solve_for_me = {} };
    if (step.paste) |line| return .{ .paste = .{ .line = line } };
    return error.UnknownScenarioStep;
}

fn runScenario(io: std.Io, data_dir: []const u8, scenario: Scenario) !void {
    const cfg = try scenarioConfig(scenario.config);
    var facade_impl = test_doubles.DeterministicFacade{ .steps = &.{}, .replace_answers = scenario.answers };
    var transport_impl = test_doubles.MemoryTransport.init(std.testing.allocator);
    defer transport_impl.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var app = try shell.Sudoku.init(cfg, facade_impl.asFacade(), transport_impl.asTransport(), &out.writer, .{
        .io = io,
        .data_dir = data_dir,
        .visible_save_dir = data_dir,
    });
    defer app.deinit();

    if (scenario.current_file) |file| {
        const bytes = try savedGame(cfg, file);
        defer std.testing.allocator.free(bytes);
        const path = try std.fs.path.join(std.testing.allocator, &.{ STARTUP_PATH_DIR, file.name });
        defer std.testing.allocator.free(path);
        try transport_impl.put(path, bytes);
        try app.runStartupFlow(path);
        if (scenario.expect.solved_after_startup) |solved| {
            try std.testing.expectEqual(solved, app.engine.state.board.isSolved());
        }
    }
    if (scenario.puzzle_line) |line| {
        if (app.engine.newFromOneLinePuzzle(line) != .ok) return error.SetupPuzzleRejected;
        app.file_session.noteLoad(.new_game);
    }

    for (scenario.steps) |step| {
        const picked = try putPicked(cfg, &transport_impl, step);
        defer if (picked) |p| std.testing.allocator.free(p);
        const one = [_]command.ParseCommandResult{.{ .valid = try stepCommand(&app, step, picked) }};
        facade_impl.steps = &one;
        facade_impl.idx = 0;
        _ = try app.turn();
    }

    try std.testing.expectEqual(scenario.expect.questions, facade_impl.replace_prompts);
    try std.testing.expectEqual(scenario.expect.written.len, transport_impl.written.items.len);
    for (scenario.expect.written, transport_impl.written.items) |want, got| {
        try std.testing.expectEqualStrings(want, std.fs.path.basename(got));
    }
    const status: ?[]const u8 = facade_impl.last_render_msg;
    if (scenario.expect.status) |want| {
        const dir_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/", .{data_dir});
        defer std.testing.allocator.free(dir_prefix);
        const relative = try std.mem.replaceOwned(u8, std.testing.allocator, status orelse "", dir_prefix, "");
        defer std.testing.allocator.free(relative);
        try std.testing.expectEqualStrings(want, relative);
    } else {
        try std.testing.expect(status == null or status.?.len == 0);
    }
    try std.testing.expectEqual(scenario.expect.errors, facade_impl.error_calls);
    if (scenario.expect.settings) |want| {
        const saved = try settings_store.loadOrDefault(std.testing.allocator, io, data_dir);
        if (want.auto_save) |on| try std.testing.expectEqual(on, saved.auto_save);
        if (want.show_region) |on| try std.testing.expectEqual(on, saved.show_region);
        if (want.theme) |name| try std.testing.expectEqualStrings(name, @tagName(saved.theme));
    }
    if (scenario.expect.legend) |want| {
        const legend = app.engine.getLegend();
        if (want.undo) |on| try std.testing.expectEqual(on, legend.undo);
        if (want.redo) |on| try std.testing.expectEqual(on, legend.redo);
    }
    const view = app.engine.eventBoard();
    for (scenario.expect.probes) |p| {
        const row: u4 = @intCast(p.row);
        const col: u4 = @intCast(p.col);
        try std.testing.expectEqual(cell.rawToCellValue(p.value), view.get(row, col));
        try std.testing.expectEqual(p.given, view.isGiven(row, col));
    }
}

test "parity scenarios: native shell meets every shared scenario expectation" {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, SCENARIOS_PATH, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Scenarios, std.testing.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.scenarios.len > 0);

    for (parsed.value.scenarios) |scenario| {
        if (scenario.skip) |skip| if (std.mem.eql(u8, skip.entry, NATIVE_ENTRY)) continue;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const rel = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer std.testing.allocator.free(rel);
        const abs_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel, std.testing.allocator);
        defer std.testing.allocator.free(abs_z);
        runScenario(io, abs_z[0 .. abs_z.len - 1], scenario) catch |err| {
            std.debug.print("parity scenario failed: {s}\n", .{scenario.name});
            return err;
        };
    }
}
