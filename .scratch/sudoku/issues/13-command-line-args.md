/** Origin: Phase-based issue rewritten after triage — removed self-blocking phase structure */

Triage date: 2025-07-23

Triage notes:
- Logger module is done (five severity methods shipped, co-located tests in logger.zig)
- Config struct exists with difficulty/preferred_renderer/fallback_renderer fields and `default()`
- CLI argument parsing is absent — main.zig calls `Config.default()`; no flag support yet

## Goal

Add CLI argument parsing so users control difficulty, log level, and help output from the command line. Config module owns arg parsing and exposes a typed struct to the wiring layer. When flags are omitted, Config preserves its existing defaults — arguments overlay rather than replace.

---

## Context

`main()` currently calls `Config.default()` — every run uses easy difficulty and info-level logging regardless of how the program was invoked. Logger is shipped (debug/info/warn/err/fatal). Config struct is shaped but doesn't parse args yet — stdlib `std.process.ArgIterator` (via `init.args`) provides the argument stream; nothing consumes it.

---

## Steps (each builds on previous, each is a vertical slice)

### Step 1: Add `-d <difficulty>` flag parsing to Config

**File**: `src/config.zig`

- Start from `Config.default()` values and overlay only the fields whose flags were provided 
- Parse `-d` / `--difficulty` for values: `easy`, `medium`, `hard`; absent leaves difficulty at `.easy`
- Invalid difficulty value emits error via Logger and exits non-zero

### Step 2: Add log-level flag `-v <level>` to Config

**File**: `src/config.zig`

- Parse `-v` / `--log-level` for values matching Logger severity enum 
- Only overlays the log-level field; all other defaults (difficulty, renderer) stay intact when absent
- Default log level remains info-equivalent unless explicitly changed  
- Add log level field to Config struct (e.g. `log_level: LogLevel`)

### Step 3: Add `-h` / `--help` usage summary

**File**: `src/config.zig`

- Emit concise usage summary listing supported flags and their valid values
- Exit cleanly with code 0
- Route output through Logger

### Step 4: Wire Config.init into main

**Files**: `src/main.zig`, `src/root.zig` 

- Replace `Config.default()` call in main with `Config.init(init.args)` 
- Verify via `zig build run -d medium` launches with medium puzzle
- Add test covering parsed config values reach main as expected

---

## Acceptance Criteria

- [ ] `zig build run -d medium` launches with a medium-difficulty generated puzzle
- [ ] `zig build run` (no arguments) preserves all current defaults from Config.default()
- [ ] Individual flags overlay defaults without overwriting untouched fields
- [ ] `-v <log_level>` controls which severity messages get emitted
- [ ] Invalid flags or values produce diagnostic output via Logger, then exit non-zero
- [ ] `-h` / `--help` prints concise usage summary and exits cleanly (0)

---

## Blocked by

(none — Logger is shipped; Config struct exists; arg iterator available via `init.args`)
