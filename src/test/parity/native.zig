// Cross-front-end parity, native side: every shared scenario runs through the real `Sudoku`
// loop (startup flow, then `turn` per step) with a scripted renderer and an in-memory folder.
// Each run records the steps core issued and the shell's answers; the transcripts are written
// for the web and Android runs (`src/wasm/flows/parity.test.mjs`) to compare against.
const std = @import("std");
const shell = @import("../../native/shell/shell.zig");
const facade_mod = @import("../../core/renderer/facade.zig");
const flow_mod = @import("../../core/flow/mod.zig");
const command = @import("../../core/command.zig");
const config = @import("../../core/config.zig");
const config_table = @import("../../core/config_table.zig");
const legend_mod = @import("../../core/renderer/legend.zig");
const board = @import("../../core/board/board.zig");
const cell = @import("../../core/board/cell.zig");
const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");
const game_engine = @import("../../core/engine/game_engine.zig");
const config_store = @import("../../core/config_store.zig");
const test_defaults = @import("../config_defaults.zig");
const MemoryTransport = @import("../../native/shell/memory_transport.zig").MemoryTransport;

const SCENARIOS_PATH = "src/test/fixtures/parity_scenarios.json";
const TRANSCRIPTS_DIR = ".zig-cache/parity";
const TRANSCRIPTS_FILE = "native.json";
const NATIVE = "native";
const FOLDER_PREFIX = MemoryTransport.DIR ++ "/";
/// A settings folder no write can create, for scenarios where storing settings fails.
const UNWRITABLE_DATA_DIR = "/dev/null/sudoku";
/// The file an `import` step's text is read from.
const IMPORT_NAME = "puzzle.txt";

const Move = struct { row: u8, col: u8, digit: u8 };
const CellAt = struct { row: u8, col: u8 };
/// One cell's expected value; `marks` (bit `k` = digit `k + 1`) is checked when given.
const Probe = struct { row: u8, col: u8, value: u8, given: bool, marks: ?u16 = null };

/// A saved game: `puzzle_line` with the player's `moves` on top. `corrupt` stores bytes that are no saved game.
const SavedFile = struct {
    name: []const u8,
    puzzle_line: []const u8 = "",
    moves: []const Move = &.{},
    corrupt: bool = false,
    missing: bool = false,
};

const World = struct {
    fail_writes: []const []const u8 = &.{},
    fail_reads: []const []const u8 = &.{},
    settings_fail: bool = false,
    // Only web and Android stage these; a scenario using one names native in `not_on`.
    taken: []const []const u8 = &.{},
    generate: ?[]const u8 = null,
    pick: ?[]const u8 = null,
};

const Step = struct {
    fill: ?Move = null,
    clear: ?CellAt = null,
    fill_first_empty: ?bool = null,
    undo: ?bool = null,
    redo: ?bool = null,
    hint: ?bool = null,
    hint_at: ?CellAt = null,
    solve: ?bool = null,
    paste: ?[]const u8 = null,
    open: ?SavedFile = null,
    import: ?[]const u8 = null,
    save: ?bool = null,
    save_as: ?[]const u8 = null,
    copy: ?bool = null,
    new: ?[]const u8 = null,
    new_line: ?[]const u8 = null,
    @"export": ?bool = null,
    toggle_auto_save: ?bool = null,
    toggle_region: ?bool = null,
    set_theme: ?[]const u8 = null,
    toggle_warn_solvability: ?bool = null,
    set_difficulty: ?[]const u8 = null,
    set_log_level: ?[]const u8 = null,
    toggle_auto_restore: ?bool = null,
    toggle_auto_new: ?bool = null,
    pencil: ?Move = null,
    toggle_pencil_mode: ?bool = null,
    toggle_show_marks: ?bool = null,
    select: ?CellAt = null,
    deselect: ?bool = null,
    relaunch: ?bool = null,
    // Steps only web and Android carry out; a scenario using one names native in `not_on`.
    open_cancel: ?bool = null,
    import_cancel: ?bool = null,
    save_as_cancel: ?bool = null,
    export_cancel: ?bool = null,
    paste_fails: ?bool = null,
    copy_fails: ?bool = null,
    close: ?bool = null,
};

