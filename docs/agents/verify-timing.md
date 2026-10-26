# Verify timing gate

`zig build verify` runs `scripts/verify-gate.sh`, which times `zig build verify-run` with bash's built-in `time` (`TIMEFORMAT='%R'`) and checks `docs/verify-timing.json` with `jq`.

## Tracking file

`docs/verify-timing.json` (committed policy):

| Field | Meaning |
|-------|---------|
| `budget_seconds` | Hard ceiling — verify fails above this |
Last successful run timing is written to local state:
`/.zig-cache/verify-timing-local.json` (untracked).

## Failure rules

Verify fails when either:

1. **Over budget** — elapsed > `budget_seconds`
2. **Regression** — elapsed > `last_seconds × 1.5` (override with `VERIFY_REGRESSION_FACTOR`).
   `last_seconds` comes from local state when present, else falls back to policy file/default budget.

Fix the slowdown, or raise `budget_seconds` when the suite legitimately grew (e.g. new tests).

## Commands

```bash
zig build verify      # gate (timed)
zig build verify-run  # work only — no timing check
```

Override regression sensitivity:

```bash
VERIFY_REGRESSION_FACTOR=2.0 zig build verify
```
