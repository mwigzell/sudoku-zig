Status: closed
Date completed: 2026-07-13

## Working mode
HITL (Human In The Loop). One TDD cycle per session.

## Parent

`.scratch/sudoku/prd.md`

## What to build

Define a minimal renderer interface (Zig struct or virtual table) that will serve as the contract between GameEngine and any concrete renderer (TUI, browser, future additions). Currently `render.zig` has no abstraction — functions operate directly on `Board`. This issue defines the boundary; implementation is separate.

### Renderer interface

Define a thin contract covering at least:
- `render(board_snapshot)` → draw full grid
- Methods required for event-based re-rendering after command execution

Extract only if duplication justifies it (coding standards: *"abstractions earned by duplication, never stubbed"*). If only one concrete renderer exists at this point, define a forward-declared struct that both TUI and WASM implementations will satisfy.

### Conflict highlighting (forward-compatible)

The interface must represent conflict state so any renderer can highlight conflicting cells. The Validator hasn't shipped yet (issue 02); just ensure the data shape is in the contract.

## Acceptance criteria

- [x] A renderer interface/contract exists defining `render(board_snapshot)` minimum
- [x] The contract supports conflict marking data (even if no conflict marks exist yet)
- [x] The interface is testable without a concrete renderer implementation
- [x] Existing test suite (`cellChar`, grid rendering) passes against the new contract

## Blocked by

(none)

## Comments
