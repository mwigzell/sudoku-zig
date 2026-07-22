Status: closed

Triage date: 2025-07-23

**Sp4 from full code review:** Testing guideline says *"Tests exercise external behavior only, not internal implementation details"* but several Board tests directly inspect internal representation like `digit_bits` arrays and index lists rather than asserting observable behavior through the command→event seam.

---

## Context

The spec's ideal is exercising interfaces through GameEngine command→event boundary. Tests currently reach deep into:
- Box bitmask state (`b.digit_bits[box_idx]`)
- Internal row/column index arrays  
- Per-box digit tracking structures

These are valuable structural tests now, but they tie the test suite closer to implementation than intended by our testing philosophy.

## Acceptance Criteria

- [x] Identify which internal-state assertions can be expressed through public seam methods instead
- [x] Refactor at least one heavily-coupled test to use GameEngine command→event flow where practical
- [x] Keep structural tests that prove correctness of internal invariants (not every test needs to go through GameEngine)

## Done
- `97dd498` — refactored two remaining game_engine tests (`"GameEngine init builds board from puzzle string"`, `"GameEngine is non-generic, init takes only puzzle string"`) from `engine.board.*` to `engine.eventBoard()`.
- All 89 tests pass; coverage maintained. Board.zig invariant tests kept as-is (correct layer).

## Triage notes:
- Blocker (issue 20) is `Status: closed` — Event seam is implemented.
- Issue 20's Step 5 already converted most GameEngine tests to use `Event.ok.board_view`.
- **Remaining scope:** two game_engine tests (`"GameEngine init builds board from puzzle string"`, `"GameEngine is non-generic, init takes only puzzle string"`) still access `engine.board.` directly and should use `eventBoard()` instead.
- Board.zig tests checking `digit_bits` and `isConflicting(idx)` are legitimate low-level invariant tests — per AC #3 these are kept as-is (they test module-local invariants at the right layer).
## Blocked by: _none_ (issue 20 is closed)