const ScenarioConfig = struct {
    auto_restore: bool = false,
    auto_new: bool = false,
    auto_save: bool = false,
    difficulty: ?[]const u8 = null,
};

const Settings = struct { auto_save: ?bool = null, show_region: ?bool = null, theme: ?[]const u8 = null, show_marks: ?bool = null };
const Legend = struct { undo: ?bool = null, redo: ?bool = null };

/// Outcomes every front end that runs the scenario must meet, on top of matching each other.
const Expect = struct {
    questions: ?usize = null,
    errors: ?usize = null,
    solved_after_startup: ?bool = null,
    written: ?[]const []const u8 = null,
    settings: ?Settings = null,
    legend: ?Legend = null,
    probes: []const Probe = &.{},
    /// The cell drawn as selected after the steps.
    selected: ?CellAt = null,
    /// Nothing is drawn as selected after the steps.
    nothing_selected: ?bool = null,
};

/// An entry that cannot run the scenario yet; the drift check requires the gap and an open issue.
const Skip = struct { entry: []const u8, gap: []const u8, issue: u32 };

const Scenario = struct {
    name: []const u8,
    summary: []const u8,
    not_on: ?std.json.ArrayHashMap([]const u8) = null,
    skip: ?Skip = null,
    config: ScenarioConfig = .{},
    current_file: ?SavedFile = null,
    files: []const SavedFile = &.{},
    puzzle_line: ?[]const u8 = null,
    world: World = .{},
    answers: []const bool = &.{},
    steps: []const Step = &.{},
    expect: Expect = .{},

    fn runsOnNative(self: Scenario) bool {
        if (self.not_on) |not_on| if (not_on.map.contains(NATIVE)) return false;
        if (self.skip) |skip| if (std.mem.eql(u8, skip.entry, NATIVE)) return false;
        return true;
    }
};

const Scenarios = struct {
    flowless_commands: std.json.ArrayHashMap([]const u8),
    /// Step kinds a front end never receives, with the reason; the JS runner checks them for every front end.
    steps_not_received: std.json.ArrayHashMap(std.json.ArrayHashMap([]const u8)),
    scenarios: []const Scenario,
};

/// One step core issued and the shell's answer; null fields are left out of the transcript.
const Event = struct {
    step: []const u8,
    type: ?[]const u8 = null,
    title: ?[]const u8 = null,
    text: ?[]const u8 = null,
    buttons: ?[]const []const u8 = null,
    /// The button dismissing the prompt answers, if any.
    dismiss: ?usize = null,
    name: ?[]const u8 = null,
    replace: ?bool = null,
    delete: ?bool = null,
    status: ?[]const u8 = null,
    file: ?[]const u8 = null,
    loaded: ?bool = null,
    difficulty: ?[]const u8 = null,
    answer: ?Answer = null,
};

