const about = @import("../../core/about.zig");
const build_info = @import("../../build_info.zig");
const display_width = @import("display_width.zig");
const about_format = @import("about_format.zig");
const board = @import("../../core/board/board.zig");
const cell = @import("../../core/board/cell.zig");
const parser = @import("parser.zig");

/// Shown when no command can be typed at the prompt.
const NO_COMMANDS_MSG = "No commands are available right now.";
const _command = @import("../../core/command.zig");
const styler = @import("styler.zig");
const std = @import("std");
const Io = std.Io;
const facade = @import("../../core/renderer/facade.zig");
const input_source = @import("../../native/input_source.zig");
const puzzle_gen = @import("../../core/puzzle_gen/mod.zig");

const config = @import("../../core/config.zig");
const logger = @import("../../core/logger.zig");
const Difficulty = @import("../../core/puzzle_gen/mod.zig").Difficulty;
const flow_step = @import("../../core/flow/step.zig");

/// Terminal renderer for the 9x9 Sudoku board.
///
/// Native terminal Facade implementation (ASCII/ANSI). Web presentation is JS
/// from wasm JSON; it does not implement this vtable today.
///
/// Parameterised over StylerType so tests can use PlainStyler and
/// production code swaps in ANSI-capable styler at runtime.

// Box-drawing border strings - shared constants for the 9x9 grid.
pub fn columnHeader() []const u8 {
    return "   A B C │ D E F │ G H I \n";
}

pub fn topBorder() []const u8 {
    return " ╭───────┼───────┼───────╮\n";
}

pub fn midBorder() []const u8 {
    return " ├───────┼───────┼───────┤\n";
}

pub fn bottomBorder() []const u8 {
    return " ╰───────┴───────┴───────╯\n";
}

/// Minimum visible width (columns) for status/error message boxes. Message
/// lines and the legend can push it wider — never narrower than this.
const box_min_width: usize = 80;
const SAVE_AS_PROMPT = "Save as (Enter keeps the current file): ";

fn menuPickIsQuit(pick: []const u8) bool {
    return std.mem.eql(u8, pick, "10") or
        std.ascii.eqlIgnoreCase(pick, "q") or
        std.ascii.eqlIgnoreCase(pick, "quit");
}

fn hintCommandFromTarget(target: ?facade.Selection) _command.Command {
    return .{ .hint = .{
        .row = if (target) |t| t.row else null,
        .col = if (target) |t| t.col else null,
    } };
}

