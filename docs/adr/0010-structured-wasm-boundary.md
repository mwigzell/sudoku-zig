# ADR-0010 — Structured WASM boundary; engine I/O-free; JSON wire (slice B)

Status: accepted
Date: 2026-09-12
Supersedes: ADR-0004 (command strings + passive JSON snapshots over REPL)

## Context

The wasm deployment initially reused the terminal REPL: `step(line)` fed command strings, Zig rendered a full ASCII screen through `page_bytes_out`, and `showError` was supposed to block for acknowledgement. That model assumes a synchronous call stack (stdin blocking). Browser WASM runs to return on each import; it cannot suspend inside `showError` or filename dialogs and resume when the user clicks OK.

ADR-0004 chose JSON events and command strings to mirror terminal parsing. That duplicated a terminal-shaped shell in the browser and could not honour interactive message acknowledgement. Issues #24–#26 (GitHub, closed) recorded the dead end; grill-with-docs (2026-09-12) locked the replacement shape.

Native terminal play remains stack-shaped (blocking facade) for now; revisit when TuiRenderer or a Linux GUI front-end lands (ADR-0008 pattern).

## Decision

### GameEngine (portable core)

- Owns `State`, gameplay `exec` (fill, clear, undo, redo, quit), and the **SUD0 codec** (`toSaveFormat` / `loadSaveFormat` on bytes).
- **No** `FileTransport`, paths, or `std.Io`.
- Session persistence (save, open, save-as, new-from-file) is **not** in `exec`. Native `Sudoku` routes parsed session commands to `FileTransport` + codec; the web shell (JS) owns file bytes via the File System Access API.

### WASM exports (slice B)

Replace REPL imports (`page_line_in`, `page_bytes_out`, `page_picker`, `file_read`/`file_write`) with memory exports:

- `init(wire_config)` — difficulty (+ optional log level); `PuzzleGen` stays in Zig.
- `exec(action_json)` → `Event` JSON (`.ok` / `.error_msg`).
- `getLegend()` → JSON flags (separate from turn outcome).
- `getState()` or state embedded in exec response — board + given/conflict markers for DOM.
- `serialize()` / `deserialize(bytes)` — **SUD0 only**; JS reads/writes opaque files; no SaveFormat logic in JS.

Wire format for slice B: **length-prefixed or NUL-terminated JSON strings** in wasm linear memory (debuggable). Binary layouts are a later optimisation, not slice B.

### Delete from wasm path

- `WasmRenderer`, `WasmHost`, `WasmTransport`, `step(line)` command loop, ASCII screen feed.
- Keep: `wasm_bytes` embed, `-r web` static serve (`native/serve.zig`), `artifact.wasm` compile gate.

### Testing

- **Native:** existing `sudoku.zig` integrated e2e through `Sudoku` + blocking AsciiRenderer (unchanged for this slice).
- **Wasm:** rewrite `glue.test.mjs` to drive real `artifact.wasm` in node against JSON exports (no ASCII grid parsing). Browser DOM e2e remains optional (ADR-0002).

## Consequences

- ADR-0004 command-string ABI is retired; do not reintroduce terminal projection as the browser UI.
- `CONTEXT.md` and PRD WASM sections must align as code moves (incremental, not batched).
- Native session commands stay in the command parser; `Sudoku.handleResult` intercepts before `exec` (minimal parser churn).
- A future real DOM front-end (splash, modals, FS Access) is JS-owned; wasm never blocks for UI acknowledgement.
- Parity tests (shared action fixtures, compare state JSON native vs wasm) are recommended after slice B basics land.
