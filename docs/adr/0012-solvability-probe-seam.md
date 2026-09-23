# ADR-0012 — Solvability probe seam on GameEngine; solver stays pure

Status: accepted
Date: 2026-09-23

## Context

Commit `1d2b492` added unsolvable warnings after player moves and on open/load. Both paths call `solver.solve()` directly inside `GameEngine`. Integration tests route most gameplay through `execTest`, so every fill/clear/undo/redo pays a full backtracking solve — test time jumped from ~2.5s to ~75s on wasm-era baselines.

The slowdown is not the solver algorithm; it is **when the engine chooses to run it**. Warning-after-move and warning-on-load are engine policy. `solve_for_me` and redo of a solve batch are different semantics (mutate board + history, not probe-and-warn).

A partial fix gated `solver.solve()` at the move call site behind `warn_dead_moves`. That scattered policy across call sites, left the load path ungated, and invited a guard inside `solver.solve()` — which would break tests and commands that need an honest solve.

## Decision

### `solver.solve()` stays pure

`solver.zig` answers one question: can this board be completed? It does not know about player warnings, test binaries, or deployment. No guards, stubs, or `builtin.is_test` branches inside `solve()`.

### One engine seam for probe-and-warn gameplay

`GameEngine` exposes a single private method for solvability **checks that may produce warnings** — e.g. `probeSolvability()` (name fixed at implementation). It:

- calls `solver.solve(self.state.board)` internally;
- returns `?solver.SolveResult` (or equivalent) so callers can append warnings;
- is the **only** path from gameplay warning logic to the solver.

Call sites:

| Call site | Uses probe seam | On `.none` |
|---|---|---|
| `finishOkAfterCellEdit` (fill/clear/undo/redo cell edits) | yes | append dead-move warning |
| `finishLoadEvent` / open-from-save | yes | append load warning |

Both funnel through `probeSolvability()`, not duplicate inline `solver.solve()` calls.

### Policy flags live on the engine, not in the solver

Whether `probeSolvability()` runs is controlled by engine fields (defaults TBD at implementation — e.g. `warn_dead_moves`, and a load equivalent or shared flag). Runtime (`zig build run`, wasm): on. Test binary: off by default so bulk `execTest` stays fast.

Specs that assert warning text opt in explicitly (e.g. a test helper that sets the flag for that engine instance) rather than making every integration test pay for solvability probes.

### Three distinct solver roles — do not conflate

| Role | Owner | Uses probe seam? | Always runs in tests when exercised? |
|---|---|---|---|
| Probe and warn (move, load) | `probeSolvability()` | — (is the seam) | only in opt-in warning specs |
| Solve for me | `solveForMe()` | no | yes — tests need real solve + board mutation |
| Redo solve batch | `redo.zig` (restore post–solve-for-me board) | no | yes when that redo path is under test |

`solveForMe` and redo solve batch call `solver.solve()` directly for **apply the grid**, not for optional status messages. They do not go through `probeSolvability()`.

## Consequences

- Warning policy is one place to read and one place to gate for performance; load and move paths cannot drift to different guard rules.
- `solver.zig` tests and engine tests that need a real solve (`solve_for_me`, unsolvable grid fixtures, direct assertions) stay unchanged.
- Implementing this ADR replaces scattered inline `solver.solve()` in warning paths and supersedes a call-site-only `warn_dead_moves` guard without moving policy into `solve()`.
- Until implemented, shipped code still has duplicate inline solves in `finishOkAfterCellEdit` and `appendUnsolvableLoadWarningIfNeeded`; treat this ADR as the target shape for that refactor.
