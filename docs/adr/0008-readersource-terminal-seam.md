# ADR-0008 — ReaderSource is the terminal I/O seam; no interceptor layer

Status: accepted
Date: 2026-08-11

## Context

`input_source.ReaderSource` wraps stdin/stdout and supports both real terminal file descriptors and canned mock responses for tests. A proposed deepening suggested extracting a "terminal dialog interceptor" from `AsciiRenderer` — a dedicated seam for prompts, save/open dialogs, and new-game options that sits between the renderer and standard I/O.

At time of review:
- Six existing e2e tests already prove the `ReaderSource` seam works (init with MockSource → canned responses flow through `getCommandInput`, `newGameOptions`, etc.)
- No second renderer exists yet that would exercise a different interception pattern
- The "interceptor" concept adds a layer whose only consumer is `AsciiRenderer` — it rearranges the same I/O calls, just behind another name

## Decision

**ReaderSource stays as the interception point.** Adding an "interceptor" abstraction between `AsciiRenderer` and terminal I/O earns nothing until:
- Two renderers need different dialog strategies (ASCII prompt-based vs. WASM modal forms), OR
- The current seam produces concrete pain during test authoring or edits

This is a direct application of ADR-0003 (abstractions earned by duplication). One consumer = no layer.

## Consequences

- Terminal dialog code lives inside `AsciiRenderer` directly calling through the `ReaderSource`/facade methods — that's fine until it isn't
- If WASM renderer needs an equivalent "dialog" concept, the duplication will be visible and extraction timing will be obvious
- The seam is already testable: `MockSource` replaces real stdin/stdout at construction time, so no additional indirection is needed for coverage
