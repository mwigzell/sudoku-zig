# ADR-0009 — Facade Make(CT) comptime construction stays as-is

Status: accepted
Date: 2026-08-11

## Context

`Facade.Make(CT)` binds function pointers at compile time through a concrete renderer type parameter. This pattern was part of the original facade design (Issue 29): every vtable slot is filled by referencing free functions on the concrete renderer, and the struct is instantiated at `main.zig` init time with the real renderer type.

A proposed deepening suggested revisiting this for "comptime readability" — making the table construction more explicit or moving binding elsewhere. This raised concerns:
- The pattern works: all function pointers resolve, the vtable bridges correctly, and 200+ tests pass through it
- It was the designer's own choice; retroactive second-guessing risks introducing a different problem to solve a non-problem
- Zig's comptime evaluation of `fn` pointer fields with `*const` prefixes (resolved during Issue 29) is the idiomatic vtable pattern — not a smell

## Decision

**Facade.Make(CT) stays as designed.** The comptime table construction will not be refactored unless it produces concrete pain:
- Repeated confusion during edits (same error, same file, multiple sessions), OR
- A second renderer type exposes a real defect in the binding pattern, OR
- It blocks another decision that has measurable value

The bar for retroactive readability improvements on working comptime code is high. "Could be clearer" does not meet it — "costs me time every edit cycle" does.

## Consequences

- Future contributors encounter the `Make(CT)` pattern as-is and learn the binding convention
- If WASM renderer integration reveals a genuine flaw in how function pointers are bound, that earns its own ADR with evidence
- The current pattern constrains future changes implicitly: any new facade method must be added to both the struct field and every concrete renderer's function table — that coupling is intentional and worth keeping visible
- Native menus take `Config` as one value per call (`getCommandInput(names, cfg)`) and draw Settings from core's config table, not per-pref scalar parameters or pref-sync methods — see [ADR-0020](0020-config-beside-the-engine-and-the-config-table.md) and AGENTS.md “Native renderer facade seam”
- Messages the player must answer go through one method, `promptMessage` — see [ADR-0017](0017-prompt-message-step.md)
- `render` takes core's `Frame` (`src/core/frame.zig`) as its only drawing argument, replacing `(view, status, selection, marks_visible)`; new drawing state is a frame field, not a new argument — see [ADR-0019](0019-core-owns-selection-and-frame.md)
