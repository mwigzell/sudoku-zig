# Verify standards gate

`zig build verify-run` runs `scripts/verify-standards.sh` after tests and format check. `zig build verify` wraps that in the timing gate — see `docs/agents/verify-timing.md`.

## Scope

Compares **added lines** on the current branch against the merge-base with `origin/main` (or `main`). Override with:

```bash
VERIFY_BASE=abc1234 zig build standards
```

Run standalone: `zig build standards`.

## Output

The gate prints a short banner on every run:

- **✓ PASSED** (green when stdout is a TTY) — mechanical checks clean
- **✗ FAILED** (red) — bullet list of violations with sample added lines

Force color in CI or build logs: `FORCE_COLOR=1 zig build verify`.

Disable color: `NO_COLOR=1 zig build standards`.

## What it enforces (mechanical)

Rules from `AGENTS.md`, `CONTEXT.md`, and `docs/coding-standards.md` that grep can check without judgement:

| Check | Rule |
|-------|------|
| Issue refs in code | No `(#N)`, `Issue N`, `Step N`, `chunk N` in comments |
| JSON escaping | No raw `{s}` in wasm `boundary.zig` error/msg JSON |
| Io-free engine | No `FileTransport` / save-open paths in `game_engine.zig` |
| Session fields | No new `data_dir` / `last_save_msg` on `GameEngine` |
| Wasm prefs | No `localStorage` in wasm JS |
| Retired symbols | No `BootstrapConfig`, `WasmHost`, `WasmTransport`, `WasmRenderer` |
| Serve DRY | No `assetBody` or inline asset switches in `serveClient` |
| Wire DRY | No parallel `JsonCell` + `CellSnapshot` structs |
| Test side effects | No live `openBrowser()` in unit tests |
| Public API docs | Added Zig `pub` symbols must have a preceding comment line |
| Wasm ownership | No new write-policy/state-machine literals outside legacy wasm entry points |
| Policy authority | No duplicated write-context event string literals outside `file_policy` authority |
| Test fixture DRY | No local `WRITE_CONTEXT_EVENTS` map literals in wasm tests; build from shell contract keys |
| Adapter text ownership | No dialog or status text written as a literal in adapter code (see below) |
| Restore lane contract | No startup restore routing through named-open copy (`name: restorePath`) in `src/wasm/flows/startup.js` |

## Adapter text ownership

Adapters show the text core supplies (`AGENTS.md`, "Text ownership follows the behaviour"). Adapter code is web JS and HTML (`src/wasm/**`), Android (`src/android/**`, without `src/android/test/`), the native shell and renderers (`src/native/**`), `src/web_host/**`, and the `src/entry_*.zig` entries. On added lines in those files the check flags:

- a sentence-shaped string literal: a quoted string that starts with a capital, holds a space and ends in `.`, `!` or `?` (dialog and status text is always full sentences);
- a web status fallback, `msg: x ?? "…"`, in `src/wasm/` JS outside `artifacts/`;
- a `.msg = "…"` literal in `src/native/shell/` outside `shell.zig`.

It skips comment lines, log calls (`log.*`, `Log.*`, `clientLog`, `console.*`, `std.debug.print`), `*.test.mjs` files and Zig `test` blocks. Technical reasons for core's log (`"paste: clipboard read denied"`) start lowercase and pass. Single-word titles and labels are not sentences, so the check does not see them; review catches those.

**Allow-list** (`ADAPTER_TEXT_ALLOWED` in the script). It holds platform-only text, for behaviour no core flow implements:

| Entry | Why the platform owns it |
|-------|--------------------------|
| `src/wasm/artifacts/page.html` `BOOT_FAILED_MSG` | Web boot failure, before wasm loads |
| `src/android/bootstrap/MainActivity.java` `BOOT_FAILED_MSG` | Android boot failure, before wasm loads |
| `src/native/ascii/parser.zig` (whole file) | The terminal's command-line help; typing commands is the terminal's own input |
| `src/native/ascii/renderer.zig` `NO_COMMANDS_MSG` | The terminal menu when it has nothing to offer |

An entry names a file, or a file and a constant. An entry whose file or constant no longer exists fails the check. Add an entry only for text the platform alone implements; anything a core flow implements goes through core's text.

## Cross-entry parity (`zig build parity`)

`scripts/verify-parity.sh` runs on the whole repo (not the branch diff) as part of `verify`. It fails when a scenario in `src/test/fixtures/parity_scenarios.json` is missing from `docs/parity-matrix.md` or its name is duplicated; when either runner (`src/test/parity/native.zig` for native, `src/wasm/flows/parity.test.mjs` for web and Android) stops loading the scenarios or drops out of its test list; when a scenario `skip` lacks a gap or an open issue, or a `not_on` lacks a reason; or when a step kind in `src/core/flow/step.zig` has no `STEP_*` constant and `case` in `src/wasm/flows/step_runner.js` (native gets that check from the Zig compiler). Steps a front end never receives are listed in the fixture's `steps_not_received`. It calls `gh` only when a skip exists. See `docs/parity-matrix.md`.

## What it does not enforce

SOLID judgement, Feature Envy, speculative generality, and full architecture review still belong in **two-axis review** (`/code-review` skill or GitHub review issues). The script prints a reminder when it passes.
