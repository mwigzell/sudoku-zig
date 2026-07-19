# Full Code Review — Sudoku Zig (2025-01)

Two-axis review of the entire codebase against:
- **Coding Standards** → `.coding-standards.md`
- **Spec** → `.scratch/sudoku/prd.md` + `CONTEXT.md`
- **Smell baseline** → Fowler _Refactoring_ ch.3 (from pi code-review skill)

---

## Standards (4 findings)

### S1 — Duplicated Code: `countOccurrences` / `fnCount` clone {#s1}

Same helper in two files, same algorithm:

**`styler.zig` line 140:**
```zig
fn countOccurrences(haystack: []const u8, needle: []const u8) usize { ... }
```

**`ascii_renderer.zig` line 182:**
```zig
fn fnCount(haystack: []const u8, needle: []const u8) usize { ... }
```

Byte-identical loop logic. Extract to a shared util module — or at least into one of the two files and import it from the other.

### S2 — Naming: `BOLD_ON` / "bold" labels lie {#s2}

**`styler.zig` line 51:**
```zig
const BOLD_ON = "\x1b[2m";   // \x1b[2m is DIM, not BOLD (\x1b[1m)
```

The variable name says BOLD, the comment above (line 50) says "Dim ON", and the test at line 113 says "bold CSI codes". Three names, one fact. Either rename `BOLD_ON` to `DIM_ON` through the board, or change the escape to `\x1b[1m`. Pick one.

**Status:** Fixed — renamed to `DIM_ON` and updated all call sites.

### S3 — Mutable pointer on read-only accessor {#s3}

**`board.zig` line 173:**
```zig
pub fn asView(self: *Board) BoardView {
    return BoardView{ .board = self };
```

This never mutates anything. Should be `self: *const Board`. Also, `asRow`, `asCol`, `asBox` (lines 128, 141, 154) take no `self` at all — they're free methods on the `Board` struct that don't need an instance. The comment says "Return a RowView for row n" but nothing ties them to the Board data model — any board can use the same indices. This is fine in practice (the indices are static) but it's confusing structurally: why live inside `Board` if they don't depend on it?

### S4 — Documentation gaps on public surfaces (coding standard #1) {#s4}

Coding standard: *"Every public function must have a header comment explaining its purpose, parameters, and return value."*

Missing:
- **`puzzle_gen.zig`** — `Difficulty`, `PuzzleGen.generate()`, `countGivens()` all undocumented.
- **`game_engine.zig`** — `fill()`, `fillAndRender()` have inline comments but no proper header docs like `init()`.
- **`board.zig`** — `getBoxDigitBits`, `setCell`, `clearCell` lack doc headers.
- **`logger.zig`** — the `Logger` generator itself is undocumented.

---

## Spec (4 findings)

### Sp1 — US3 conflicts: no Validator at all {#sp1}

PRD User Story 3: *"I want conflicts highlighted visually … so that I know when I've made a mistake."*

The PRD Implementation Decisions describe a **Validator** module (§2): *"conflict detection logic. Given a Board state, reports which cells are in error (duplicate digits in shared row/column/box)."* CONTEXT.md names it with explicit terminology guidance: _"Avoid: Checker (implies boolean only)"_.

There is zero conflict detection anywhere. No Validator struct, no duplicate-digit checking, no error flags on cells. `Board.digit_bits` tracks which digits are used per box (a good data structure for this), but nobody reads it to flag conflicts. The renderer has no path to highlight errors. This is the biggest gap — digit tracking infrastructure exists but is unused for its intended purpose.

### Sp2 — US10 cell selection: no state {#sp2}

PRD User Story 10: *"I want highlighted row/column/box regions when I select a cell."*

There's no concept of a "selected cell" anywhere — no state in `GameEngine`, `Board`, or `Cell`. The renderers have no highlight path. Main has no interactive loop. Without a selection concept, this story has no foundation yet. This is expected for vertical slice 1 (TUI prove-the-architecture), but worth noting as a gap versus the PRD's complete feature set.

### Sp3 — MockRenderer accesses private fields through a const pointer escape {#sp3}

**`mock_renderer.zig` line 23:**
```zig
cells[row][col] = view.board.cells[idx].value;
```

This goes through `BoardView.board` (a `*const Board`) to access `Board.cells` directly. The PRD says: *"Event snapshot describes the resulting state … the Renderer consumes this, not the Board or Grid themselves."* MockRenderer is doing exactly what the spec warns against — reaching past the view seam into Board internals. Currently fine for tests (co-located, internal), but it means `BoardView` isn't a real boundary — if cells were ever made private, the mock would break along with any renderer that reached through the same hole.

### Sp4 — PRD says "Tests exercise external behavior only" but many tests are implementation-deep {#sp4}

Coding standard / testing guideline: *"Tests exercise external behavior only, not internal implementation details."*

Several board tests verify internal representation:
- `"Board: init sets all box digit bitmasks to zero"` checks `b.digit_bits[box_idx]` directly.
- `"Board: fromFlat initializes digit_bits for given cells"` inspects per-box bitmask state.
- Tests like `"Board: asRow produces contiguous indices"` verify internal index arrays.

These are fine as structural tests — they prove correctness — but they're closer to what the testing guideline says to avoid. The spec's ideal is exercising only through `GameEngine` command→event boundary.

---

## Summary

| Axis | Findings | Worst Issue |
|------|----------|-------------|
| **Standards** | 4 (1 fixed) | ~~S2~~ — `BOLD_ON` lied about what it did. Renamed to `DIM_ON`. |
| **Spec** | 4 | Sp1 — Validator / conflict detection missing entirely despite `digit_bits` infrastructure being in place and the PRD calling it out as core domain logic. |

The overall architecture is solid for vertical slice 1. The layering (Cell → Board → GameEngine → Renderer) matches the PRD's intent, abstractions are earned not pre-stubbed, and the test coverage is thorough on the parts that exist. The main debt is that US3 (conflict detection/validation) has its data structure but none of the logic or rendering path around it.
