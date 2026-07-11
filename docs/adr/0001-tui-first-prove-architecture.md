# ADR-0001 — TUI-first proves architecture before WASM browser

Status: accepted
Date: 2026-07-10

## Context

The target is a WASM Sudoku game running in the browser. However, cross-language boundaries (Zig ↔ JS), DOM rendering, and WebAssembly tooling all add friction that obscures whether the domain logic itself is sound. We need to prove GameEngine → Renderer correctness before introducing any cross-language integration complexity.

## Decision

Implement the first two vertical slices (static grid render, interactive play with validation) entirely in a **terminal UI** compiled natively. No WASM exports, no JS shell — just `main.zig` printing to stdout/stderr using standard terminal I/O. Once interactive play works end-to-end in TUI, the browser renderer is introduced and forces extraction of the Renderer interface.

Rationale:
- Terminal output requires zero boilerplate beyond what's already in Zig stdlib
- Debugging domain state (Board mutations, Validator errors) is immediate with `std.debug.print` or terminal output
- Proves command→event loop works before wrapping that logic across language boundaries
- Duplication arrives naturally when DOM renderer is added — interface extraction is driven by real code, not anticipation

## Consequences

- Two slices are TUI-only; once browser joins (slice 3), the Renderer interface exists with two consumers and DRY principle kicks in properly
- Nothing built in TUI is wasted — it becomes the first concrete implementation of the Renderer interface, tested against both terminal and DOM
- Adds ~1–2 vertical slices that would be "extra" if we went browser-first directly, but saves weeks of debugging cross-language state sync issues up front
