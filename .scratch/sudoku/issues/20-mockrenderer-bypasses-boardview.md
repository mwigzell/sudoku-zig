## Problem

**Sp3 from full code review:** MockRenderer reaches past the `BoardView` seam into `Board.cells` directly, breaking the boundary that renderers should not access internal Board structures.

---

## Context

PRD spec: *"Event snapshot describes the resulting state … the Renderer consumes this, not the Board or Grid themselves."*

MockRenderer does exactly what the spec warns against — reaching through a `const BoardView.board` pointer to mutate test assertions on internals rather than using view methods. Currently fine for tests (co-located, internal) but means `BoardView` isn't enforcing its own boundary.

## Acceptance Criteria

- [ ] MockRenderer uses only public accessors through `BoardView` instead of reaching into ` Board.cells[idx]`
- [ ] All tests still pass after refactoring
- [ ] Boundary is enforced enough that we couldn't accidentally bypass it if someone tried again
