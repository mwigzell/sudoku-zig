# sudoku-zig

A classic 9×9 Sudoku game for the terminal, written in **Zig** (0.17).

© 2026 Mark Wigzell — [MIT licensed](LICENSE)
## Purpose

`sudoku-zig` exists first and foremost as a way to learn **Zig 0.17** through real work — the Sudoku is the excuse, the discipline (test-first iteration, deep modules, honest I/O seams) is the point. It is also intended to be a genuinely playable game, not a tutorial artifact.

The codebase was produced with a local AI agent in a tight loop: Pi (terminal agent harness), Qwen 27b (local LLM, single RTX 3090), Matt Pocock's workflow skills (grill-me, TDD, two-axis code review), with a human gate at every boundary. This is a deliberate experiment, not a claim: the open question is whether serious, sustainable code can be produced at this local level at all. The tickets in `.scratch/sudoku/issues/` and the test suite are the data — you are invited to check, not to be sold.

```
   A B C │ D E F │ G H I
 ╭───────┼───────┼───────╮
1│     3 │   2   │ 6     │
2│ 9     │ 3   5 │     1 │
3│     1 │ 8   6 │ 4     │
 ┼───────┼───────┼───────┼
```

(given cells render dimmed in the terminal; the interactive prompt follows the grid)

## Features

- **Full game loop** — fill, clear, undo/redo, new game, quit
- **Puzzle generation** with easy/medium/hard difficulty (cells removed by a backtracking solver)
- **Conflicts** — the board tracks and displays cell conflicts as you play
- **Command disambiguation** — type partial or prefix-matched commands (`sa` → save-as, `f` → fill)
- **Save & restore** — binary save format with versioned header/trailer, stored under `~/.local/share/sudoku`
- **ANSI styled** terminal renderer (styler is swappable)

## CLI

```
Usage: sudoku [OPTIONS]

  -h, --help              Show this help message
  -V, --version           Show version and exit
  -r, --renderer <kind>   Choose renderer (ansi, tui, wasm)
```

## Building & running

Requires **Zig 0.17** and a C library for libc linking.

```sh
zig build            # compiles to zig-out/bin/sudoku
zig-out/bin/sudoku   # interactive game
zig-out/bin/sudoku --version
```

Or run directly: `zig build run` (the 0.17 builder consumes flags after `run`,
so pass program flags via the built binary).

## Tests

```sh
zig build test                        # full suite (silent = pass)
zig build test -Dtest-filter='name'   # single test
zig build cov                         # kcov coverage report
```

Tests use `std.testing.io` for in-process fake I/O — no real terminal
stdin/stdout is ever touched by the suite.

## Project layout

```
src/
├── main.zig            entry point, IoSession wiring
├── sudoku.zig          the game: prompt → parse → exec loop
├── cli.zig             --help / --version / --renderer parsing
├── version.zig         app version (0.1.0)
├── board.zig / board/  domain: cells, conflicts, validation
├── engine/             mutations (fill, clear, undo/redo), new game, save/open
├── renderer/           facade + AsciiRenderer (ANSI styler, command parsing)
├── puzzle_gen.zig      difficulty-based puzzle generation
└── io_session.zig      stdin/stdout source union (prod + mock)
```

## Issue tracker

Local markdown issues live in [`.scratch/sudoku/issues/`](.scratch/sudoku/issues/),
one file per ticket with `triage:` and `status:` in the header. Closed issues
are archived under `.scratch/sudoku/issues/closed/`.