/// Terminal implementation of the Renderer Facade.
///
/// Stores a writer pointer, a styler
/// reference. Instance methods are routed through the Facade vtable via Make()
/// wrapper functions that coerce fn values to fn pointers.
pub fn AsciiRenderer(StylerType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: *Io.Writer,
        styler: *StylerType,
        inputSource: input_source.ReaderSource,
        // Owned dialog paths for open and save-as; ImportData/SaveData/OpenData borrow them.
        open_path: ?[]u8 = null,
        save_as_path: ?[]u8 = null,
        // Owned dialog path for the import command; not part of the save-target cache.
        import_path: ?[]u8 = null,
        // Owned dialog path for the export command; not part of the save-target cache.
        export_path: ?[]u8 = null,
        paste_line: ?[]u8 = null,
        legend_line_width: usize = 0,
        can_solve: bool = false,

        /// Construct with writer (all output), styler pointer, and input source.
        pub fn init(allocator: std.mem.Allocator, writer: *Io.Writer, styler_ptr: *StylerType, inputSource: input_source.ReaderSource) @This() {
            return .{ .allocator = allocator, .writer = writer, .styler = styler_ptr, .inputSource = inputSource };
        }

        /// Free the owned dialog paths.
        pub fn deinit(self: *@This()) void {
            if (self.open_path) |name| {
                self.allocator.free(name);
            }
            if (self.save_as_path) |name| {
                self.allocator.free(name);
            }
            if (self.import_path) |name| {
                self.allocator.free(name);
            }
            if (self.export_path) |name| {
                self.allocator.free(name);
            }
            if (self.paste_line) |line| {
                self.allocator.free(line);
            }
        }

        /// Draw the full board: column header, borders, styled rows via formatRow,
        /// with box-drawing borders between 3x3 boxes. When status_msg is non-null,
        /// draw it in a box frame below the grid — non-blocking, no input read;
        /// null ⇒ plain board.
        pub fn render(self: *@This(), view: board.Board.BoardView, status_msg: ?[]const u8, selection: ?facade.Selection) anyerror!void {
            try self.writer.writeAll(columnHeader());
            try self.writer.writeAll(topBorder());
            for (0..9) |row| {
                var rowBuf: [256]u8 = undefined;
                const styler_sel: ?styler.CellSelection = if (selection) |s| .{ .row = s.row, .col = s.col } else null;
                const line = try self.styler.formatRow(row, view, styler_sel, &rowBuf);
                try self.writer.writeAll(line);
                if (row == 2 or row == 5) {
                    try self.writer.writeAll(midBorder());
                }
            }
            try self.writer.writeAll(bottomBorder());
            if (status_msg) |msg| try self.drawBox(msg);
        }

        /// Shared box frame for status and error messages. Width = max(box_min_width,
        /// legend line width, longest message line + 4) — content never hides.
        /// One framed line per message line. Pure output — never reads input.
        fn drawBox(self: *@This(), msg: []const u8) anyerror!void {
            var width: usize = box_min_width;
            if (self.legend_line_width > width) width = self.legend_line_width;
            var probe = std.mem.splitScalar(u8, msg, '\n');
            while (probe.next()) |ln| {
                const cols = display_width.columns(ln);
                if (cols + 4 > width) width = cols + 4;
            }
            const inner = width - 2;
            const dash = "─";
            try self.writer.writeAll("┌");
            for (0..inner) |_| try self.writer.writeAll(dash);
            try self.writer.writeAll("┐\n");
            var lines = std.mem.splitScalar(u8, msg, '\n');
            while (lines.next()) |ln| {
                const padded = try display_width.padColumns(self.allocator, ln, inner);
                defer self.allocator.free(padded);
                try self.writer.writeAll("│");
                try self.writer.writeAll(padded);
                try self.writer.writeAll("│\n");
            }
            try self.writer.writeAll("└");
            for (0..inner) |_| try self.writer.writeAll(dash);
            try self.writer.writeAll("┘\n");
        }

        /// Implement Facade showLegend_fn. Build command legend from Legend,
        /// disambiguate prefixes, print "Command: ...". Arena allocates temp strings.
        pub fn showLegend(self: *@This(), commands: legend.Legend) anyerror!void {
            var names: [7][]const u8 = undefined;
            const count = commands.getNames(&names);

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const entries = try disambiguate.getMinimumPrefixes(arena.allocator(), names[0..count]);
            const str = try legend.formatLegend(arena.allocator(), entries);
            _ = try self.writer.print("  Command: {s}\n", .{str});
            self.legend_line_width = 11 + str.len;
            self.can_solve = commands.solve;
        }

        /// Read one line from the injected input source.
        /// Caller owns returned string and must free it.
        pub fn readLine(self: *@This()) facade.Error![]u8 {
            const raw = self.inputSource.readline() catch return facade.Error.System;
            // Caller needs an owned copy of the trimmed line
            const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
            defer self.allocator.free(raw);
            return self.allocator.dupe(u8, trimmed) catch return facade.Error.System;
        }

        /// Implement Facade showError_fn. Draw the error in the shared box frame, then
        /// "Press Enter to continue..." and wait on stdin (via injected input source).
        pub fn showError(self: *@This(), msg: []const u8) facade.Error!void {
            const owned = self.allocator.dupe(u8, msg) catch return facade.Error.System;
            defer self.allocator.free(owned);
            self.drawBox(owned) catch return facade.Error.System;
            self.writer.print("Press Enter to continue... ", .{}) catch return facade.Error.System;

            const line = try self.readLine();
            defer self.allocator.free(line);
        }

        /// Two-button question: title line, then text with both labels; true only when the player types `ok_label`.
        pub fn ask(self: *@This(), question: flow_step.Ask) facade.Error!bool {
            self.writer.print("{s}\n{s} [{s}/{s}]: ", .{ question.title, question.text, question.ok_label, question.cancel_label }) catch return facade.Error.System;
            const line = self.readLine() catch return false;
            defer self.allocator.free(line);
            return std.ascii.eqlIgnoreCase(line, question.ok_label);
        }

        /// Internal — prompt for filename with default, return owned string.
        /// Prompt for a Save As path; an empty answer returns null so core suggests the name.
        fn saveAsDialog(self: *@This()) facade.Error!?[]u8 {
            self.writer.writeAll(SAVE_AS_PROMPT) catch return facade.Error.System;
            const line = try self.readLine();
            if (line.len == 0) {
                self.allocator.free(line);
                return null;
            }
            return line;
        }

        /// Prompt for a file path; empty input means cancelled.
        fn pathDialog(self: *@This(), prompt: []const u8) facade.Error!_command.OpenFileResult {
            self.writer.print("{s}", .{prompt}) catch return facade.Error.System;

            const line = self.readLine() catch return .Cancelled;

            if (line.len == 0) {
                defer self.allocator.free(line);
                return .Cancelled;
            }
            return .{ .FileName = line };
        }

        /// Prompt for a one-line puzzle string; empty input means cancelled.
        fn puzzleLineDialog(self: *@This()) facade.Error!_command.OpenFileResult {
            self.writer.writeAll("Paste puzzle line: ") catch return facade.Error.System;

            const line = self.readLine() catch return .Cancelled;

            if (line.len == 0) {
                defer self.allocator.free(line);
                return .Cancelled;
            }
            return .{ .FileName = line };
        }

        fn pickDifficulty(self: *@This()) facade.Error!Difficulty {
            self.writer.writeAll("Difficulty:\n  1) Easy\n  2) Medium\n  3) Hard\n> ") catch return facade.Error.System;
            const pick = self.readLine() catch return facade.Error.System;
            defer self.allocator.free(pick);
            if (std.mem.eql(u8, pick, "1")) return .easy;
            if (std.mem.eql(u8, pick, "2")) return .medium;
            if (std.mem.eql(u8, pick, "3")) return .hard;
            try self.showError("invalid choice — enter 1, 2, or 3");
            return try self.pickDifficulty();
        }

        fn pickLogLevel(self: *@This()) facade.Error!logger.Severity {
            self.writer.writeAll("Log level:\n  1) debug\n  2) info\n  3) warn\n  4) err\n  5) fatal\n> ") catch return facade.Error.System;
            const pick = self.readLine() catch return facade.Error.System;
            defer self.allocator.free(pick);
            if (std.mem.eql(u8, pick, "1")) return .debug;
            if (std.mem.eql(u8, pick, "2")) return .info;
            if (std.mem.eql(u8, pick, "3")) return .warn;
            if (std.mem.eql(u8, pick, "4")) return .err;
            if (std.mem.eql(u8, pick, "5")) return .fatal;
            try self.showError("invalid choice — enter 1–5");
            return try self.pickLogLevel();
        }

        fn pickTheme(self: *@This()) facade.Error!config.ViewTheme {
            self.writer.writeAll("Theme:\n  1) dark\n  2) light\n> ") catch return facade.Error.System;
            const pick = self.readLine() catch return facade.Error.System;
            defer self.allocator.free(pick);
            if (std.mem.eql(u8, pick, "1")) return .dark;
            if (std.mem.eql(u8, pick, "2")) return .light;
            try self.showError("invalid choice — enter 1 or 2");
            return try self.pickTheme();
        }

        /// Terminal settings sheet (native); web uses File → Settings modal.
        fn showSettingsMenu(
            self: *@This(),
            show_region: bool,
            warn_solvability: bool,
            difficulty: Difficulty,
            log_level: logger.Severity,
            theme: config.ViewTheme,
            auto_restore: bool,
            auto_new: bool,
            auto_save: bool,
            hint_target: ?facade.Selection,
        ) facade.Error!_command.ParseCommandResult {
            const warn_state = if (warn_solvability) "on" else "off";
            const auto_restore_state = if (auto_restore) "on" else "off";
            const auto_new_state = if (auto_new) "on" else "off";
            const auto_save_state = if (auto_save) "on" else "off";
            self.writer.writeAll("\nSettings:\n") catch return facade.Error.System;
            self.writer.print("  1) Solvability warnings ({s})\n", .{warn_state}) catch return facade.Error.System;
            self.writer.print("  2) Default difficulty ({s})\n", .{@tagName(difficulty)}) catch return facade.Error.System;
            self.writer.print("  3) Log level ({s})\n", .{@tagName(log_level)}) catch return facade.Error.System;
            self.writer.print("  4) Theme ({s})\n", .{@tagName(theme)}) catch return facade.Error.System;
            self.writer.print("  5) Auto restore ({s})\n", .{auto_restore_state}) catch return facade.Error.System;
            self.writer.print("  6) Auto new ({s})\n", .{auto_new_state}) catch return facade.Error.System;
            self.writer.print("  7) Auto save ({s})\n", .{auto_save_state}) catch return facade.Error.System;
            self.writer.writeAll("  8) Back\n> ") catch return facade.Error.System;
            const pick = self.readLine() catch return facade.Error.System;
            defer self.allocator.free(pick);
            if (std.mem.eql(u8, pick, "1")) {
                return .{ .valid = _command.Command{ .toggle_warn_solvability = {} } };
            }
            if (std.mem.eql(u8, pick, "2")) {
                const diff = try self.pickDifficulty();
                return .{ .valid = _command.Command{ .set_difficulty = diff } };
            }
            if (std.mem.eql(u8, pick, "3")) {
                const level = try self.pickLogLevel();
                return .{ .valid = _command.Command{ .set_log_level = level } };
            }
            if (std.mem.eql(u8, pick, "4")) {
                const picked = try self.pickTheme();
                return .{ .valid = _command.Command{ .set_theme = picked } };
            }
            if (std.mem.eql(u8, pick, "5")) {
                return .{ .valid = _command.Command{ .toggle_auto_restore = {} } };
            }
            if (std.mem.eql(u8, pick, "6")) return .{ .valid = _command.Command{ .toggle_auto_new = {} } };
            if (std.mem.eql(u8, pick, "7")) return .{ .valid = _command.Command{ .toggle_auto_save = {} } };
            if (std.mem.eql(u8, pick, "8")) {
                return try self.showMenu(show_region, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target);
            }
            try self.showError("invalid settings choice");
            return try self.showSettingsMenu(show_region, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target);
        }

        /// Numbered session/view submenu — file operations, view, hint, quit.
        pub fn showMenu(
            self: *@This(),
            show_region: bool,
            warn_solvability: bool,
            difficulty: Difficulty,
            log_level: logger.Severity,
            theme: config.ViewTheme,
            auto_restore: bool,
            auto_new: bool,
            auto_save: bool,
            hint_target: ?facade.Selection,
        ) facade.Error!_command.ParseCommandResult {
            const region_state = if (show_region) "on" else "off";
            const auto_save_state = if (auto_save) "on" else "off";
            self.writer.writeAll("\nMenu:\n") catch return facade.Error.System;
            if (auto_save) {
                self.writer.print("  1) Save (auto: {s})\n", .{auto_save_state}) catch return facade.Error.System;
            } else {
                self.writer.writeAll("  1) Save\n") catch return facade.Error.System;
            }
            self.writer.writeAll("  2) Open\n") catch return facade.Error.System;
            self.writer.writeAll("  3) Import\n") catch return facade.Error.System;
            self.writer.writeAll("  4) Export\n") catch return facade.Error.System;
            self.writer.writeAll("  5) New\n") catch return facade.Error.System;
            self.writer.writeAll("  6) Save As\n") catch return facade.Error.System;
            self.writer.print("  7) Region ({s})\n", .{region_state}) catch return facade.Error.System;
            self.writer.writeAll("  8) Hint\n") catch return facade.Error.System;
            self.writer.writeAll("  9) About\n") catch return facade.Error.System;
            self.writer.writeAll("  10) Quit\n") catch return facade.Error.System;
            if (self.can_solve) {
                self.writer.writeAll("  11) Solve\n") catch return facade.Error.System;
            } else {
                self.writer.writeAll("  11) Solve (unavailable)\n") catch return facade.Error.System;
            }
            self.writer.writeAll("  12) Copy puzzle line\n") catch return facade.Error.System;
            self.writer.writeAll("  13) Paste puzzle line\n") catch return facade.Error.System;
            self.writer.writeAll("  14) Settings\n") catch return facade.Error.System;
            self.writer.writeAll("> ") catch return facade.Error.System;

            const pick = self.readLine() catch return facade.Error.System;
            defer self.allocator.free(pick);

            if (std.mem.eql(u8, pick, "1")) return .{ .valid = _command.Command{ .save = .{ .path = null } } };
            if (std.mem.eql(u8, pick, "2")) return .{ .valid = _command.Command{ .open = .{ .path = null } } };
            if (std.mem.eql(u8, pick, "3")) return .{ .valid = _command.Command{ .import = .{ .path = null } } };
            if (std.mem.eql(u8, pick, "4")) return .{ .valid = _command.Command{ .@"export" = .{ .path = null } } };
            if (std.mem.eql(u8, pick, "5")) return .{ .valid = _command.Command{ .new = .{ .puzzle = null } } };
            if (std.mem.eql(u8, pick, "6")) return .{ .valid = _command.Command{ .save_as = .{ .path = null } } };
            if (std.mem.eql(u8, pick, "7")) return .{ .valid = _command.Command{ .toggle_region = {} } };
            if (std.mem.eql(u8, pick, "8")) {
                return .{ .valid = hintCommandFromTarget(hint_target) };
            }
            if (std.mem.eql(u8, pick, "9")) {
                try self.showAbout();
                return try self.showMenu(show_region, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target);
            }
            if (menuPickIsQuit(pick)) return .{ .valid = _command.Command.quit };
            if (std.mem.eql(u8, pick, "11")) {
                if (!self.can_solve) return try self.showMenu(show_region, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target);
                return .{ .valid = _command.Command{ .solve_for_me = {} } };
            }
            if (std.mem.eql(u8, pick, "12")) return .{ .valid = _command.Command{ .copy = {} } };
            if (std.mem.eql(u8, pick, "13")) return .{ .valid = _command.Command{ .paste = .{ .line = null } } };
            if (std.mem.eql(u8, pick, "14")) {
                return try self.showSettingsMenu(show_region, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target);
            }
            try self.showError("invalid menu choice");
            return try self.showMenu(show_region, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target);
        }

        /// Help/About — product metadata with acknowledgement.
        pub fn showAbout(self: *@This()) facade.Error!void {
            const text = about_format.formatNativeText(self.allocator) catch return facade.Error.System;
            defer self.allocator.free(text);
            try self.showError(text);
        }

        /// Live puzzle-gen feedback on the session writer (Facade vtable pass-through).
        pub fn reportGenProgress(self: *@This(), event: puzzle_gen.GenProgressEvent) facade.Error!void {
            var msg_buf: [96]u8 = undefined;
            const msg = puzzle_gen.formatProgressEvent(event, &msg_buf) orelse return;
            self.writer.print("{s}\n", .{msg}) catch return facade.Error.System;
        }

        /// New = generate — choose a difficulty; returns an owned puzzle string.
        /// Ask for New's difficulty; null when the pick is not one of the levels.
        pub fn newGameDialog(self: *@This()) facade.Error!?Difficulty {
            self.writer.writeAll("Difficulty:\n") catch return facade.Error.System;
            const levels = [_][]const u8{ "Easy", "Medium", "Hard" };
            for (levels, 0..) |name, i| {
                self.writer.print("  {d}) {s}\n", .{ i + 1, name }) catch return facade.Error.System;
            }
            self.writer.writeAll("> ") catch return facade.Error.System;
            const pick = self.readLine() catch return facade.Error.System;
            defer self.allocator.free(pick);
            if (std.mem.eql(u8, pick, "1")) return .easy;
            if (std.mem.eql(u8, pick, "2")) return .medium;
            if (std.mem.eql(u8, pick, "3")) return .hard;
            return null;
        }

        /// Implement Facade getCommandInput_fn. Reads a line, parses it.
        pub fn getCommandInput(
            self: *@This(),
            names: []const []const u8,
            show_region: bool,
            warn_solvability: bool,
            difficulty: Difficulty,
            log_level: logger.Severity,
            theme: config.ViewTheme,
            auto_restore: bool,
            auto_new: bool,
            auto_save: bool,
            hint_target: ?facade.Selection,
        ) facade.Error!_command.ParseCommandResult {
            while (true) {
                self.writer.writeAll("> ") catch return facade.Error.System;
                const raw = self.inputSource.readline() catch return .{ .valid = _command.Command.quit };
                defer self.allocator.free(raw);
                if (names.len == 0) return .{ .error_msg = NO_COMMANDS_MSG };

                var rsl = parser.parseWithCommands(raw, names);
                if (std.meta.activeTag(rsl) == .valid and std.meta.activeTag(rsl.valid) == .menu) {
                    rsl = try self.showMenu(show_region, warn_solvability, difficulty, log_level, theme, auto_restore, auto_new, auto_save, hint_target);
                }
                // A cancelled dialog goes back to the command prompt quietly.
                if (self.completeFromDialog(&rsl)) return rsl;
            }
        }

        /// Ask the dialog a command needs (path, puzzle line, difficulty); false when the player cancels.
        fn completeFromDialog(self: *@This(), rsl: *_command.ParseCommandResult) bool {
            // Intercept save_as: the typed path, or null for core's suggestion.
            if (std.meta.activeTag(rsl.*) == .valid and
                std.meta.activeTag(rsl.*.valid) == .save_as)
            {
                const path = self.saveAsDialog() catch return false;
                if (self.save_as_path) |old| self.allocator.free(old);
                self.save_as_path = path;
                rsl.*.valid.save_as.path = path;
            }

            // Intercept open: always prompt for the file.
            if (std.meta.activeTag(rsl.*) == .valid and
                std.meta.activeTag(rsl.*.valid) == .open)
            {
                const file_result = self.pathDialog("Open file: ") catch return false;
                switch (file_result) {
                    .FileName => |new_path| {
                        if (self.open_path) |old| self.allocator.free(old);
                        self.open_path = new_path;
                        rsl.*.valid.open.path = new_path;
                    },
                    .Cancelled => return false,
                }
            }

            // Intercept import: prompt for a text file; no filename cache — import does not change the save target
            if (std.meta.activeTag(rsl.*) == .valid and
                std.meta.activeTag(rsl.*.valid) == .import)
            {
                const file_result = self.pathDialog("Import file: ") catch return false;
                switch (file_result) {
                    .FileName => |path| {
                        // Renderer owns the import dialog path; ImportData.path borrows it
                        if (self.import_path) |old| self.allocator.free(old);
                        self.import_path = path;
                        rsl.*.valid.import.path = path;
                    },
                    .Cancelled => return false,
                }
            }
            // Intercept paste: prompt for a one-line puzzle; engine owns parse/validate.
            if (std.meta.activeTag(rsl.*) == .valid and std.meta.activeTag(rsl.*.valid) == .paste) {
                const line_result = self.puzzleLineDialog() catch return false;
                switch (line_result) {
                    .FileName => |line| {
                        if (self.paste_line) |old| self.allocator.free(old);
                        self.paste_line = line;
                        rsl.*.valid.paste.line = line;
                    },
                    .Cancelled => return false,
                }
            }
            // Intercept export: prompt for a destination file; no filename cache — like import
            if (std.meta.activeTag(rsl.*) == .valid and
                std.meta.activeTag(rsl.*.valid) == .@"export")
            {
                const file_result = self.pathDialog("Export file: ") catch return false;
                switch (file_result) {
                    .FileName => |path| {
                        // Renderer owns the export dialog path; ExportData.path borrows it
                        if (self.export_path) |old| self.allocator.free(old);
                        self.export_path = path;
                        rsl.*.valid.@"export".path = path;
                    },
                    .Cancelled => return false,
                }
            }
            // Intercept new: the chosen difficulty rides the command; core generates.
            if (std.meta.activeTag(rsl.*) == .valid and
                std.meta.activeTag(rsl.*.valid) == .new)
            {
                const picked = (self.newGameDialog() catch null) orelse return false;
                rsl.*.valid.new.difficulty = picked;
            }

            return true;
        }
    };
}

