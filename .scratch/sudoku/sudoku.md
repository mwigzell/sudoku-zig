# Sudoku (Zig) — architecture and refactor plan

Design notes for the Sudoku app on **confucius** (`/home/mark/Dev/src/sudoku`). Captures agreed patterns from architecture review (Jul 2026). Use this when working with Pi or Cursor on the project.

**Stack:** Zig latest (`/home/mark/.local/tools/zig-latest/`), 0.16+ `std.Io`. Dev agent: Pi + local Qwen on confucius. See also [llm.md](./llm.md).

---

## Goals

- **Iterative vertical slices:** end-to-end thin path first, then flesh out slice by slice.
- **Front-end independence:** game logic must not depend on ASCII, TUI, or WASM.
- **Testable render path:** no stdout/TTY assumptions in unit tests.
- **Simple domain model:** one grid, one cell type, borrowed views for read paths.

---

## Layer diagram (target)

```
main
 └── GameEngine          owns Board, orchestrates input + render
      ├── Board            [81]CellState, mutation, constraint caches
      │    └── BoardView    borrowed read lens (not owned)
      └── Renderer          thin interface: draw(BoardView)
           ├── AsciiRenderer   Writer → text grid (first slice)
           ├── TuiRenderer     ncurses (later)
           └── WasmRenderer    HTML/DOM (later)
```

**Dependency rule:** `Board` never imports renderers. `GameEngine → Board`, `GameEngine → Renderer` only.

---

## Current vs target (rewiring)

| Area | Current (problem) | Target |
|------|-------------------|--------|
| Grid storage | Built from `Box`-owned 3×3 matrices; no flat 81 grid | `Board` owns `[81]CellState` |
| `Grid` | Owning layer | Drop as storage; row/col/box are helpers/views |
| `Box` | Owns 3×3 cells | **View** over board region + optional digit bitmask cache |
| `RenderCell` | Separate owned struct | **Remove** — same `CellState` for domain and display |
| `RenderSnapshot` | Assembled clone from nested structures | **`BoardView`** — borrowed slice, no allocator |
| `StdoutRenderer` | Tied to stdout stream / TTY | **`AsciiRenderer`** + injected **`Writer`** |
| Box `hasValue()` | HashMap(value → Cell) considered | **9-bit digit mask per box**, updated in `setCell` |
| Renderer tests | Colocated tests hitting stdout/pipes | **`ArrayList(u8)` buffer** + string compare |

---

## Domain model

### CellState

One struct per cell on the board. Start minimal; add flags only when a vertical slice needs them.

```zig
pub const CellState = struct {
    value: u4,   // 0 = empty, 1..9 = digit
    given: bool, // true = clue, false = user entry
};
```

Optional packed form (`packed struct(u8)`) if desired — not required at 81 cells.

**Do not put in `CellState`:** cursor, selection, highlight, conflict (derive or cache later if needed).

### Board

- Owns `cells: [81]CellState`.
- Indexing: **row-major** `idx = row * 9 + col` (0..80).
- Mutation API: `setCell`, `clearCell` (names as you prefer) — **single choke point** for cache updates.
- Box digit cache: `box_digits: [9]u16` — bit `(d - 1)` set if digit `d` is present in that box.
- `hasValueInBox(box_idx, digit)` → bitmask check, O(1). Brute-force scan of 9 cells is also fine before cache exists.

### Box, row, col

**Non-owning views** — coordinates + helpers, not storage:

```zig
pub const BoxView = struct {
    board: *const Board,
    box_idx: u8, // 0..8
};
```

Free functions or small view types: `rowCells`, `colCells`, `boxCells`, `index(row, col)`, etc.

**No `HashMap(value → Cell)`** — at most 9 cells per box; a map duplicates cell ownership and adds sync cost on every write.

### BoardView

**Does not own `Board`.** Borrowed read lens for render and validation:

```zig
pub const BoardView = struct {
    cells: []const CellState, // len 81, borrowed

    pub fn from(board: *const Board) BoardView {
        return .{ .cells = board.cells[0..] };
    }
};
```

**When to copy:** only for undo stacks, async render, or immutable wire payloads — use a separate owned type (e.g. `BoardSnapshot { cells: [81]CellState }`), not `BoardView`.

### Render migration

