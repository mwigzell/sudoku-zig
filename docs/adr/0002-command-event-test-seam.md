# ADR-0002 — Command → Event seam as the single test boundary

Status: accepted
Date: 2026-07-10

## Context

We need a consistent approach to testing the Sudoku GameEngine without coupling tests to any specific renderer (TUI or WASM browser). The engine orchestrates commands, mutates Board state, runs validation, and emits events — the question is where we draw the test line.

## Decision

The **Command → Event boundary** is the sole integration seam:

- Tests feed commands into GameEngine as opaque input strings (or structs)
- Tests assert that the emitted event snapshot matches expected Board state
- No assertions against any renderer (TUI printing, DOM, terminal output)
- Domain model unit tests exercise Cell/Board correctness directly; GameEngine tests exercise command→event round-trips

This keeps test coverage independent of rendering medium while exercising all game logic.

## Consequences

- Adding a new renderer cannot break existing tests
- Command schema changes require updating event assertions together (coupled intentionally)
- If we later wish to render TUI or browser in CI, those are optional e2e layers, not required for confidence