// Tests - real renderer path, no mocks. Use Io.Writer.Allocating to
// capture output for assertions instead of hitting stdout.

const game_engine = @import("../../core/engine/game_engine.zig");
const disambiguate = @import("disambiguate.zig");
const legend = @import("../../core/renderer/legend.zig");

test "showLegend: writes Command: with Fill Clear Quit" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, io) });

    const cmds = legend.Legend{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .menu = true,
        .save = false,
        .open = false,
        .new = false,
        .save_as = false,
    };
    try renderer.showLegend(cmds);

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "  Command:") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(F)ill") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(C)lear") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(Q)uit") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(M)enu") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "(S)ave") == null);
}

test "reportGenProgress: writes formatted line to session writer" {
    const io = std.testing.io;
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, io) });

    try renderer.reportGenProgress(.{ .attempt = .{ .n = 2, .max = 256 } });

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "Generating: try 2/256") != null);
}

test "render: renders empty board end-to-end" {
    const io = std.testing.io;

    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, io) });

    const b = board.Board.init();
    try renderer.render(b.asView(), null, null);

    const contents = aw.writer.buffered();

    try std.testing.expectEqualStrings(
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
        contents,
    );
}

test "render: renders with digits placed" {
    const io = std.testing.io;

    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    var renderer = AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, &aw.writer, &s, .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, io) });

    const givens_row = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 3, 0, 0, 0, 1, 0,
        0, 9, 8, 0, 2, 7, 0, 6, 0,
    };
    var rest: [54]u8 = undefined;
    @memset(&rest, 0);

    var flat: [81]u8 = undefined;
    @memcpy(flat[0..27], &givens_row);
    @memcpy(flat[27..], &rest);

    const b = try board.fromFlat(flat, .{});
    try renderer.render(b.asView(), null, null);

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "9") != null);
}

