Status: closed

## Problem

`Board.clearCell()` is `pub` but only called from one production site — `GameEngine.tryClear()` inside the same module-level package. Its semantics ("hard reset: blank value AND strip given-bit") don't belong on `Board`'s public surface because the gameplay clear action isn't a "factory reset" — it's "blank out my entry."

---

## Context

**Public mutation surface is too wide.** Board exposes two write methods:
1. `setCell(row, col, val) !void` — guarded write; refuses given cells with `error.IsGiven`; sets value and updates box bitmask
2. `clearCell(row, col) void` — unguarded "nuke it" — sets value to zero, clears given-bit, updates box bitmask

The problem:
- GameEngine already owns the higher-level `tryFill` / `tryClear` cycle: guard → mutate → conflict refresh → render
- When a user clears their own entry, that cell was **never** marked as-given — so clearing the given bit is semantically meaningless (it's already clear). Using `clearCell` implies this is a destructive reset when it's just "set the value back to blank."
- A caller could call `clearCell` on an actual puzzle clue and silently erase its given status — no guard, no error returned
- `clearCell` bypasses the conflict refresh step (GameEngine does that separately, but nothing enforces it if someone calls `clearCell` directly)

**Why this matters:** Raw mutations should flow through GameEngine so the lifecycle (guard → mutate → conflict refresh → render) is always respected. Board's job is to hold state; GameEngine's job is mutation orchestration.

---

## Acceptance Criteria

- [x] `GameEngine.tryClear(row, col)` delegates to `self.tryFill(row, col, .zero)` — single line pass-through, no duplicated error handling / guard logic
- [x] `clearCell` is called from zero production sites (only co-located Board tests)
- [x] Make `clearCell` non-public (remove `pub`) so it exists only as a test helper / internal reset primitive on the Board struct
- [x] All tests pass
## Working Log

**`error.NotGiven` → `error.IsGiven` (Board.setCell)** — comptime error tag is created inline on the return expression at board.zig:206. Renamed so the name reads naturally: if the cell **is** given, return error.IsGiven. Updated all 3 references.
**tryClear delegates to tryFill(row, col, .zero)** — eliminated duplicated guard + conflict refresh + render logic. Now a one-line pass-through through the single mutation path.
