# ADR-0011 — Layer ownership: where each concern's state may and may not live

Status: proposed
Date: 2026-12-18

## Context

Placement drift. A recurring failure mode across this project: implementation is correct locally but a concern is housed in the wrong layer, and the error is only visible from the other deployment. Same shape, different cases:

- `std.Io` field on `GameEngine` (2026-08) — capability of a deployment housed in the portable core.
- `save_format` manufacturing a `GameEngine` from bytes — codec smuggling a runtime object.
- `WebGame` second app object in the wasm path — a parallel application beside the core instead of a thin entry (2026-08-31 owner ruling).
- `showError` implemented as fire-and-forget in wasm — ack contract of an interactive surface dropped (issues #25/#26 era).
- Region highlight memo (issue #46, 2026-12) — both attempts pulled the "last cell" memo into the **renderer**; it belongs in the driver (native) / page (web), exactly where sibling entries already keep selection.

`AGENTS.md` says closed issues are historical and code is source of truth, but none of these was caught because there was no *written* rule saying which layer owns which concern. ADR-0010 pins the wasm boundary and engine I/O-freeness; **ADR-0014** pins persistent settings, host bootstrap, and in-app editing — but not the full placement law in this table.

This project's unique asset is **one portable core, N thin front-end entries**. Any placement question should be resolved by comparing **sibling entries**, not inventing a one-off home.

**Front-end entries (authoritative list):**

| Entry | Process wiring | Play surface |
|--------|----------------|--------------|
| **Native terminal** | `main` → `native/desktop_terminal.zig` → `Host` + `Sudoku` | Terminal renderer facade (`native/shell/`) |
| **Desktop web** | `main` → `native/desktop_web.zig` → `web_host` + browser open | JS shell (`src/wasm/`) + wasm |
| **Android host** | `src/android/` JNI + minimal Java bootstrap → `web_host` | WebView loading loopback URL + same JS shell (ADR-0013 default) |

## Decision

Placement decisions cite a sibling entry before they invent a new home. Ownership table (as of this ADR; "never" is load-bearing):

| Concern | Owning layer | Never in |
|---|---|---|
| Game state (board, history, `cfg`, SUD0 codec) | `GameEngine` / `src/board` | renderers, drivers, entries |
| One-shot facts (conflict, win, last cell, msg) | engine → `Event`/`BoardView`, delivered per render | stored in renderer or driver across renders (except the memo below) |
| Cursor / selection memo | **UI-session layer**: `driver` (native shell) / JS app (`board.js` `selection`, web) | renderer, engine, event as storage |
| File I/O bytes | `FileTransport` arms (native `std.Io`; wasm JS imports, ADR-0010) | engine, board, facade |
| Session lifecycle (`new`/`open`/`save`/`save_as`) | driver (native) / JS app (web) | renderers |
| `io: std.Io` | host + transport arms, capability-injected (ADR-0010) | engine, facade, board, `event` |
| Rendering (paint, shade, borders) | renderer, **stateless painter** over `(view, status, selection/args)` | any concern state; see #46 AC |
| Nominal user prefs (`Config`, `settings.json`) | **`GameEngine.cfg`**; load/save via **`settings_store`** (native **`Sudoku`**) or **`web_host`** POST (web) | renderers holding prefs; JS boot literals overriding host config; engine reading disk directly |
| Settings / view pref **UI** | Native **Menu** (+ **`getCommandInput`** scalars from driver); web **menubar** + modals + **`exec`** | disk or CLI as the **only** way to change a persisted player-facing field (ADR-0014) |

Rules:

1. **Sibling-entry test** — before any new field, method, or seam, ask: what do other supported entries do here? If the answer differs, say why explicitly (issue Decisions section).
2. **Renderer is a painter** — it accepts call args each render and stores nothing per-session. If a renderer needs to remember something between renders, the memory belongs in the driver (native) or the JS app (web) that calls it.
3. **Engine is state + pure rules** — no capability handles, no `io`, no I/O fns, no objects it manufactured from bytes.
4. **One core, N thin entries** — per entry, no second app object and no second startup path in the same process (ADR-0010).
5. **Issue Decisions sections carry placements** — every new concern's home and non-homes are written in the issue body before RED, citing this table.
6. **Front-end feature parity is mandatory** — shipped user-visible gameplay/session capabilities are expected on every supported front-end entry. A temporary gap must be explicit in the owning issue as a scoped exception with follow-up ownership; "platform-specific shell" is not a standing waiver.
7. **Front ends stay dumb** — entry/UI layers orchestrate input/output and lifecycle only. They do not own business rules, persistence policy, or feature semantics that belong in shared seams (`engine`, shared codecs, shared host interfaces). If a capability appears to require front-end-specific logic, first extract a shared seam instead of re-implementing behavior per front end.

## Consequences

- Table becomes a review gate: any diff adding state to a layer contradicted by a row fails review regardless of green tests.
- Green tests are a floor, not a placement proof — a wrongly-placed concern compiles and passes (this year's incidents did).
- Rows may be amended by a new ADR or by owner decision recorded in an issue body; they do not drift by code accident.
- Existing code not yet conforming (e.g. #46's memo not yet in the driver) is fixed at the issue's closeout, not here.
- Front-end entries cannot silently diverge on user-facing behavior. If one entry ships a capability and another does not, the gap must be tracked as an explicit exception and closed, not treated as a permanent difference.
- UI/entry code remains transport and presentation glue; shared behavior is implemented once in shared seams and consumed by each front end.
