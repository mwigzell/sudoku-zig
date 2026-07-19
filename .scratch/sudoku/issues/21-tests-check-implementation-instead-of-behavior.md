Status: needs-triage

## Problem

**Sp4 from full code review:** Testing guideline says *"Tests exercise external behavior only, not internal implementation details"* but several Board tests directly inspect internal representation like `digit_bits` arrays and index lists rather than asserting observable behavior through the command→event seam.

---

## Context

The spec's ideal is exercising interfaces through GameEngine command→event boundary. Tests currently reach deep into:
- Box bitmask state (`b.digit_bits[box_idx]`)
- Internal row/column index arrays  
- Per-box digit tracking structures

These are valuable structural tests now, but they tie the test suite closer to implementation than intended by our testing philosophy.

## Acceptance Criteria

- [ ] Identify which internal-state assertions can be expressed through public seam methods instead
- [ ] Refactor at least one heavily-coupled test to use GameEngine command→event flow where practical
- [ ] Keep structural tests that prove correctness of internal invariants (not every test needs to go through GameEngine)
