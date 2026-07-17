Status: ready-for-agent
Blocked By: Issue 15 — Board topology refactor (ADR-0006)

## Working mode
HITL (Human In The Loop). One TDD cycle per session.

## Parent

`.scratch/sudoku/prd.md`

## What to build

Implement `TuiRenderer` as a concrete renderer fulfilling the interface from issue 09. Rewrite the current `printGrid` function into a proper struct that reads the board through Grid views (`row(n).cells()`, `col(n).cells()`, `box(br, bc)`) — not flat array indices.

### TuiRenderer implementation
- Struct satisfying the renderer interface/contract from issue 09
- Replaces `printGrid` (flat-index based) with methods that consume Board through Grid lenses
- Retain current ASCII box-boundary rendering style (top/down borders, vertical dividers every 3 columns); no visual regression
- Must compile against new Box/Grid/Board types from issue 01

### Conflict & locked-cell highlighting
Implement conflict visualization: cells flagged by the Validator render differently (ANSI red or unicode emphasis — implementation choice). Distinct from region highlighting (issue 07).
Also handle locked-vs-user filled cell distinction (moved here from StdoutRenderer #11).

### What this does NOT cover
- Renderer interface definition (issue 09)
- WASM/browser renderer implementation (issue 03)

## Acceptance criteria

- [ ] `TuiRenderer` struct exists satisfying the renderer interface from issue 09
- [ ] Compiles against new Board/Grid/Box types (no flat-index access to `b.cells[]`)
- [ ] ASCII grid output matches pre-refactor visual layout (box boundaries, dividers)
- [ ] Existing render test suite passes after migration (`cellChar`, grid rendering equivalents)
- [ ] Conflicting cells are visually highlighted in output
- [ ] Rendering path accesses cells through Grid views (`row(n).cells()`, `col(n).cells()`, or `box(br, bc)`)

## Blocked by

(none) — renderer interface (issue 09) complete

## Comments
