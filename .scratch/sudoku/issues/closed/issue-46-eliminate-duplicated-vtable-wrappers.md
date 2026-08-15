triage: ready-for-human
Status: closed

Eliminate the 10 hand-written prod/mock vtable wrappers — they duplicate `facade.Make(CT)` which already generically produces these exact 5 wrappers for any context type.

## Problem

10 hand-duplicated wrapper functions in `ascii_renderer_alloc.zig` (5 per branch — the table shows all of them):

| Prod | Mock |
|---|---|
| `prodRenderWrapped` | `mockRenderWrapped` |
| `prodShowLegendWrapped` | `mockShowLegendWrapped` |
| `prodShowErrorWrapped` | `mockShowErrorWrapped` |
| `prodGetCommandInputWrapped` | `mockGetCommandInputWrapped` |
| `prodDeinitWrapped` | `mockDeinitWrapped` |

They are line-for-line identical — only the `@ptrCast(target_type)` differs. That is exactly the hand-generated duplication that a comptime generic exists to eliminate.

## Overlap with existing code (review finding 2026-08-15)

`facade.Make(comptime CT: type) type` in `facade.zig` (lines 52–89) already does this: it generates `render_wrapper`, `showLegend_wrapper`, `showError_wrapper`, `getCommandInput_wrapper`, `deinit_wrapper` for any type CT, and `make(instance: *CT)` returns a wired `Facade`.

For a type C to satisfy Make's contract, C needs these methods:
- `render(view: board.Board.BoardView, status_msg: ?[]const u8) facade.Error!void`
- `showLegend(commands: legend.Legend) facade.Error!void`
- `showError(msg: []const u8) facade.Error!void`
- `getCommandInput(names: []const []const u8) facade.Error!command.ParseCommandResult`
- `deinit() void`

**Both `ProdFacadeContext` and `MockFacadeContext` already satisfy the first four** — the "pass-through methods for Facade vtable wrappers" (lines 203–217, 239–253). The only gap: cleanup is named `freeAll()` instead of `deinit()`.

So the plan is NOT to add a new generic helper — it is to reuse the existing one:

1. Rename `freeAll()` → `deinit()` on both `ProdFacadeContext` and `MockFacadeContext` (update the two test call sites and `prodDeinitWrapped`/`mockDeinitWrapped` references before deleting them).
2. In `prodBranch` replace the 9-line `facade.Facade{...}` literal with:
   ```zig
   return facade.Make(ProdFacadeContext).make(ctx_ptr);
   ```
   (same for `mockBranch` with `MockFacadeContext`).
3. Delete all 10 hand-written wrapper functions.
4. **Keep the 8 pass-through methods** (4 per context) — `Make(CT)` calls `self.render(...)` etc. *on CT itself*, so the context's pass-through methods are required for `Make(ProdFacadeContext)` to compile. They stay; only the 10 hand-written vtable wrappers go.
5. Test suite passes: `zig build test`, then `zig test src/root.zig -lc` full run; `zig build run` still prints puzzle.

### Steps

| Step | Description | Status |
|------|-------------|--------|
| 1 | Rename `freeAll()` → `deinit()` on both context types; fix test call sites | Done |
| 2 | Both branches return `facade.Make(CtxType).make(ctx_ptr)` | Done |
| 3 | Delete the 10 hand-written wrappers | Done |
| 4 | Keep the 8 pass-through methods (4 per context) — they are the methods `Make(CT)` calls into; do NOT delete them | Done |
| 5 | `zig build test` + `zig build run` all pass | Done |
| 6 | Delete dead ownership block (`allocator`/`handles` fields, `Handles`/`ProdHandles`/`MockHandles`, `RenderMode`, struct-level `deinit`) — left over from the pre-`Make` design; never initialized or called | Done |

### Acceptance Criteria

- [x] Zero hand-written vtable wrapper functions in `ascii_renderer_alloc.zig`
- [x] Both branches use `facade.Make` — no new generic helper introduced
- [x] Net removal: 60+ lines (10 wrappers ≈ 47 lines + Facade literals shrink by ≈ 14; Make calls add little — plus ~50 lines of dead ownership block in Step 6)
- [x] All tests pass (SafeAllocator leak checks unchanged — `deinit` body is identical, only renamed)
- [x] `zig build run` demo still works