test "showError: reads from MockSource and does not panic" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // MockSource provides a canned "Enter" press so showError doesn't hang.
    const responses = [_][]const u8{"\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    try renderer.showError("something went wrong");

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "something went wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") != null);
}

/// Renderer over scripted input lines, writing into `aw`.
fn scriptedRenderer(aw: *Io.Writer.Allocating, s: *styler.PlainStyler, responses: []const []const u8) AsciiRenderer(styler.PlainStyler) {
    const source: input_source.ReaderSource = .{ .mock = input_source.MockSource.init(std.testing.allocator, responses) };
    return AsciiRenderer(styler.PlainStyler).init(std.testing.allocator, &aw.writer, s, source);
}

test "saveAsDialog: empty input leaves the name to core" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    var renderer = scriptedRenderer(&aw, &s, &.{"\n"});
    try std.testing.expect((try renderer.saveAsDialog()) == null);
    try std.testing.expectEqualStrings(SAVE_AS_PROMPT, aw.writer.buffered());
}

test "saveAsDialog: custom input returns user filename" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    var renderer = scriptedRenderer(&aw, &s, &.{"my_puzzle.sud\n"});
    const name = (try renderer.saveAsDialog()).?;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("my_puzzle.sud", name);
}

test "saveAsDialog: EOF is an input failure" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    var renderer = scriptedRenderer(&aw, &s, &.{});
    try std.testing.expectError(facade.Error.System, renderer.saveAsDialog());
}

