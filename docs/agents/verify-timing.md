# Verify timing gate

`zig build verify` runs `scripts/verify-gate.sh`, which times `zig build verify-run` with bash's built-in `time` (`TIMEFORMAT='%R'`) and checks `docs/verify-timing.json` with `jq`.

## Tracking file

`docs/verify-timing.json` (committed):

| Field | Meaning |
|-------|---------|
| `budget_seconds` | Hard ceiling — verify fails above this |
| `last_seconds` | Duration of the last successful verify |
| `recorded_at` | UTC timestamp of that run |

On every successful verify, the script updates `last_seconds` and `recorded_at`. Commit those changes when they drift (same PR as intentional suite growth, or after a clean baseline run).

## Failure rules

Verify fails when either:

1. **Over budget** — elapsed > `budget_seconds`
2. **Regression** — elapsed > `last_seconds × 1.5` (override with `VERIFY_REGRESSION_FACTOR`)

Fix the slowdown, or raise `budget_seconds` / `last_seconds` when the suite legitimately grew (e.g. new tests).

## Commands

```bash
zig build verify      # gate (timed)
zig build verify-run  # work only — no timing check
```

Override regression sensitivity:

```bash
VERIFY_REGRESSION_FACTOR=2.0 zig build verify
```
