triage: ready-for-human

Facade factory per renderer — move allocation into AsciiRendererAlloc, return only Facade from buildFacade

## Problem

Issue 44 fixed the leak but introduced a coupling problem: `buildFacade` returns `(facade.Facade, *AsciiRendererAlloc)`. The concrete Alloc type leaks through to `Sudoku`, which stores it as a typed sidecar field. Adding a second renderer (TuiRenderer, WasmRenderer) would require expanding Sudoku with a union of Alloc types — breaking the very thing Facades are supposed to isolate.

**Current shape:**
```
sudoku.zig::buildFacade returns (Facade, *AsciiRendererAlloc)
Sudoku stores both facade + typed sidecar pointer
deinit calls renderer.deinit() + alloc.deinit() + allocator.destroy(alloc)
```

**Why it breaks with more renderers:** Every new renderer adds another Alloc variant to a union on Sudoku. The Facade was supposed to make Sudoku blind to concrete types — but we put the concrete type back in.

## File plan

| New item | File | Replaces / relates to |
|----------|------|-----------------------|
| `ProdFacadeContext` struct + `freeAll()` | `src/renderer/ascii_renderer_alloc.zig` (existing) | replaces current `ProdHandles` |
| `MockFacadeContext` struct + `freeAll()` | `src/renderer/ascii_renderer_alloc.zig` (existing) | replaces current `MockHandles` |
| `makeFacade(is, alloc, io)` static factory | `src/renderer/ascii_renderer_alloc.zig` (existing) | allocation block currently in `sudoku.zig::buildFacade` lines 32-89 |
| Delegate buildFacade body | `src/sudoku.zig` (existing) | `FacadeResult` struct + renderer_alloc field removed from Sudoku |

Unchanged files: `facade.zig`, all other modules.

## Design: Self-contained factory per renderer, context-driven deinit through vtable

### 1. Allocation, context structs → `src/renderer/ascii_renderer_alloc.zig`

Move all three-pointer allocation out of `sudoku.zig/buildFacade`. This file gets new items:

- **`ProdFacadeContext`** — struct holding allocator, `*std.Io.File.Writer`, `*styler.AnsiStyler`, `*AsciiRenderer(AnsiStyler)`; includes `freeAll()` that destroys all three child pointers then destroys itself. Replaces current `ProdHandles`.
- **`MockFacadeContext`** — struct holding allocator, `*std.Io.Writer.Allocating`, `*styler.PlainStyler`, `*AsciiRenderer(PlainStyler)`; includes `freeAll()`. Replaces current `MockHandles`. Both need `.deinit()` on the Allocating writer before destroy.
- **`makeFacade(is, alloc, io) Error!facade.Facade`** — static factory: reads `is` to pick prod or mock branch. Allocates all child pointers, initialises the renderer, allocates the context struct, passes `*Context` to `Make(*Context).make()`. Returns only `facade.Facade`.

The context's `freeAll()` method is wired as the vtable `deinit_fn` callback — so `Facade.deinit()` routes through opaque back to the concrete context and tears everything down.

### 2. Thin delegate → `src/sudoku.zig`

Existing `buildFacade` replaced:

```zig
fn buildFacade(cfg: config.Config, is: input_source.ReaderSource, io: std.Io) Error!facade.Facade {
    switch (cfg.preferred_renderer) {
        .ansi => return try AsciiRendererAlloc.makeFacade(is, alloc, io),
        else => return error.System,
    }
}
```

Changes in this file:
- `FacadeResult` struct removed
- `renderer_alloc` field removed from `Sudoku` struct
- `AsciiRendererAlloc` import kept (used by buildFacade delegate call)
- `deinit()` calls only `self.renderer.deinit()` + `self.engine.deinit()`

### 3. deinit cascades through vtable only

`Sudoku.deinit()` is two lines:

```zig
pub fn deinit(self: *@This()) void {
    self.renderer.deinit(); // routes Facade vtable → Context.freeAll()
    self.engine.deinit();
}
```

### 4. Scaling to future renderers

TuiRenderer defines `TuiFacadeContext` + its own alloc module with `makeFacade()`. WasmRenderer does the same. `Sudoku` struct and deinit never change — only new `.ansi => ...` lines appear in the buildFacade switch.

## Steps

| Step | Description | Status |
|------|-------------|--------|
| 1 | Define `ProdFacadeContext` / `MockFacadeContext` structs with `freeAll()` in `ascii_renderer_alloc.zig`; remove old `ProdHandles`/`MockHandles` union + tag enum | DONE — structs written, test passes (SafeAllocator check). Old types retained until Steps 2-5 replace allocation path so sudoku.zig stops importing them |
| 2 | Write `makeFacade(is, alloc, io)` static factory in `ascii_renderer_alloc.zig` — allocates all three, wires into Make with context pointer as opaque handle | COMPLETED 2026-08-13 |
| 3 | Wire `freeAll()` as the vtable's deinit callback (replaces current deinit that only frees the renderer) | COMPLETED 2026-08-13 |
| 4 | Replace `buildFacade` body in `src/sudoku.zig` with delegate to `AsciiRendererAlloc.makeFacade(...)` | DONE 2026-08-13 — return type changed to `facade.Facade`, delegates via switch on `cfg.preferred_renderer` (Step 5 completed alongside as compile-required) |
| 5 | Remove `renderer_alloc` sidecar field from `Sudoku`; tighten deinit to two calls. Remove `FacadeResult` struct | DONE 2026-08-13 — completed alongside Step 4 as compile-required: FacadeResult removed, renderer_alloc field removed, deinit is `renderer.deinit()` + `engine.deinit()` only |
| 6 | Full test suite under SafeAllocator — zero leaks, all tests pass | DONE 2026-08-13 — `renderer.deinit()` was dropped during refactor; restored in both Prod and Mock context freeAll. Test updated to init renderer pointers properly.

## Acceptance Criteria

- [x] `Sudoku` struct has no renderer-typed fields beyond `renderer: facade.Facade`
- [x] `buildFacade` returns only `facade.Facade` (one return value) — no tuples, no opaque sidecars
- [x] AsciiRendererAlloc factory creates all allocations and wires the vtable deinit to free them
- [x] Adding TuiRenderer/WasmRenderer would only require: (a) new alloc module, (b) one line in buildFacade switch — zero changes to Sudoku struct or deinit
- [x] Full suite under SafeAllocator — zero leaks


