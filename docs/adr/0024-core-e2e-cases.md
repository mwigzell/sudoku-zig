# ADR-0024 — Core e2e cases: the player's use cases, driven through the terminal

Status: accepted
Date: 2026-11-20
Related: `docs/testing/core-e2e-cases.md` (the case list), `docs/agents/verify-slow.md` (the gate that runs them), `docs/zig-testing.md` (the testing guide), ADR-0002 (command/event/test seam)

## Context

The terminal is the vanilla lingua franca of core. Every front end adapts the same engine, but the
terminal is the one whose input is the raw command text — no tap, no button, no bridge — so a use
case driven through the terminal proves the core behaviour itself, independent of any front end's
presentation.

Two defects showed what happens without such a suite:

- The Pencil button (`toggle_pencil_mode`) shipped in core and web/Android, but the terminal parser
  never wired it, so typing `P` did nothing. Parity did not catch it: the native arm injects the
  command directly into the engine, bypassing the parser. The bug was invisible until a player
  typed `P` at the prompt.
- A use case that spans several commands (turn Auto Pencil on, toggle Pencil, fill, undo, turn it
  off) had no test asserting the story's outcome, only unit tests of each command in isolation.

The gap is not "a command lacks a unit test" — it is "no test walks a player's use case through the
real terminal input path and asserts the outcome." Unit tests prove the parts; the use case proves
they are wired together and behave as the player experiences them.

## Decision

- **Core e2e cases are the authoritative use-case suite.** Each is a player story, expressed as a
  precise terminal command sequence with an asserted outcome, driven through the real input path
  (`Host.createForTest` → parser → engine), never a `DeterministicFacade` step that bypasses the
  parser.
- **Each case has a long mnemonic** in Gherkin form — `given_<state>_when_<action>_then_<outcome>` —
  that names the story, not the command. The mnemonic list is the primary index: a fixture, an issue
  or a review cites the mnemonic, and the doc explains why each command is in the case.
- **The cases live in `src/test/slow/core_e2e.zig`**, imported by `src/entry_verify_slow.zig`, so
  they run in `zig build verify-slow` — the delivery gate — and not in the fast `verify` cycle.
- **A use case spans the commands its story needs.** It is not one test per command; it is one test
  per story, and the story is what a player does, not what a command table lists.
- **A new command or behaviour ships with its use case in the same change.** The use case is the
  first red test (TDD): it fails until the command is wired through the terminal and its outcome
  holds.
- **Renderer smoke tests are not use cases.** A test that proves the renderer builds and renders
  (ANSI facade, ASCII grid, prodBranch) stays in the fast core suite, renamed so it does not claim
  to be an end-to-end use case.

## Consequences

- A command that is added to core but not wired into the terminal fails its use case, so the
  `toggle_pencil_mode` class of defect cannot ship silently.
- The mnemonic list in `docs/testing/core-e2e-cases.md` is the map from player story to test; a story with
  no mnemonic has no proof.
- The use cases run in verify-slow, so they cost the delivery gate, not every cycle; a use case
  that must run every cycle belongs in the fast suite instead.
- The terminal remains the canonical driver: a use case that cannot be expressed in terminal
  commands is not a core use case, it is a front-end-specific one (the Android device suite, or
  the cross-front-end parity suite).