test "openDialog: user enters a file path" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"my_save.sud\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.pathDialog("Open file: ");

    switch (result) {
        .FileName => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expectEqualStrings("my_save.sud", path);
        },
        .Cancelled => {
            try std.testing.expect(false);
        },
    }

    const contents = aw.writer.buffered();
    try std.testing.expectEqualStrings("Open file: ", contents);
}

test "openDialog: EOF returns Cancelled" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &[0][]const u8{}),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.pathDialog("Open file: ");
    switch (result) {
        .Cancelled => try std.testing.expect(true),
        .FileName => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expect(false);
        },
    }
}

test "openDialog: empty input returns Cancelled" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.pathDialog("Open file: ");
    switch (result) {
        .Cancelled => try std.testing.expect(true),
        .FileName => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expect(false);
        },
    }
}

test "getCommandInput: New opens the difficulty dialog; the pick rides the command" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "m\n", "5\n", "1\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );
    const avail = legend.Legend{
        .fill = false,
        .clear = false,
        .quit = true,
        .undo = false,
        .redo = false,
        .menu = true,
        .save = false,
        .open = false,
        .new = true,
        .save_as = false,
    };
    var names: [7][]const u8 = undefined;
    const count = avail.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| {
            switch (cmd) {
                .new => |data| {
                    try std.testing.expect(data.puzzle == null);
                    try std.testing.expectEqual(Difficulty.easy, data.difficulty.?);
                },
                else => return error.TestFailed,
            }
        },
        .error_msg => return error.TestFailed,
    }
    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, "1) Easy") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "2) Medium") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "3) Hard") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Open From File") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Load From URL") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Paste Puzzle String") == null);
}

