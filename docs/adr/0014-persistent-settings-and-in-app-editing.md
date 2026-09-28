# ADR-0014 — Persistent settings, host bootstrap, and in-app editing

Status: accepted
Date: 2026-09-28

## Context

Player preferences lived in code defaults and CLI flags with no durable file and no consistent UI across deployments. Issues **#61**, **#62**, and **#63** (GitHub, closed) shipped a vertical slice: disk-backed **`settings.json`**, web host bootstrap parity with native, and first-pass menubar/menu wiring. Review on **#63** also captured hygiene follow-ups (logging mkdir failures, API docs, optional e2e) — not repeated here.

Gaps that motivated this ADR as a **standing product rule** (not only a one-off ticket):

- Disk is not the product UI — users must not rely on hand-editing JSON for normal preference changes.
- Web boot must not invent difficulty/log defaults in JS when the host already resolved `Config` from disk + CLI (**#62**).
- Native and web are **twins** (ADR-0011): the same nominal fields in `config.Config` / `settings.json` should be changeable through each platform’s interactive shell where that platform is supported.

## Decision

### Authority and runtime copy

| Layer | Role |
|--------|------|
| **`config.Config`** | Nominal shape of user settings the app understands. |
| **`GameEngine.cfg`** | Live copy during play — **source of truth in the portable core**. |
| **`getConfig()` (wasm)** | JSON readout of `engine.cfg` for the DOM — **not** startup authority. |
| **`/host-config.json` (web serve)** | Host-resolved config snapshot for **first** wasm init — same merge rules as native startup. |

Mutations in session: **`Command` / `exec`** (`set_theme`, `set_region`, `set_warn_solvability`, `set_difficulty`, `set_log_level`, …) update `engine.cfg`; they do not live in `Legend`, SUD0, or ad-hoc JS globals.

### Startup merge (native and web host)

One pipeline (**`resolveStartupConfig`** / **`startup_config.zig`**):

1. Load **`settings.json`** from the platform data directory (or defaults if missing/invalid).
2. Apply **CLI** overrides.
3. **Save** merged result back to disk (so CLI changes stick).
4. Pass that struct into the runtime — native **`Sudoku.init(cfg, …)`**; web **`serveWithHostConfig(cfg)`** → page **`bootstrapHostConfig`** (legacy wasm **`bootstrap(u32,u32)`** removed).

Web session boot (**#62**): fetch host config → bootstrap engine → optional **SUD0 resume** from page session storage; if boot is empty (no resume), **generating New Game** uses host/default difficulty — not glue/page literals. **File → New** keeps an explicit difficulty picker for that action.

### Persistence file

- **Path:** `settings.json` under the platform data directory (`settings_store`; paths documented in README).
- **Keys (stable JSON):** `difficulty`, `log_level`, `theme`, `show_region`, `warn_solvability`, `preferred_renderer`, optional `fallback_renderer`.
- **Native in-session save:** `Sudoku` persists after view/settings commands when a data dir is configured (`settings_store.save`).
- **Web in-session save:** menubar actions **`POST /settings.json`**; serve merges partial JSON into host `Config` and writes disk (same nominal fields as native save).

**Session bytes** (in-progress puzzle) remain separate: native save files / web `localStorage` SUD0 — not mixed into `settings.json`.

### In-app editing (product rule)

Every **`settings.json` field that affects normal play or presentation** must be **editable in the supported front end** for that deployment — menubar, modal, or native numbered **Menu** — not only via CLI or manual file edit.

| Field | Web UI (expected) | Native UI (expected) |
|--------|-------------------|----------------------|
| `theme` | View (or equivalent) | Menu / Settings |
| `show_region` | View | Menu → Region |
| `warn_solvability` | File → Settings | Menu → Settings |
| `difficulty` | Settings and/or New flows | Menu / Settings |
| `log_level` | Settings | Menu / Settings |
| `preferred_renderer`, `fallback_renderer` | **Excluded** — CLI + file only (deployment choice) |

Splitting controls across **File → Settings** and **View** on web is acceptable; hiding a persisted field behind disk-only edit is **not**.

Implementation seam for **native** menu state: scalar parameters on existing **`Facade.getCommandInput`** from **`Sudoku.turn()`** (engine config snapshot per turn) — see AGENTS.md “Native renderer facade seam” and ADR-0009. **Web** uses **`exec`** + DOM; no facade.

### Solvability warnings

Single toggle **`warn_solvability`** (default **off**) drives proactive move/load “no solution” probes when enabled; unchanged hint/solve behaviour when disabled.

## Consequences

- New persisted prefs require: `Config` + `settings.json` schema, engine `exec`/command handler, **both** persistence paths (native save + web POST), and **UI on each supported platform** unless explicitly listed as CLI/disk-only like renderer choice.
- **`CONTEXT.md`** WireConfig / glossary should stay aligned with fields JS may read/write; renderer kinds stay off the wasm wire.
- Contract tests: `settings_store`, `startup_config`, `serve` POST merge, `host_settings.test.mjs`, glue host bootstrap — extend when adding fields.
- ADR-0010 wasm boundary remains JSON `init`/`exec`/`getConfig`; this ADR owns **where config comes from at boot** and **how changes return to disk**, not the REPL-shaped shell.
- ADR-0011 layer table references this ADR for settings ownership rows.

## References

- `src/config.zig`, `src/settings_store.zig`, `src/startup_config.zig`
- `src/native/shell/sudoku.zig`, `src/native/serve.zig`
- `src/wasm/shell.js` (`initializeWebSession`, `hostSettingsForPersist`, `persistHostSettings`)
- README — Settings section (data-dir paths)
