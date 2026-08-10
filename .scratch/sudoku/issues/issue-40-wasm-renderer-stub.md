triage: ready-for-human

## Working mode

Feature — stub WasmRenderer proving multi-renderer capability. Requires build system changes for command-line routing and WASM target compilation.

## Context

The TUI only renderer works. A stub WasmRenderer (hardcoded responses) will:
- Prove the Facade vtable supports two concrete renderers
- Force `command/parse.zig` type leakage into visibility (WASM imports types, drags in ASCII parsing it never uses → Issue 39)
- Begin WASM build tooling (zig cc, wasm32 target, JS glue code)
- Require CLI routing (`--tui` vs `--wasm`) to select renderer at startup

## Steps

### Step 1: Add command-line flag for renderer selection
`main.zig` (or entry point) reads a CLI arg to choose between TUI and WASM modes. Default: `--tui` preserving current behaviour. The flag only affects what happens, not how the binary compiles — same executable runs both paths when compiled natively.

### Step 2: Add WASM compilation target to build.zig
Configure Zig's wasm32-freestanding cross-compilation alongside the native binary target. The WASM build produces a `.wasm` file (not an executable) that gets bundled with minimal JS glue code for browser invocation.

### Step 3: Create `src/renderer/wasm/wasm_renderer.zig`
Implement Facade vtable with hardcoded behaviour — every method returns canned values to prove the types flow correctly through the system without crashing:
- `showLegend`: prints "legend" to stdout/log
- `getCommandInput`: always returns `.fill` with coordinate A1 and value 5
- `newGameOptions`: always returns a hardcoded easy puzzle string
- `showError`: logs error message (no terminal interaction in WASM, JS side handles display)

### Step 4: Wire Facade.Make(WasmRenderer) path
Add the second Make call path so selecting `--wasm` uses WasmRenderer through the same Facade pattern. The rest of the engine — GameEngine, Board, commands — runs identically regardless of renderer choice.

### Step 5: Minimal JS glue + HTML host page
A `web/index.html` + `web/wasm.js` that loads the compiled `.wasm`, exports the game loop entry point, and renders ASCII output in terminal-like fashion (sends command strings to WASM, receives board state as JSON/ASCII to render). This is throwaway scaffolding to prove the binary works — not a proper browser rendering layer.

### Step 6: Verify both modes compile and run
`zig build run --tui` → existing TUI behaviour. New build step (e.g., `zig build wasm`) produces `.wasm` that loads in browser and shows hardcoded fill command flowing through to board state change.

## Acceptance criteria

- [ ] `--tui` / `--wasm` CLI flag routes to correct renderer path
- [ ] Native build (`zig build run --tui`) works unchanged
- [ ] WASM build compiles successfully producing `.wasm` output
- [ ] WasmRenderer stub implements all Facade vtable methods (hardcoded responses)
- [ ] WasmRenderer's `getCommandInput` returns a valid `ParseCommandResult` with hardcoded `.fill` command
- [ ] Minimal JS glue + HTML page can load the `.wasm` and show board rendering working one cycle (command → engine execution → state snapshot returned to browser render)
- [ ] Zero behavioural change to TUI path — all existing 202+ tests still pass