test "getCommandInput: New dialog rejects retired pick slots beyond the three difficulties" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    // Difficulty dialog only accepts 1-3; an invalid difficulty choice must be rejected.
    const responses = [_][]const u8{ "m\n", "5\n", "4\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );
    const avail = legend.Legend{
        .fill = false,
        .clear = false,
        .quit = true,
        .undo = false,
        .redo = false,
        .menu = true,
        .save = false,
        .open = false,
        .new = true,
        .save_as = false,
    };
    var names: [7][]const u8 = undefined;
    const count = avail.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);
    // The rejected pick cancels New quietly; the prompt reads again and the input has ended.
    try std.testing.expect(result == .valid and result.valid == .quit);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "cancelled") == null);
}

test "getCommandInput: fill A1 5 returns valid Fill" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"fill A1 5\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const avail = legend.Legend{
        .fill = true,
        .clear = true,
        .quit = true,
        .undo = false,
        .redo = false,
        .menu = true,
        .save = true,
        .open = true,
        .new = true,
        .save_as = true,
    };

    var names: [7][]const u8 = undefined;
    const count = avail.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);

    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "fill");
            try std.testing.expectEqual(@as(u4, 0), cmd.fill.row);
            try std.testing.expectEqual(@as(u4, 0), cmd.fill.col);
            try std.testing.expectEqual(cell.CellValue.five, cmd.fill.digit);
        },
        .error_msg => |msg| {
            try std.testing.expect(std.ascii.eqlIgnoreCase(msg, "")); // should not be an error
        },
    }
}

