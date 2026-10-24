# Verify-slow gate

Costly tests that must **not** run on every `zig build verify` — e.g. live puzzle generation (`countSolutions` during carve).

## Commands

```bash
zig build verify-slow      # timed gate (delivery / pre-release)
zig build verify-slow-run  # run slow tests only — no timing check
```

Timing uses `docs/verify-slow-timing.json` and `scripts/verify-slow-gate.sh` (same rules as `docs/agents/verify-timing.md`).

**Wall bound:** the gate wraps the suite in `run-with-timeout.sh` — default **90s** total (`VERIFY_SLOW_WALL_SECONDS` to override). Healthy runs are machine-dependent (a few seconds to the high tens of seconds); the `budget_seconds` ceiling in `docs/verify-slow-timing.json` is the pass/fail line, and the 90s wall just catches runaway carve loops without hanging the agent.

## Adding slow tests

- Root file **not** imported from `src/entry_native.zig` (same rule as other opt-in suites).
- Canonical test entry: `src/entry_verify_slow.zig` (currently imports `src/test/slow/puzzle_gen_live.zig`) — generator uniqueness, givens band, consecutive outputs differ.

Manual equivalent:

```bash
zig test src/entry_verify_slow.zig -lc --test-filter 'puzzle_gen live'
```

Override regression sensitivity:

```bash
VERIFY_SLOW_REGRESSION_FACTOR=2.0 zig build verify-slow
```
