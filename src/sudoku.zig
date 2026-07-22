const std = @import("std");
const game_engine = @import("game_engine.zig");
const config = @import("config.zig");
const puzzle_gen = @import("puzzle_gen.zig");
const command = @import("command.zig");

pub fn Sudoku(comptime R: type) type {
    return struct {
        engine: game_engine.GameEngine(R),
        cfg: config.Config,

        pub fn init(cfg: config.Config, r: *R) anyerror!@This() {
            const puzzle_str = puzzle_gen.PuzzleGen.generate(cfg.difficulty);
            const engine = try game_engine.GameEngine(R).init(puzzle_str, r);
            return .{
                .engine = engine,
                .cfg = cfg,
            };
        }

        fn readLine(reader: anytype) anyerror![]const u8 {
            return try reader.takeDelimiter('\n') orelse return error.ReadEOF;
        }

        /// Show an error message and wait for Enter to continue.
        fn waitAck(self: *@This(), writer: anytype, reader: anytype, msg: []const u8) anyerror!void {
            _ = self;
            try writer.print("{s}\n", .{msg});
            try writer.print("Press Enter to continue... ", .{});

            _ = try readLine(reader);
        }

        /// R → P → L → Pr → Sw → E command loop.
        pub fn run(self: *@This(), io: std.Io) anyerror!void {
            var stdout_writer = std.Io.File.stdout().writer(io, &.{});
            const out = &stdout_writer.interface;
            var stdin_buf: [1024]u8 = undefined;
            var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);

            const in_ = &stdin_reader.interface;

            // R — initial render
            try self.engine.render();

            while (true) {
                // P — prompt
                try out.print("> ", .{});

                // L — read line from stdin
                const line = try readLine(in_);
                if (line.len == 0) continue;

                // Pr — parse line
                const tokens = std.mem.trim(u8, line, &std.ascii.whitespace);
                const result = command.parse(tokens);

                // Sw — switch on parse outcome
                switch (result) {
                    .error_msg => |msg| {
                        try self.waitAck(out, in_, msg);
                        continue;
                    },
                    .valid => |cmd| {
                        if (cmd == .quit) return; // quit detected at command level

                        const exec_result = try self.engine.exec(cmd);
                        switch (exec_result) {
                            .ok => {},
                            .error_msg => |msg| {
                                try self.waitAck(out, in_, msg);
                                continue;
                            },
                        }
                    },
                }

                // R — re-render at start of next iteration (top of while)
            }
        }
    };
}

const mock_renderer = @import("mock_renderer.zig");
const board = @import("board.zig");
const cell = @import("cell.zig");

test "Sudoku.init uses config difficulty to build the board" {
    const cfg: config.Config = .{
        .difficulty = .hard,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };
    var mock = mock_renderer.MockRenderer.init();
    var sudoku = try Sudoku(mock_renderer.MockRenderer).init(cfg, &mock);

    // The hard puzzle has different given cells than the default puzzle.
    // For example, hard[0] is '0' (empty) whereas default[0] is '6'.
    // If init used PuzzleGen.default() instead of cfg.difficulty, cell (0,0) would be six.
    try std.testing.expect(!sudoku.engine.board.isGiven(0, 0));
}

test "Sudoku.init with .medium difficulty loads medium puzzle" {
    const cfg: config.Config = .{
        .difficulty = .medium,
        .preferred_renderer = .ascii_ansi,
        .fallback_renderer = .ascii_ansi,
    };
    var mock = mock_renderer.MockRenderer.init();
    var sudoku = try Sudoku(mock_renderer.MockRenderer).init(cfg, &mock);

    // medium[0] is '8' (given) — hard and easy both have '0' here.
    try std.testing.expect(sudoku.engine.board.isGiven(0, 0));
}
