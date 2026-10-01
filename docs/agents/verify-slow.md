# Verify-slow gate

Costly tests that must **not** run on every `zig build verify` — e.g. live puzzle generation (`countSolutions` during carve).

## Commands

```bash
zig build verify-slow      # timed gate (delivery / pre-release)
zig build verify-slow-run  # run slow tests only — no timing check
```

Timing uses `docs/verify-slow-timing.json` and `scripts/verify-slow-gate.sh` (same rules as `docs/agents/verify-timing.md`).

**Wall bound:** the gate wraps the suite in `run-with-timeout.sh` — default **45s** total (`VERIFY_SLOW_WALL_SECONDS` to override). Expect ~2–15s when generation is healthy; 45s catches runaway carve loops without hanging the agent.

## Adding slow tests

- Root file **not** imported from `src/main.zig` (same rule as other opt-in suites).
- Entry today: `src/puzzle_gen/live.zig` — generator uniqueness, givens band, consecutive outputs differ.

Manual equivalent:

```bash
zig test src/puzzle_gen/live.zig -lc --test-filter 'puzzle_gen live'
```

Override regression sensitivity:

```bash
VERIFY_SLOW_REGRESSION_FACTOR=2.0 zig build verify-slow
```
