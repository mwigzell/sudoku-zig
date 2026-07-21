# Code Review — board.zig & validator.zig (0e90a9)

Two-axis review of `board.zig` and `validator.zig` against:
- **Coding Standards** → `.coding-standards.md`
- **Spec** → CONTEXT.md Validator definition + PRD User Story 3
- **Smell baseline** → Fowler *Refactoring* ch.3 (pi code-review skill)

No diff baseline — reviewing both files as-is following the validator namespace refactor handoff (`/tmp/pi-handoff.md`).

---

## Standards (4 findings)

### S1 — Magic numbers in box loops (`board.zig`) {#s1}

**Standard:** No magic numbers (§4). **Judgement call.**

`validate()` line 286: `for (0..3)` uses bare `3` instead of a derived constant. The constants exist nearby:
- `BOX_DIMENSION = 3` (line 11)
- `DIMENSION_SIZE = 9` (line 8)

Same pattern in `refreshConflictsForCell()` loop (line 284 area). Replacing `0..3` with `0..(DIMENSION_SIZE / BOX_DIMENSION)` or a named constant would remove the last bare literals from validation logic. Minor, no-effort fix.

### S2 — Stale/drifted comment block (`board.zig` lines 145–148) {#s2}

```zig
/// Return a RowView for row n (0..8).    // ← line 145-146, belongs to asRow

/// Create a borrowed read-only view of this board's cells.  // ← line 148, belongs to asView (line 283)
pub fn asRow(n: u4) RowView {
```

The second comment drifted from `asView` during the refactor. Harmless but confusing — a reader scanning top-to-bottom would think `asRow` borrows the board's cells read-only (it doesn't; it returns flat-storage indices with no receiver).

### S3 — Documentation gaps: resolved {#s3}

**Standard:** Document public surfaces (§1). **Previously captured as issue 19.**

Prior full review (`.scratch/code-review-full.md`, S4) flagged `getBoxDigitBits`, `setCell`, `clearCell`, `isConflicting` etc. as undocumented. All six previously-flagged methods now have proper `///` doc headers.

**Status: resolved.** ✓

### S4 — Test mutates through private seam, skipping public setter (`board.zig` line 952) {#s4}

```zig
b.cells[16].value = .nine;
b.refreshConflictsForCell(1, 7);
```

Test `"Board: refreshConflictsForCell does not touch unrelated cells"` bypasses `setCell`, which would also call `updateDigitBits` to maintain the per-box `digit_bits` bitmask. This means `digit_bits` is stale relative to actual cell values. The test's purpose (checking conflict isolation) doesn't depend on digit bits, so it still passes — but if shared board state were ever used, this broken invariant would propagate. Minor risk since each test starts from fresh `Board.init()`.

---

## Spec (3 notes)

### Sp1 — PRD US3 conflict detection: resolved {#sp1}

**PRD §2:** "conflict detection logic reports which cells are in error (duplicate digits in shared row/column/box)."

Prior review flagged zero conflict detection existed. Current state:
- `Board.validate()` walks all 27 units (9 rows + 9 columns + 9 boxes), delegates to `Validator.flagScopeConflicts()`, accumulates into `conflict_bits`. ✓
- `Board.refreshConflictsForCell()` provides incremental conflict refresh on cell mutation. ✓
- 8 integration tests cover row, column, box-only, multi-scope, and incremental scenarios. ✓

**Status: resolved.** This was the core gap the refactor addressed.

### Sp2 — Incremental refresh is semantically correct {#sp2}

`refreshConflictsForCell()` does `self.conflict_bits &= ~umask` to zero out only affected row+col+box cells, then ORs in new results. Conflicts within those units that no longer apply are cleared; conflicts in other units remain untouched. Correct-by-design for incremental update — no spec violation.

### Sp3 — Validator scope narrower than CONTEXT.md's literal definition (not a violation) {#sp3}

CONTEXT.md says Validator reports conflicts with "row (RowView), column (ColView), or Box (owned 3×3)." Current `flagScopeConflicts` takes raw `[]const Cell` + index list, not the RowView/ColView types. It's a generic scope detector parameterized by position — more reusable than per-view coupling. Meets intent; design improvement over spec's literal wording.

---

## Summary

| Axis | Findings | Worst Issue |
|------|----------|-------------|
| **Standards** | 4 (S1–S4) — S3 from prior review resolved, 3 new judgement calls | S1 — bare `3` in box loops where named constants exist |
| **Spec** | 3 notes (Sp1–Sp3) — Sp1 resolved, Sp2 correct-by-design, Sp3 design improvement not violation | None action-required. Prior spec blocker (missing conflict detection) fully closed. |

The validator refactor is clean on the spec axis — the main prior gap (no conflict detection) is closed. Standards findings are all judgement calls around magic numbers, a drifted comment, and test seam usage; no hard violations of the documented coding standard.

---

**Note on S1 (duplicated call pattern):** User noted the six `flagScopeConflicts` call sites aren't duplication — they're the same algorithm applied to different lenses (row/col/box). Extracting wouldn't simplify, just add indirection. Closed.
