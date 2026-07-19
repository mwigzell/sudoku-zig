Status: ready-for-agent

## Triage
Date: 2026-07-18

Blocked by issue 15, cleared (closed).

### Notes
- Scope narrow per PRD. Styler owns buffer; no cursor logic here, still pure ASCII output
- Design sketch locked after session review: Plain/Ansi impls via shared row formatting contract
- Tests cover both variants injected into AsciiRenderer (plain for bit-for-bit identity, ansi adds bold styling around given digits)

## Parent
`.scratch/sudoku/prd.md`

## Working mode
HITL. Design first; implementation after issue 15 (closed).

## What to build
Introduce a **Styler** seam so AsciiRenderer can target different *byte encodings* (plain ASCII vs ANSI decoration) without changing rendering decisions or layout logic.

Currently the renderer writes directly to an `Io.Writer` via single format string per row. To distinguish givens from player input, Styler owns per-row buffer fill: it walks board positions inside `formatRow(row_idx, view, buf) []u8`, decides whether to decorate digit runs with CSI codes around given values, and returns filled slice. Static text (borders, column header) still emits via AsciiRenderer; only data rows go through Styler.

## Shape & Contract
Plain/Styler writes unadorned layout into passed buffer — bit-for-bit identical to current AsciiRenderer output (key invariant).  
Ansi/Styler wraps decorated runs (given digits inside bold CSI codes) around styled cells. Future styling flags query BoardView/Cell inside same loop — signature stays unchanged as it is now.

```zig
pub const PlainStyler = struct { ... };
pub const AnsiStyler = struct { ... };

fn formatRow(self: *Styler, row_idx: usize, view: board.BoardView, buf: []u8) []u8;
```

## Scope (step-by-step)

**16.1 — New file `src/styler.zig`: Plain + Ansi Styler impls**  
Both structs implement shared contract:
- `formatRow(self, row_idx: usize, view: board.BoardView, buf: []u8) []u8` — non-fallible, fills buffer with layout string for that data row

Plain/Styler delegates through unchanged. Ansi/Styler queries `view.isGiven(r,c)` per cell position and wraps the digit character run in bold CSI codes when given is true.

Tests (co-located):
- *PlainStyler produces unadorned row string — assert returned slice matches current `cellRow` bufPrint output exactly*
- *AnsiStyler wraps given digits in bold CSI codes — parse filled buffer for decoration markers only around expected digit positions*

**16.2 — Modify `src/ascii_renderer.zig`: inject Styler into render path**  
AsciiRenderer init gains second param: styler pointer. Static lines still emit via AsciiRenderer; row formatting delegates through cellRow into Styler via per-call invocation like:
```zig
const line = try self.styler.formatRow(...);
```

Tests:
- All 4 existing tests remain green using Plain/Styler injected instead of raw buffer print
- New test confirms renderer delegates row layout through Styler contract

**16.3 — Modify `src/main.zig`: wire Ansi Styler in prod**  
Import styler module, create Ansi/Styler instance, pass to AsciiRenderer.init alongside stdout writer. Verified via `zig build run` visual check for ANSI bold styling around given cells in terminal output.

**16.4 — Update `src/root.zig`: add styler module import**  
Add styler import and reference inside test tuple discovery block. Imports grow from 7 to 8 modules verified through zig test src/root.zig passing across all newly discovered co-located blocks including styler tests.

## Acceptance criteria
- [x] Styler concept defined implementing shared row layout contract via formatRow method — non-fallible, fills passed buffer
- [x] Plain/Styler renders identically to unmodified AsciiRenderer output (bit-for-bit validation against current cell row string generation)
- [ ] Ansi/Styler produces bold styling only around *given* cells without distorting rendered layout spacing 
- [x] Test suite passes with both Styler variants injected alongside current renderer tests covering identical/unadorned emission

## Blocked by
(none — issue 15 closed)