const Answer = struct {
    pressed: ?usize = null,
    wrote: ?[]const u8 = null,
    read: ?[]const u8 = null,
    generated: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

const FinalConfig = struct {
    difficulty: []const u8,
    log_level: []const u8,
    theme: []const u8,
    show_region: bool,
    warn_solvability: bool,
    auto_restore: bool,
    auto_new: bool,
    auto_save: bool,
};

/// The game once the steps are done.
const Final = struct {
    cells: []const u8,
    givens: []const u8,
    undo: bool,
    redo: bool,
    file: ?[]const u8,
    status: ?[]const u8,
    /// The selected cell the board was last drawn with.
    selected: ?CellAt,
    /// The shaded cells' indices (row * 9 + col) the board was last drawn with.
    region: ?[]const usize,
    config: FinalConfig,
};

const Transcript = struct { name: []const u8, events: []const Event, final: Final };

/// Records what one run showed and answers its prompts from the scenario.
const Recorder = struct {
    arena: std.mem.Allocator,
    events: std.ArrayListUnmanaged(Event) = .empty,
    answers: []const bool = &.{},
    answered: usize = 0,
    /// The command the next `turn` reads.
    pending: ?command.Command = null,
    last_status: ?[]const u8 = null,
    last_selected: ?CellAt = null,
    last_region: ?[]const usize = null,
    recording: bool = true,

    fn asFacade(self: *Recorder) facade_mod.Facade {
        return facade_mod.Make(Recorder).make(self);
    }

    fn observer(self: *Recorder) shell.Sudoku.StepObserver {
        return .{ .ctx = @ptrCast(self), .onStep = onStep };
    }

    /// Keeps the status line, selection and region the board was last drawn with, for the final state.
    pub fn render(self: *Recorder, frame: facade_mod.Frame) !void {
        self.last_status = if (frame.status) |m| (if (m.len == 0) null else self.text(m) catch return error.System) else null;
        self.last_selected = if (frame.selected) |s| .{ .row = s.row, .col = s.col } else null;
        self.last_region = if (frame.region) |mask| self.regionCells(mask) catch return error.System else null;
    }

    /// The indices of the cells `mask` shades, in board order.
    fn regionCells(self: *Recorder, mask: board.CellMask) ![]const usize {
        var cells: std.ArrayListUnmanaged(usize) = .empty;
        for (0..board.CELL_COUNT) |i| if (mask & board.indexBit(i) != 0) try cells.append(self.arena, i);
        return cells.items;
    }

    /// The legend is read from the engine at the end, not from the screen.
    pub fn showLegend(_: *Recorder, _: legend_mod.Legend) !void {}

    /// A question is answered from the scenario (yes, the default, when the answers run out); an error is acknowledged.
    pub fn promptMessage(self: *Recorder, prompt: flow_mod.PromptMessage) !usize {
        if (prompt.buttons.len == 1) return 0;
        var yes = true;
        if (self.answered < self.answers.len) {
            yes = self.answers[self.answered];
            self.answered += 1;
        }
        return if (yes) prompt.defaultAnswer() else prompt.dismissAnswer() orelse 0;
    }

    /// The scenario step being run, once; then quit, so `turn()` returns.
    pub fn getCommandInput(
        self: *Recorder,
        _: []const []const u8,
        _: config.Config,
    ) !command.ParseCommandResult {
        const cmd = self.pending orelse return .{ .valid = .{ .quit = {} } };
        self.pending = null;
        return .{ .valid = cmd };
    }

    /// Generation progress is not a flow step, so it is not recorded.
    pub fn reportGenProgress(_: *Recorder, _: puzzle_gen.GenProgressEvent) !void {}

    /// The recorder's text lives in the run's arena.
    pub fn deinit(_: *Recorder) void {}

    /// Text as the player reads it, without the folder the in-memory transport puts names in.
    fn text(self: *Recorder, raw: []const u8) ![]const u8 {
        return std.mem.replaceOwned(u8, self.arena, raw, FOLDER_PREFIX, "");
    }

    fn baseName(self: *Recorder, path: []const u8) ![]const u8 {
        return self.arena.dupe(u8, std.fs.path.basename(path));
    }

    fn onStep(ctx: *anyopaque, step: flow_mod.Step, answer: ?flow_mod.Input) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (!self.recording) return;
        const event = self.describe(step, answer) catch @panic("parity: out of memory recording a step");
        self.events.append(self.arena, event) catch @panic("parity: out of memory recording a step");
    }

    fn describe(self: *Recorder, step: flow_mod.Step, answer: ?flow_mod.Input) !Event {
        var event: Event = .{ .step = @tagName(step) };
        switch (step) {
            .prompt_message => |p| {
                event.type = @tagName(p.type);
                event.title = try self.text(p.title);
                event.text = try self.text(p.text);
                const buttons = try self.arena.alloc([]const u8, p.buttons.len);
                for (p.buttons, buttons) |b, *out| out.* = try self.arena.dupe(u8, b);
                event.buttons = buttons;
                event.dismiss = p.dismissAnswer();
            },
            .save, .autosave => |w| {
                event.name = try self.baseName(w.name);
                event.replace = w.replace;
            },
            // The terminal types Save As's file; a picker suggests one. Only what was written is compared.
            .save_as => |w| event.replace = w.replace,
            .flush, .export_puzzle => |name| event.name = try self.baseName(name),
            .show_game => |g| {
                event.status = if (g.frame.status) |s| (if (s.len == 0) null else try self.text(s)) else null;
                event.file = if (g.file) |f| try self.baseName(f) else null;
                event.loaded = if (g.loaded) true else null;
            },
            .generate_game => |d| event.difficulty = @tagName(d),
            // The web host serves the current file at a fixed address, so restoring and forgetting it compare without its name.
            .forget_current_file => |f| event.delete = f.delete,
            .show_status => |s| event.text = try self.text(s),
            .resolve_default_target, .reclaim_file, .copy_puzzle, .paste_puzzle, .restore, .open, .import_puzzle, .persist_config, .done => {},
        }
        if (answer) |a| event.answer = try self.describeAnswer(a);
        return event;
    }

    fn describeAnswer(self: *Recorder, input: flow_mod.Input) !?Answer {
        return switch (input) {
            .start, .ack => null,
            .default_target => |name| .{ .name = try self.baseName(name) },
            .pressed => |i| .{ .pressed = i },
            .wrote => |w| switch (w) {
                .ok => |name| .{ .wrote = "ok", .name = try self.baseName(name) },
                else => .{ .wrote = @tagName(w) },
            },
            .read => |r| .{ .read = @tagName(r) },
            .generated => |g| .{ .generated = @tagName(g) },
            .persisted, .copied => |o| .{ .outcome = @tagName(o) },
        };
    }
};

