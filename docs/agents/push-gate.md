# Push gate

`zig build push-gate` runs `scripts/push-gate.sh`: every lane a push must prove, cheapest first,
stopped at the first failure. **This is the only way to push** — the push happens after the gate
passes, never before it, so a red push gate is the "PR red" case: fix, commit, rerun.

`scripts/push-gate.sh` is the script form, for a push made outside the build.

## Lanes

| # | Lane | Command | Why it is here |
|---|------|---------|----------------|
| 1 | `verify` | `zig build verify` | the cycle gate: tests, formatting, standards, coverage |
| 2 | `verify-slow` | `zig build verify-slow` | the costly suites `verify` leaves out (see `docs/agents/verify-slow.md`) |
| 3 | `android-device` | `zig build android-test` | the whole device suite, unfiltered |

The order is by cost, and a lane that fails stops the run: a later lane cannot turn a failure green,
and the device lane is the one that costs minutes.

The device lane is the **full** suite, never a `-Dtest-filter` run: a filtered run proves a method,
which is what the close gate requires of a branch, not what a push requires of the commit it lands.
The device lane starts its own emulator — `scripts/android-emulator-start.sh` — and waits for it to boot,
then runs the suite. `ANDROID_SERIAL` names which device when several are attached; a device that fails to
boot **fails** the gate, and a run is never skipped.
`zig build verify` stays device-free — this gate is the only place the toolchain reaches a device.

## Record

Each run writes `.push-gate/<commit>.json` (untracked), failure included:

```json
{
  "commit": "<sha the gate ran on>",
  "result": "passed",
  "at": "2026-01-01T00:00:00Z",
  "coverage_percent": 89.03,
  "lanes": [
    { "name": "verify", "command": "zig build verify", "status": "passed", "duration_s": 94 }
  ]
}
```

`coverage_percent` is the overall covered-lines percentage the verify lane's kcov run reported,
or `null` when no coverage summary exists (an overridden verify lane does not produce one).

`result` is `passed` only when every lane passed. Each lane's `status` is `passed`, `failed` or
`skipped`: a lane after the failing one is `skipped`, because the run already stopped. A failed lane
still leaves its record, so a red push has evidence of which lane failed rather than a transcript.

## Overrides

The lane commands are read from `PUSH_GATE_VERIFY_CMD`, `PUSH_GATE_SLOW_CMD` and
`PUSH_GATE_DEVICE_CMD`, the record directory from `PUSH_GATE_RECORD_DIR`, and the coverage
summary path from `PUSH_GATE_COVERAGE_JSON`. The gate's own suite
(`.sandcastle/push_gate.test.mts`, part of `zig build verify`) uses them to prove the order, the
stop and the record without a device; they exist for that, not for choosing a cheaper push.

`zig build push-gate -- --lanes` prints the lane table and runs nothing.
