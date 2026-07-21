Status: done
Type: task
Blocked by: (none — validator.zig compiles but has stale code to replace)

## What to build

Refactor `src/validator.zig` to use a single, lens-agnostic scope conflict detector powered by Board's RowView/ColView/BoxView indices. Borrow the count-array pattern from `.scratch/sudoku/issues/02-interactive-play/sudoku-conflict-api.zig` (read-only reference — do not copy as-is).

### Design decision

Validator knows Cell only (no Board import). One pure function:
```zig
pub fn flagScopeConflicts(cells: []const Cell, indices: []const usize) u128
```
Takes 81 cells + 9 flat-storage indices, scans with a `[10]u8` count array, returns bits 0..8 where bit `i` means the cell at `indices[i]` is duplicated. Works for ANY scope — no row/col/box-specific code.

Board owns:
- `validateBoard(b: *Board)` — full revalidation across all 27 scopes (9 rows + 9 cols + 9 boxes)
- `refreshConflictsForCell(row, col)` — incremental: clear only the affected row+col+box bits via a units mask, re-run detector on just those 3 scopes, OR results back
- Small helper to translate scope-relative bits (0..8) into full u128 board positions using the View indices

### Session plan (step by step)

**Step 1 — Write tests for `flagScopeConflicts` (TDD)**
Replace existing 6 tests with cleaner equivalents against the new signature:
- empty scope → 0
- row duplicate at positions 0 and 3 → bits 0|3 set
- column duplicate at positions 2 and 7 → bits 2|7 set
- box duplicate at positions 1 and 6 → bits 1|6 set
- unique digits → no false positives
- three-of-a-kind (same digit appears 3x) → all 3 flagged

**Step 2 — Implement `flagScopeConflicts`**
Count-array scan (`[10]u8`). Remove dead code: the old double-loop `flagConflicts`, the stale comments at line 92-95, the private `flagScope`/`flagScopeInPlace`.

**Step 3 — Wire Board side (validateBoard)**
Replace current validateBoard + flagScopeInPlace loop with a helper that:
1. Takes `(b: *const Board, indices: []const usize)`
2. Calls `flagScopeConflicts`
3. Translates scope bits 0..8 → full u128 board mask
4. Returns the board mask for OR-ing into `conflict_bits`

**Step 4 — Add incremental path (refreshConflictsForCell)**
- `unitsMask(row, col)` — precomputes which of the 9 cells in a given row/col/box map to (max 27 bits across all 3 scopes)
- Clear those bits from `conflict_bits` via `&= ~mask`
- Re-detect just the affected row, column, and box
- OR results back into `conflict_bits`

**Step 5 — Integration tests for full + incremental paths**
Tests already exist (validateBoard flags row/col/box conflicts) — adapt if API shape changed. Add:
- "refreshConflictsForCell updates only affected scopes"
- "refreshConflictsForCell does not touch unrelated cells"

### Verify after
- [x] `zig test src/validator.zig` passes with 7+ unit tests (flagScopeConflicts)


- [x] `zig build cov` — validator.zig > 95% coverage