fn scenarioConfig(sc: ScenarioConfig) !config.Config {
    var cfg = test_defaults.testConfigDefaults();
    cfg.auto_restore = sc.auto_restore;
    cfg.auto_new = sc.auto_new;
    cfg.auto_save = sc.auto_save;
    if (sc.difficulty) |name| cfg.difficulty = std.meta.stringToEnum(config.Difficulty, name) orelse return error.UnknownDifficulty;
    return cfg;
}

/// Bytes of a saved game file, owned by `gpa`.
fn savedGame(gpa: std.mem.Allocator, cfg: config.Config, file: SavedFile) ![]u8 {
    if (file.corrupt) return gpa.dupe(u8, "this is not a saved game");
    var engine = try game_engine.GameEngine.init(puzzle_gen.PuzzleGen.default(), cfg);
    defer engine.deinit();
    _ = engine.newFromOneLinePuzzle(file.puzzle_line);
    for (file.moves) |m| {
        const event = engine.exec(.{ .fill = .{ .row = @intCast(m.row), .col = @intCast(m.col), .digit = cell.rawToCellValue(m.digit) } });
        if (event != .ok) return error.SetupMoveRejected;
    }
    return engine.toSaveFormat(gpa);
}

fn putFile(gpa: std.mem.Allocator, cfg: config.Config, transport: *MemoryTransport, file: SavedFile) !void {
    if (file.missing) return;
    const bytes = try savedGame(gpa, cfg, file);
    defer gpa.free(bytes);
    const path = try std.fmt.allocPrint(gpa, FOLDER_PREFIX ++ "{s}", .{file.name});
    defer gpa.free(path);
    try transport.put(path, bytes);
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

/// The command a scenario step issues; `view` picks the cell for `fill_first_empty`, and a
/// config step is the `set_config` the menus send from `cfg`.
fn stepCommand(step: Step, view: ?board.Board.BoardView, cfg: config.Config) !command.Command {
    if (configChange(step, cfg)) |change| return .{ .set_config = change };
    if (step.fill) |m| return .{ .fill = .{ .row = @intCast(m.row), .col = @intCast(m.col), .digit = cell.rawToCellValue(m.digit) } };
    if (step.clear) |at| return .{ .clear = .{ .row = @intCast(at.row), .col = @intCast(at.col) } };
    if (step.fill_first_empty != null) return .{ .fill = if (view) |v| try firstEmptyLegalFill(v) else .{ .row = 0, .col = 0, .digit = .zero } };
    if (step.undo != null) return .{ .undo = {} };
    if (step.redo != null) return .{ .redo = {} };
    if (step.hint != null) return .{ .hint = .{} };
    if (step.hint_at) |at| return .{ .hint = .{ .row = @intCast(at.row), .col = @intCast(at.col) } };
    if (step.solve != null) return .{ .solve_for_me = {} };
    if (step.paste) |line| return .{ .paste = .{ .line = line } };
    if (step.open) |file| return .{ .open = .{ .path = file.name } };
    if (step.import != null) return .{ .import = .{ .path = IMPORT_NAME } };
    if (step.save != null) return .{ .save = .{ .path = null } };
    if (step.save_as) |name| return .{ .save_as = .{ .path = name } };
    if (step.copy != null) return .{ .copy = {} };
    if (step.new) |name| return .{ .new = .{ .difficulty = std.meta.stringToEnum(config.Difficulty, name) orelse return error.UnknownDifficulty } };
    if (step.new_line) |line| return .{ .new = .{ .puzzle = line } };
    if (step.@"export" != null) return .{ .@"export" = .{ .path = null } };
    if (step.pencil) |m| return .{ .pencil = .{ .row = @intCast(m.row), .col = @intCast(m.col), .digit = cell.rawToCellValue(m.digit) } };
    if (step.toggle_pencil_mode != null) return .{ .toggle_pencil_mode = {} };
    if (step.select) |at| return .{ .select = .{ .row = @intCast(at.row), .col = @intCast(at.col) } };
    if (step.deselect != null) return .{ .deselect = {} };
    if (step.open_cancel != null) return .{ .open = .{ .path = null } };
    if (step.import_cancel != null) return .{ .import = .{ .path = null } };
    if (step.save_as_cancel != null) return .{ .save_as = .{ .path = null } };
    if (step.export_cancel != null) return .{ .@"export" = .{ .path = null } };
    if (step.paste_fails != null) return .{ .paste = .{ .line = null } };
    if (step.copy_fails != null) return .{ .copy = {} };
    return error.UnknownScenarioStep;
}

/// A config step's change: toggles flip the field's value in `cfg`, choices go by name.
fn configChange(step: Step, cfg: config.Config) ?config_table.Change {
    const row = config_table.row;
    if (step.toggle_auto_save != null) return config_table.toggle(cfg, row("auto_save"));
    if (step.toggle_region != null) return config_table.toggle(cfg, row("show_region"));
    if (step.toggle_show_marks != null) return config_table.toggle(cfg, row("show_marks"));
    if (step.toggle_warn_solvability != null) return config_table.toggle(cfg, row("warn_solvability"));
    if (step.toggle_auto_restore != null) return config_table.toggle(cfg, row("auto_restore"));
    if (step.toggle_auto_new != null) return config_table.toggle(cfg, row("auto_new"));
    if (step.set_theme) |name| return .{ .field = row("theme").field, .value = .{ .choice = name } };
    if (step.set_difficulty) |name| return .{ .field = row("difficulty").field, .value = .{ .choice = name } };
    if (step.set_log_level) |name| return .{ .field = row("log_level").field, .value = .{ .choice = name } };
    return null;
}

/// What one launch of the shell runs against; a relaunch keeps all of it.
const Rig = struct {
    io: std.Io,
    data_dir: []const u8,
    recorder: *Recorder,
    transport: *MemoryTransport,
    out: *std.Io.Writer,

    fn launch(self: Rig, cfg: config.Config) !shell.Sudoku {
        var app = try shell.Sudoku.init(cfg, self.recorder.asFacade(), self.transport.asTransport(), self.out, .{
            .io = self.io,
            .data_dir = self.data_dir,
            .visible_save_dir = MemoryTransport.DIR,
        });
        app.step_observer = self.recorder.observer();
        return app;
    }

    fn run(app: *shell.Sudoku, recorder: *Recorder, cmd: command.Command) !void {
        recorder.pending = cmd;
        _ = try app.turn();
    }
};

fn finalState(arena: std.mem.Allocator, app: *shell.Sudoku, recorder: *Recorder) !Final {
    const view = app.engine.eventBoard();
    const cells = try arena.alloc(u8, board.CELL_COUNT);
    const givens = try arena.alloc(u8, board.CELL_COUNT);
    const line = app.engine.toPuzzle();
    for (0..9) |r| for (0..9) |c| {
        const i = r * 9 + c;
        cells[i] = line[i];
        givens[i] = if (view.isGiven(@intCast(r), @intCast(c))) '1' else '0';
    };
    const legend = app.engine.getLegend(app.cfg.auto_save);
    const cfg = app.cfg;
    return .{
        .cells = cells,
        .givens = givens,
        .undo = legend.undo,
        .redo = legend.redo,
        .file = if (app.file_session.currentFile()) |f| try arena.dupe(u8, std.fs.path.basename(f)) else null,
        .status = recorder.last_status,
        .selected = recorder.last_selected,
        .region = recorder.last_region,
        .config = .{
            .difficulty = @tagName(cfg.difficulty),
            .log_level = @tagName(cfg.log_level),
            .theme = @tagName(cfg.theme),
            .show_region = cfg.show_region,
            .warn_solvability = cfg.warn_solvability,
            .auto_restore = cfg.auto_restore,
            .auto_new = cfg.auto_new,
            .auto_save = cfg.auto_save,
        },
    };
}

fn runScenario(arena: std.mem.Allocator, io: std.Io, data_dir: []const u8, scenario: Scenario) !Transcript {
    const gpa = std.testing.allocator;
    const cfg = try scenarioConfig(scenario.config);
    var recorder = Recorder{ .arena = arena, .answers = scenario.answers };
    var transport = MemoryTransport.init(gpa);
    defer transport.deinit();
    transport.fail_writes = scenario.world.fail_writes;
    transport.fail_reads = scenario.world.fail_reads;
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    const settings_dir = if (scenario.world.settings_fail) UNWRITABLE_DATA_DIR else data_dir;
    const rig = Rig{ .io = io, .data_dir = settings_dir, .recorder = &recorder, .transport = &transport, .out = &out.writer };

    for (scenario.files) |file| try putFile(gpa, cfg, &transport, file);
    if (scenario.current_file) |file| try putFile(gpa, cfg, &transport, file);

    var app = try rig.launch(cfg);
    defer app.deinit();
    try app.runStartupFlow(if (scenario.current_file) |f| f.name else null);
    if (scenario.expect.solved_after_startup) |solved| {
        try std.testing.expectEqual(solved, app.engine.state.board.isSolved());
    }
    if (scenario.puzzle_line) |line| {
        recorder.recording = false;
        try Rig.run(&app, &recorder, .{ .new = .{ .puzzle = line } });
        recorder.recording = true;
        transport.clearWritten();
    }

    for (scenario.steps) |step| {
        if (step.relaunch != null) {
            const written = transport.written.items;
            if (written.len == 0) return error.NothingToRelaunch;
            const path = try gpa.dupe(u8, std.fs.path.basename(written[written.len - 1]));
            defer gpa.free(path);
            const next = try rig.launch(app.cfg);
            app.deinit();
            app = next;
            try app.runStartupFlow(path);
            continue;
        }
        if (step.close != null) return error.CloseIsNotANativeStep;
        if (step.open) |file| try putFile(gpa, cfg, &transport, file);
        if (step.import) |text| try transport.put(FOLDER_PREFIX ++ IMPORT_NAME, text);
        try Rig.run(&app, &recorder, try stepCommand(step, app.engine.eventBoard(), app.cfg));
    }

    const written = try arena.alloc([]const u8, transport.written.items.len);
    for (transport.written.items, written) |path, *name| name.* = try arena.dupe(u8, std.fs.path.basename(path));
    try checkExpect(io, settings_dir, scenario.expect, recorder.events.items, written, &app, &recorder);
    return .{ .name = scenario.name, .events = recorder.events.items, .final = try finalState(arena, &app, &recorder) };
}

/// The scenario's own expectations, checked here as the web and Android runs check them.
fn checkExpect(io: std.Io, data_dir: []const u8, expect: Expect, events: []const Event, written: []const []const u8, app: *shell.Sudoku, recorder: *const Recorder) !void {
    var questions: usize = 0;
    var errors: usize = 0;
    for (events) |e| if (e.buttons) |b| {
        if (b.len == 1) errors += 1 else questions += 1;
    };
    if (expect.questions) |want| try std.testing.expectEqual(want, questions);
    if (expect.errors) |want| try std.testing.expectEqual(want, errors);
    if (expect.written) |want| {
        try std.testing.expectEqual(want.len, written.len);
        for (want, written) |w, got| try std.testing.expectEqualStrings(w, got);
    }
    if (expect.settings) |want| {
        const saved = try config_store.loadOrDefault(std.testing.allocator, io, data_dir);
        if (want.auto_save) |on| try std.testing.expectEqual(on, saved.auto_save);
        if (want.show_region) |on| try std.testing.expectEqual(on, saved.show_region);
        if (want.theme) |name| try std.testing.expectEqualStrings(name, @tagName(saved.theme));
        if (want.show_marks) |on| try std.testing.expectEqual(on, saved.show_marks);
    }
    if (expect.legend) |want| {
        const got = app.engine.getLegend(app.cfg.auto_save);
        if (want.undo) |on| try std.testing.expectEqual(on, got.undo);
        if (want.redo) |on| try std.testing.expectEqual(on, got.redo);
    }
    const view = app.engine.eventBoard();
    for (expect.probes) |p| {
        const row: u4 = @intCast(p.row);
        const col: u4 = @intCast(p.col);
        try std.testing.expectEqual(cell.rawToCellValue(p.value), view.get(row, col));
        try std.testing.expectEqual(p.given, view.isGiven(row, col));
        if (p.marks) |want| try std.testing.expectEqual(want, view.marks(row, col));
    }
    if (expect.selected) |want| try std.testing.expectEqual(@as(?CellAt, want), recorder.last_selected);
    if (expect.nothing_selected != null) try std.testing.expectEqual(@as(?CellAt, null), recorder.last_selected);
}

/// Every command reaches core in some scenario, or is named as one no flow runs for.
fn checkEveryCommandCovered(parsed: Scenarios) !void {
    var seen = std.EnumSet(command.CommandTag).empty;
    for (parsed.scenarios) |scenario| for (scenario.steps) |step| {
        if (step.relaunch != null or step.close != null) continue;
        seen.insert(std.meta.activeTag(try stepCommand(step, null, config.Config.default())));
    };
    for (std.meta.tags(command.CommandTag)) |tag| {
        if (seen.contains(tag) or parsed.flowless_commands.map.contains(@tagName(tag))) continue;
        std.debug.print("parity: command {s} has no scenario\n", .{@tagName(tag)});
        return error.CommandWithoutScenario;
    }
}

fn writeTranscripts(io: std.Io, arena: std.mem.Allocator, transcripts: []const Transcript) !void {
    const kinds = std.meta.tags(std.meta.Tag(flow_mod.Step));
    const names = try arena.alloc([]const u8, kinds.len);
    for (kinds, names) |k, *n| n.* = @tagName(k);
    const doc = .{
        .step_kinds = names,
        .generated_lines = .{
            .easy = puzzle_gen.PuzzleGen.generate(.easy),
            .medium = puzzle_gen.PuzzleGen.generate(.medium),
            .hard = puzzle_gen.PuzzleGen.generate(.hard),
        },
        .scenarios = transcripts,
    };
    const json = try std.json.Stringify.valueAlloc(arena, doc, .{ .emit_null_optional_fields = false, .whitespace = .indent_1 });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, TRANSCRIPTS_DIR);
    // The coverage run writes the same file while the glue tests may be reading it: replace it whole.
    var tmp_name: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_name, TRANSCRIPTS_DIR ++ "/" ++ TRANSCRIPTS_FILE ++ ".{d}.tmp", .{std.c.getpid()});
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = json });
    try cwd.rename(tmp, cwd, TRANSCRIPTS_DIR ++ "/" ++ TRANSCRIPTS_FILE, io);
}

test "parity scenarios: native shell meets every shared scenario and writes its transcripts" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, SCENARIOS_PATH, gpa, .unlimited);
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(Scenarios, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.scenarios.len > 0);
    try checkEveryCommandCovered(parsed.value);

    var transcripts: std.ArrayListUnmanaged(Transcript) = .empty;
    for (parsed.value.scenarios) |scenario| {
        if (!scenario.runsOnNative()) continue;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer gpa.free(rel);
        const data_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, rel, gpa);
        defer gpa.free(data_dir);
        const transcript = runScenario(arena, io, data_dir, scenario) catch |err| {
            std.debug.print("parity scenario failed on native: {s}\n", .{scenario.name});
            return err;
        };
        try transcripts.append(arena, transcript);
    }
    try writeTranscripts(io, arena, transcripts.items);
}
