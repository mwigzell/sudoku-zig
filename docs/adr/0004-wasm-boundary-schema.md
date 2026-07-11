# ADR-0004 — WASM ABI uses JSON snapshot events + command strings

Status: accepted
Date: 2026-07-10

## Context

When slices transition from TUI-only to browser, we must define how Zig communicates with JavaScript across the WebAssembly boundary. The domain layer produces full-state snapshots (Board) and consumes player intents (commands). We need a concrete ABI shape that is simple, debuggable, and testable without special tooling.

## Decision

- **Events**: Zig serializes the Board state snapshot as **flat JSON strings** after each command completes. JS receives these via exported pointer + length (or `MemoryData` struct pointing into WASM linear memory) and parses with standard `JSON.parse`.
- **Commands**: JS sends player actions as **string arguments** to exported functions (e.g., `fill_cell("3 5 7")`). Format is free-form per command; parsing happens inside Zig. This matches exactly how the TUI receives input (`stdin → GameEngine.parse_command`), so no new parsing layer exists for browser.
- Zig owns all state. The JS shell is a **passive renderer** — it never mutates the Board directly; it only re-renders DOM from whatever full-state event it receives.

Rationale:
- JSON works everywhere without binary struct alignment issues across Wasm ABI boundaries
- Debugging is trivial: both sides log the same printable string representation
- Matches our TUI command parsing path — no duplication of intent-extraction logic for browser
- Keeps JS renderer thin (stateless render loop, no game knowledge)

## Consequences

- If performance profiling shows JSON serialization becomes a bottleneck at large event payloads (unlikely for 81 cells), we replace with binary structs later using the same exported pointer pattern — but we start simple.
- Command parsing errors surface in Zig as rejected commands (no state mutation); error events can be emitted similarly to success events and rendered identically by any consumer.