```zig
// before
const snapshot = try board.buildRenderSnapshot(allocator);
try renderer.draw(snapshot);
snapshot.deinit(allocator);

// after
try renderer.draw(board.view());
```

---

## Rendering

### Renderer interface (keep)

Thin trait already in place — keep it. Contract:

```zig
draw(view: BoardView) !void
```

No snapshot assembly, no `RenderCell`, no stdout in the interface.

### AsciiRenderer (first backend)

- **Name:** `AsciiRenderer` (or `TextRenderer`) — describes **format**, not destination.
- **Output:** injected `Writer`, not “stdout” as a concept.
- **Production:** `main` wires stderr or file writer; behavior can match today’s visible output.
- **Tests:** write to `ArrayList(u8)`, assert exact string.

```zig
test "ascii renderer empty board" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    // var w = buf.writer(...);  // std.Io 0.16 pattern
    var renderer = AsciiRenderer.init(&w);
    try renderer.draw(empty_board.view());
    try std.testing.expectEqualStrings(expected, buf.items);
}
```

**Do not** unit-test renderers against stdout, pipes, or TTY/server mode — that tests the harness, not the formatter.

### Backend order

1. **AsciiRenderer** + `Writer` (current slice, re-architected)
2. **TuiRenderer** (ncurses — different output model entirely)
3. **WasmRenderer** (same `BoardView`, different sink)

WASM does **not** require a separate domain cell type — only a different encoding of the same 81 values.

---

## Logging

Thin wrapper around **`std.log.scoped(...)`** (levels + scopes delegated to std):

- Optional `@src()` at call site (pass explicitly or via `inline` forward — `@src()` inside wrapper body reports wrapper file, not caller)
- Optional timestamp formatting
- **Never** used for user-visible grid output

| Channel | Use |
|---------|-----|
| `std.log` / wrapper | Diagnostics (solver, generator, errors) |
| `Renderer → Writer` | Grid and user-facing text |

Accept the `(fmt, .{})` tuple for parameterized log lines — no separate `mylogger.zig` module unless requirements outgrow std.

---

## Testing strategy

| Layer | What | How |
|-------|------|-----|
| **Board** | index math, set/get, box bitmask, constraints | Plain `test` blocks, no I/O — **write these first** |
| **AsciiRenderer** | exact grid formatting | Buffer-backed `Writer`, string compare |
| **GameEngine** | orchestration | Later; fake renderer or capture buffer |
| **Integration** | `main` smoke | Manual or one smoke test; not colocated with unit tests |

---

## Refactor order (inside-out, stay green)

Keep `zig build` + visible ASCII board working after each step.

1. **`Board` + `[81]CellState`** — new storage; board unit tests
2. **Box digit bitmasks** — update in `setCell` / `clearCell`
3. **`BoardView`** — replace `RenderSnapshot` assembly
4. **`StdoutRenderer` → `AsciiRenderer`** — inject `Writer`; wire stderr in `main` (same visual output)
5. **Renderer tests** — switch to buffer; remove stdout/TTY assumptions
6. **Delete** — `RenderCell`, snapshot builder, `Grid` as storage, old Box-owned matrices

Do **not** block the refactor on ncurses or WASM.

---

## Agent rules (Pi / Cursor)

Copy **`docs/sudoku-AGENTS.md`** → `/home/mark/Dev/src/sudoku/AGENTS.md` on confucius. That file is the concise rule set for agents; this doc is the full architecture reference.

---

## Project paths (confucius)

| Item | Path |
|------|------|
| Repo | `/home/mark/Dev/src/sudoku` |
| Zig | `/home/mark/.local/tools/zig-latest/` |
| Debug | OSS Code + CodeLLDB, `.vscode/launch.json` + `tasks.json` |
| Pi | launch from project cwd; guardrails enabled |

---

## Decision log

| Date | Decision |
|------|----------|
| 2026-07-16 | Flat `[81]CellState` on `Board`; Box/row/col as views |
| 2026-07-16 | Drop `RenderCell`; `RenderSnapshot` → borrowed `BoardView` |
| 2026-07-16 | Box fast lookup via 9-bit digit masks, not hash map |
| 2026-07-16 | Keep thin `Renderer`; `AsciiRenderer` + injected `Writer` |
| 2026-07-16 | Board tests before renderer rewire; buffer-backed render tests |
| 2026-07-16 | Logging: thin std.log wrapper; grid only via Renderer |
