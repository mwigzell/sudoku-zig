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
- **Save & restore** — binary save format with versioned header/trailer, stored under the platform data directory (see below)
- **Persistent settings** — `settings.json` beside saves; native **Menu → Settings** / **Region**, web **File → Settings** and **View**, CLI flags merged at startup
- **ANSI styled** terminal renderer (styler is swappable)
- **Web UI (loopback + WASM)** — `-r web` serves embedded wasm/JS on localhost; same engine and save format as native, no separate web codebase for game logic

## CLI

```
Usage: sudoku [OPTIONS]

  -h, --help              Show this help message
  -V, --version           Show version and exit
  -r, --renderer <kind>   Choose renderer (ansi, ascii, tui, web)
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

Web UI: `zig build run -- -r web` or `zig-out/bin/sudoku -r web` (opens or logs a loopback URL).

## Settings (`settings.json`)

Nominal game preferences (difficulty, log level, theme, region shading, solvability warnings, renderer choice) are stored as JSON in the **same data directory** as native save files:

| OS | `settings.json` |
|----|-----------------|
| **macOS** | `~/Library/Application Support/sudoku/settings.json` |
| **Linux** | `~/.local/share/sudoku/settings.json` |

**Native terminal:** on startup the app loads this file, applies CLI overrides, and saves the merged result. In session, **Menu → 14) Settings** toggles solvability warnings; **Menu → 7) Region** toggles region shading — both write back to `settings.json`.

**Web (`-r web`):** the host serves `/host-config.json` from that file at startup. **File → Settings** and **View** (theme, region) POST partial updates to `/settings.json` on the host, which merges and saves to disk.

## Known to run on

Maintainer-tested native builds; **`zig build verify`** is run on the host OS listed below.

| OS | Native terminal | Default save location | `-r web` (loopback + browser) |
|----|-----------------|------------------------|-------------------------------|
| **macOS** | yes | `~/Library/Application Support/sudoku/` | yes |
| **Linux** | yes | `~/.local/share/sudoku/` | yes |
| **Windows** | not yet | — | not yet |

**Browser:** any modern desktop browser on the **same machine** as the running `sudoku` process when using `-r web` (WASM + static assets served locally).

Native **Windows** is tracked in [issue #60](https://github.com/mwigzell/sudoku-zig/issues/60) (cross-compile, paths, argv, browser open).

## Tests

```sh
zig build verify                      # release gate: tests, fmt check, standards, coverage, wasm glue tests
zig build test                        # full suite (silent = pass)
zig build test -Dtest-filter='name'   # single test
zig build cov                         # kcov coverage report
```

Tests use `std.testing.io` for in-process fake I/O — no real terminal
stdin/stdout is ever touched by the suite.

## Project layout

```
src/
├── main.zig              process entry (CLI, Host, `-r web` → serve)
├── wasm_entry.zig        wasm export table (browser build)
├── command.zig           command vocabulary + Hint/Fill payloads
├── event.zig             exec results (.ok / .error_msg)
├── solver.zig            backtracking solver (hints, generation, solve-for-me)
├── puzzle_gen.zig        live puzzle generation + difficulty
├── about.zig             Help/About metadata (native + wasm)
├── board/                cells, validation, conflicts, SUD0 serial codec
├── engine/               GameEngine.exec — fill, clear, undo/redo, hint, save format
├── renderer/             Facade vtable + legend (native presentation seam)
├── native/
│   ├── host.zig          Io session + renderer factory (ansi / ascii / web branch)
│   ├── cli.zig           --help / --version / --renderer
│   ├── serve.zig         loopback static server + browser open
│   ├── io_session.zig    stdin/stdout (prod + mock for tests)
│   ├── shell/            Sudoku app loop, save/open/import, paths, FileTransport
│   └── ascii/            terminal renderer, parser, styler, menu dialogs
└── wasm/
    ├── boundary.zig      JSON exec + snapshot encoding (ADR-0010)
    ├── wire.zig          shared wire types / cell JSON
    ├── *.js              browser shell (board, menus, file UX, help)
    └── artifacts/        emitted artifact.wasm, glue.js, page.html

docs/ — ADRs, agent/verify notes. build.zig — native exe, wasm emit, test, verify, cov.
```

## Issue tracker

Open work lives on **GitHub**: [mwigzell/sudoku-zig](https://github.com/mwigzell/sudoku-zig/issues).
See [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) for agent workflow (`gh issue list`, triage labels, close when done).

[`.scratch/sudoku/issues/closed/`](.scratch/sudoku/issues/closed/) is a **historical archive** from the early local-agent loop (README experiment record). Issue numbers there do not match GitHub IDs — code and tests are the source of truth for shipped work.
