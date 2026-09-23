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

Rules from `AGENTS.md`, `CONTEXT.md`, and `.coding-standards.md` that grep can check without judgement:

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

## What it does not enforce

SOLID judgement, Feature Envy, speculative generality, and full architecture review still belong in **two-axis review** (`/code-review` skill or GitHub review issues). The script prints a reminder when it passes.
