# ADR-0011 — Layer ownership: where each concern's state may and may not live

Status: proposed
Date: 2026-12-18

## Context

Placement drift. A recurring failure mode across this project: implementation is correct locally but a concern is housed in the wrong layer, and the error is only visible from the other deployment. Same shape, different cases:

- `std.Io` field on `GameEngine` (2026-08) — capability of a deployment housed in the portable core.
- `save_format` manufacturing a `GameEngine` from bytes — codec smuggling a runtime object.
- `WebGame` second app object in the wasm path — a parallel application beside the core instead of a thin entry (2026-08-31 owner ruling).
- `showError` implemented as fire-and-forget in wasm — ack contract of an interactive surface dropped (issues #25/#26 era).
- Region highlight memo (issue #46, 2026-12) — both attempts pulled the "last cell" memo into the **renderer**; it belongs in the driver (native) / page (web), exactly where the twin already keeps selection.

`AGENTS.md` says closed issues are historical and code is source of truth, but none of these was caught because there was no *written* rule saying which layer owns which concern. ADR-0010 pins the wasm boundary and engine I/O-freeness but not the general placement law.

This project's unique asset is the **twin deployment**: one portable core, two thin entries (native driver `src/native/shell/sudoku.zig`; wasm `src/wasm` + `src/wasm_entry.zig`). Any placement question already has an answer in the sibling deployment.

## Decision

Placement decisions cite the twin before they invent a new home. Ownership table (as of this ADR; "never" is load-bearing):

| Concern | Owning layer | Never in |
|---|---|---|
| Game state (board, history, `cfg`, SUD0 codec) | `GameEngine` / `src/board` | renderers, drivers, entries |
| One-shot facts (conflict, win, last cell, msg) | engine → `Event`/`BoardView`, delivered per render | stored in renderer or driver across renders (except the memo below) |
| Cursor / selection memo | **UI-session layer**: `driver` (native shell) / JS app (`board.js` `selection`, web) | renderer, engine, event as storage |
| File I/O bytes | `FileTransport` arms (native `std.Io`; wasm JS imports, ADR-0010) | engine, board, facade |
| Session lifecycle (`new`/`open`/`save`/`save_as`) | driver (native) / JS app (web) | renderers |
| `io: std.Io` | host + transport arms, capability-injected (ADR-0010) | engine, facade, board, `event` |
| Rendering (paint, shade, borders) | renderer, **stateless painter** over `(view, status, selection/args)` | any concern state; see #46 AC |

Rules:

1. **Twin test** — before any new field, method, or seam, ask: what does the sibling deployment do here? If the answer differs, say why explicitly (issue Decisions section).
2. **Renderer is a painter** — it accepts call args each render and stores nothing per-session. If a renderer needs to remember something between renders, the memory belongs in the driver (native) or the JS app (web) that calls it.
3. **Engine is state + pure rules** — no capability handles, no `io`, no I/O fns, no objects it manufactured from bytes.
4. **One core, two thin entries** — no second app object, no second startup path per deployment (ADR-0010).
5. **Issue Decisions sections carry placements** — every new concern's home and non-homes are written in the issue body before RED, citing this table.

## Consequences

- Table becomes a review gate: any diff adding state to a layer contradicted by a row fails review regardless of green tests.
- Green tests are a floor, not a placement proof — a wrongly-placed concern compiles and passes (this year's incidents did).
- Rows may be amended by a new ADR or by owner decision recorded in an issue body; they do not drift by code accident.
- Existing code not yet conforming (e.g. #46's memo not yet in the driver) is fixed at the issue's closeout, not here.