test "getCommandInput: EOF returns Quit" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    // Empty mock responses list triggers ReadEOF
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &[0][]const u8{}),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const avail = legend.Legend{
        .fill = true,
        .clear = false,
        .quit = true,
        .undo = false,
        .redo = false,
        .menu = false,
        .save = false,
        .open = false,
        .new = false,
        .save_as = false,
    };

    var names: [7][]const u8 = undefined;
    const count = avail.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);

    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "quit");
        },
        .error_msg => {
            try std.testing.expect(false); // should map to quit, not an error
        },
    }
}
const save_legend = legend.Legend{
    .fill = true,
    .clear = true,
    .quit = true,
    .undo = false,
    .redo = false,
    .menu = true,
    .save = true,
    .open = true,
    .new = true,
    .save_as = true,
};

test "getCommandInput: save never prompts; core names the target" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    var renderer = scriptedRenderer(&aw, &s, &.{ "m\n", "1\n", "m\n", "1\n" });
    defer renderer.deinit();
    var names: [7][]const u8 = undefined;
    const count = save_legend.getNames(&names);
    for (0..2) |_| {
        const result = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);
        try std.testing.expect(result.valid.save.path == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), SAVE_AS_PROMPT) == null);
}

test "getCommandInput: save as carries the typed path, or none for core's suggestion" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    var renderer = scriptedRenderer(&aw, &s, &.{ "m\n", "6\n", "mine.sud\n", "m\n", "6\n", "\n" });
    defer renderer.deinit();
    var names: [7][]const u8 = undefined;
    const count = save_legend.getNames(&names);
    const typed = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);
    try std.testing.expectEqualStrings("mine.sud", typed.valid.save_as.path.?);
    const suggested = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);
    try std.testing.expect(suggested.valid.save_as.path == null);
}

test "getCommandInput: open carries the typed path" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    var renderer = scriptedRenderer(&aw, &s, &.{ "m\n", "2\n", "game.sud\n" });
    defer renderer.deinit();
    var names: [7][]const u8 = undefined;
    const count = save_legend.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);
    try std.testing.expectEqualStrings("game.sud", result.valid.open.path.?);
}

test "getCommandInput: paste carries the typed puzzle line" {
    const line = "003020600900305001001806400008102900700000008006708200002609500800203009005010300";
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var s = styler.PlainStyler{};
    var renderer = scriptedRenderer(&aw, &s, &.{ "m\n", "13\n", line ++ "\n" });
    defer renderer.deinit();
    var names: [7][]const u8 = undefined;
    const count = save_legend.getNames(&names);
    const result = try renderer.getCommandInput(names[0..count], false, false, .easy, .info, .dark, false, false, false, null);
    try std.testing.expectEqualStrings(line, result.valid.paste.line.?);
}

