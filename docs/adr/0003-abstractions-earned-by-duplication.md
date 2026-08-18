# ADR-0003 — Abstractions earned by duplication, zero day-one stubs

Status: accepted
Date: 2026-07-10

## Context

SOLID's Dependency Inversion principle suggests interfaces from the start. However, pre-building empty interfaces for components (Renderer, Puzzle Repository, Solver Service) that don't exist yet produces dead code and invites YAGNI violations — we'd be architecting solutions to problems we don't know we'll have.

## Decision

**Every interface or trait/struct-vtable is extracted only when two concrete implementations exist and duplication is obvious.** Until then:

- Renderer starts as a direct `print_grid_to_terminal(board)` call inside `main.zig`
- Puzzle data starts inline in the module that needs it
- Solver, if needed by "generate" and "solve-for-me", lives alongside generation code until an external solver client (or test harness) demands separation

When duplication finally arrives (terminal + DOM both need rendering logic), we extract `Renderer` as a small focused interface and implement both sides without ceremony. Same for Puzzle Repository when static arrays + generator coexist. No placeholder structs, no empty methods, no wiring diagrams speculating on future seams.

Rationale:
- Concrete-first code is shorter to write, easier to test, and harder to mis-speculate about
- Extraction happens where real pain exists (duplicate boilerplate), not in our heads
- Zig's strong typing means refactor cost to introduce an interface is minimal once the shape is known
- Keeps early slices lean and focused — no scaffolding

## Consequences

- First two slices contain "direct" calls that will later become implementations. Those refactors are explicit work in slice #3 (not hidden behind abstractions built months earlier)
- Future contributors see real usage patterns before interfaces appear, which guides better design
- If the project never grows past the terminal renderer or never adds auto-generation, we save ourselves dead code we'd have stubbed
