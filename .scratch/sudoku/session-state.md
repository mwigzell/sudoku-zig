[2026-07-15] TDD Cycle 1 — Issue #14: Logger Subsystem

Red -> green on base factory shape. `Logger(comptime scope: anytype) type { return struct { ... }}`.
Routes through std.log default formatter, comptime-gated below threshold via std.log.logEnabled().

## What we learned
@src() works inside function body with `const src = @src();` and resolves to caller's file/line correctly.
Zig 0.17 dev rejects `@src()` as a default parameter value (parser error: expected ',' after parameter).

## Current state
28 tests passing. Logger module has a .debug() method wired with comptime scope gating.

## Remaining acceptance criteria from issue #14:
1. [x] Logger factory with comptime-scoped tagging
2. [ ] Wire custom logFn for format: `[LEVEL] [scope_tag] file.zig:LL - message`
3. [ ] Add remaining severity methods: .err(), .warn().info()  
4. [ ] Implement .fatal() with stack dump + abort (noreturn)
5. [ ] Added opt-in `stack bool = false` named param to all non-fatal methods
6. [ ] Integration test with GameEngine logging at least two messages as spec'd

## Next: Cycle 2 — custom logFn formatting wired through std.options.logF

---

## Issue #15

Working from `.scratch/sudoku/issues/15-refactor/`.
Current sub-issue: **15.1** (`15.1-refactor.md`) — Flat `[81]Cell` storage + accessor methods (HITL)

## Issue 15.1 Session

### Completed
| Test | Status | Notes |
|------|--------|-------|
| Test 2: cellAt row-major math + pointer aliasing | ✅ Green | `cellAt` implementation already correct; test added as coverage proof |

---

### In Progress: Test 3 — setCell / clearCell lifecycle

**Goal:** Verify `setCell` places a digit, doesn't mark it as given; then `clearCell` resets both value and given flag.

**Red phase:** Write the test first → will fail to compile because `Board.setCell` and `Board.clearCell` don't exist yet.
**Green phase:** Add minimal implementations of both methods.

Halt after green, wait for direction.

---

## Tool Notes

**edit vs write — when to use which:** Large structural rewrites (replacing >50% of a file, adding/removing multiple functions/tests) → `write` the whole file. Small surgical touches (1–3 non-adjacent lines, swap an identifier, add inline comment) → `edit`. Always re-read after a write or failed edit; never chain edits on stale anchors.