test "showAbout: writes name version commit build date and licence" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    try renderer.showAbout();

    const contents = aw.writer.buffered();
    const info = about.get(build_info.debug_build);
    try std.testing.expect(std.mem.indexOf(u8, contents, info.name) != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, info.version) != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, info.commit) != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, info.build_date) != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, info.licence) != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Press Enter to continue...") != null);
}

test "showMenu: quit pick returns quit command" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"10\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| try std.testing.expectEqualStrings(@tagName(cmd), "quit"),
        .error_msg => try std.testing.expect(false),
    }
}

test "showMenu: paste pick returns paste command with null line" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"13\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "paste");
            try std.testing.expect(cmd.paste.line == null);
        },
        .error_msg => try std.testing.expect(false),
    }
}

test "showMenu: copy pick returns copy command" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"12\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| try std.testing.expectEqualStrings(@tagName(cmd), "copy"),
        .error_msg => try std.testing.expect(false),
    }
}

test "showMenu: import pick returns import command with null path" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"3\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "import");
            try std.testing.expect(cmd.import.path == null);
        },
        .error_msg => try std.testing.expect(false),
    }
}
test "showMenu: solve pick is ignored when unavailable" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "11\n", "10\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| try std.testing.expectEqualStrings(@tagName(cmd), "quit"),
        .error_msg => try std.testing.expect(false),
    }
    const written = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "11) Solve (unavailable)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "invalid menu choice") == null);
}

test "showMenu: solve pick returns solve when available" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"11\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );
    renderer.can_solve = true;

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| try std.testing.expectEqualStrings(@tagName(cmd), "solve_for_me"),
        .error_msg => try std.testing.expect(false),
    }
}

test "showMenu: q pick returns quit command" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"q\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| try std.testing.expectEqualStrings(@tagName(cmd), "quit"),
        .error_msg => try std.testing.expect(false),
    }
}

test "showMenu: invalid pick re-shows menu until valid choice" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "x\n", "\n", "10\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| try std.testing.expectEqualStrings(@tagName(cmd), "quit"),
        .error_msg => try std.testing.expect(false),
    }

    const contents = aw.writer.buffered();
    const menu_count = std.mem.count(u8, contents, "Menu:\n");
    try std.testing.expectEqual(@as(usize, 2), menu_count);
    try std.testing.expect(std.mem.indexOf(u8, contents, "invalid menu choice") != null);
}

test "showMenu: hint pick returns engine-pick when no target cell" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"8\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "hint");
            try std.testing.expect(cmd.hint.row == null and cmd.hint.col == null);
        },
        .error_msg => try std.testing.expect(false),
    }
    const written = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Hint (not yet)") == null);
}

test "showMenu: hint pick uses last cell for targeted hint" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"8\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const target: facade.Selection = .{ .row = 2, .col = 4 };
    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, target);
    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "hint");
            try std.testing.expectEqual(@as(?u4, 2), cmd.hint.row);
            try std.testing.expectEqual(@as(?u4, 4), cmd.hint.col);
        },
        .error_msg => try std.testing.expect(false),
    }
}

test "showMenu: region pick is toggle_region" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{"7\n"};
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "toggle_region");
        },
        .error_msg => try std.testing.expect(false),
    }
}

test "showMenu: settings toggles solvability warnings" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.PlainStyler{};
    const responses = [_][]const u8{ "14\n", "1\n" };
    const source: input_source.ReaderSource = .{
        .mock = input_source.MockSource.init(std.testing.allocator, &responses),
    };
    var renderer = AsciiRenderer(styler.PlainStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        source,
    );

    const result = try renderer.showMenu(false, false, .easy, .info, .dark, false, false, false, null);
    switch (result) {
        .valid => |cmd| {
            try std.testing.expectEqualStrings(@tagName(cmd), "toggle_warn_solvability");
        },
        .error_msg => try std.testing.expect(false),
    }
}

const region_on = "\x1b[48;5;238m";

test "render: no region shading when selection is null" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.AnsiStyler{};
    var renderer = AsciiRenderer(styler.AnsiStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, std.testing.io) },
    );

    const b = board.Board.init();
    try renderer.render(b.asView(), null, null);

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, region_on) == null);
}

test "render: region shading when selection provided" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var s = styler.AnsiStyler{};
    var renderer = AsciiRenderer(styler.AnsiStyler).init(
        std.testing.allocator,
        &aw.writer,
        &s,
        .{ .stdin = input_source.StdinSource.initStdin(std.testing.allocator, std.testing.io) },
    );

    const b = board.Board.init();
    try renderer.render(b.asView(), null, .{ .row = 4, .col = 4 });

    const contents = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, contents, region_on) != null);
}

test "renderer prompt messages read as sentences" {
    const sentence = @import("../../test/sentence.zig");
    try sentence.expectSentence(NO_COMMANDS_MSG);
}
