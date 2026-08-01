# Handoff — Issue 25: Format Decision & Next Steps

## What We Decided Today

**Binary format finalized:** `SaveFileHeader` (8B) → N×`SaveEntry` (2B each) → `SaveFileTrailer` (97B given_bits+flat_board). Packed structs. Reserved bytes for future-proofing.

**Open > Load** — command naming changed from LOAD to OPEN throughout all docs/specs. This was done once before and needs to stick.

**Why we broke:** Step 3 said "hand-wavy spec of fields" then we jumped to code. The format should have been nailed BEFORE implementation. We now have it documented in `.scratch/sudoku/issues/25-save-restore/save-file-format.md`.

## Issue File State
- `25-save-restore.md` was restored to its ORIGINAL state from commit `0fedc1a` because my editing attempts destroyed the file structure (lost Steps, lost Acceptance Criteria). Needs rewriting with:
  - Status → in-progress
  - LOAD → OPEN throughout  
  - Move Binary Format Spec + Open Decisions BEFORE Steps section
  - Keep Acceptance Criteria intact
  - Remove "Blocked by" (there are no blockers)

## Remaining Work
- TDD `SaveFileHeader` / `SaveFileTrailer` structs into `game_engine.zig`
- Rewrite `saveGame()` to use blob writes via buffered writer (`writeAll(std.mem.toBytes(&header))`) — current impl uses `.interface` which drops bytes past offset 8+
- Wire `.save`/`.open` in sudoku.zig (not exec()) — exec() can't reference `std.testing.io`
- Implement `openGame()` + round-trip test

## Next Up
Pick up TDD for the structs. The format is locked, time to code it.
