Status: needs-triage
Blocked By: Issue 15 — Board topology refactor (ADR-0006)

## Parent

`.scratch/sudoku/prd.md`

## What to build

Replace `main.zig`'s hard-wired adapter choices with proper command-line argument parsing, a dedicated Config seam, and a Logging subsystem that routes all diagnostics. Currently every invocation loads easy via StdoutRenderer regardless of how the program was invoked; all real-world configuration decisions are baked into code rather than being pluggable.

### Vision (target architecture)

`main()` should be a thin wire job that:
- Accepts only `std.process.Init` as argument
- Delegates external environment / parsed CLI flags to a dedicated **Config module**
- Wires the real-world deps into GameEngine once configuration has been resolved  
- Does *not* embed business logic, rendering logic, puzzle loading, or stdout/stderr prints itself

The "splash" phase is: parse args → produce `ProgramConfig` struct → pass that to whatever wiring layer follows. The "big time" architecture will add more behind the config seam (renderer pool registration, logging initialization, event loop setup) but main()'s shape already needs to be set right.

### Concretely (phase 1 — splash + config boundary)

- Create `src/config.zig` with a `Config.init(args)` method that returns a typed struct containing:
  - Selected `Difficulty` enum  
  - Selected frontend string name (`"stdout"`, `"tui"`, future `"wasm"`)  
  - Verbosity/debug logging level  
- Supported flags parsed by Config:
  - `-d <difficulty>` → values: `easy` (default), `medium`, `hard`. Invalid value emits via Log and exits non-zero.
  - `-f <frontend>` → values as above, invalid name prints an available-hint via Log and exits non-zero.  
  - `-h` / `--help` → prints concise usage summary to Log and exits cleanly (0).
- Difficulty & frontend are independent axes on CLI (you can pick any combo).

### Concretely (phase 2 — logging subsystem)

- All program output and error messages route through a **Log** subsystem. Stdout/stderr are *not* dumped directly; they emit via the Log adapter.  
- Severity levels from highest to lowest: `fatal`, `error`, `warning`, `info`, `debug/verbose`.
- Verbosity flag `-v <verbosity>` controls threshold only (if set to debug, all show; if error, only fatal+error show). Default is info unless explicitly changed.
- Stderr output *should* probably go through the log adapter rather than bypassing it entirely so diagnostics stay consistent when file or rotating logs land later.

### Concretely (phase 3 — frontend splash & event coordination)

- Add a **splash slot** to renderers: a lightweight first-render hook that emits immediately after GameEngine wires up but before the command/event loop begins processing user moves.
- Coordination point established between `main()` and GameEngine for the command/event loop so main stays thin instead of accumulating boilerplate as features land.

## Acceptance criteria

### Phase 1 (mandatory)
- [ ] Config module parses difficulty and frontend flags into a typed struct  
- [ ] `zig build run -d medium` launches with a medium-difficulty generated puzzle
- [ ] `-f stdout` selects StdoutRenderer explicitly; unknown frontends emit a hint via Log
- [ ] `zig build run` (no arguments) still defaults to easy + stdout  
- [ ] `-h` / `--help` prints concise usage summary and exits cleanly  
- [ ] Invalid flags or mismatched values produce diagnostic output via logging, then exit non-zero  

### Phase 2 (logging subsystem)
- [ ] Fatal/Error/Warning/Info/Debug logging hierarchy implemented behind a single Log seam  
- [ ] Verbosity flag `-v <verbose_level>` gates what gets emitted based on threshold  
- [ ] No direct `std.debug.print` or raw stdout/error writes live outside the Log adapter (including main.zig)  

### Phase 3 (frontend splash + event coordination)
- [ ] Splash hook emits immediately after GameEngine wiring, before command/event loop starts processing input
- [ ] Command/event loop responsibility cleanly assigned and documented so future features don't leak into `main()` 

## Blocked by

Phase 1: Nothing. Pulls args from `std.process.Init.minimal.args`, which is already available through `main(init: std.process.Init)`. I/O routing handled via IoSink.  
Phase 2: Independent of external deps; self-contained logging module creation.  
Phase 3: TUI renderer (issue 10) + event loop design work.
