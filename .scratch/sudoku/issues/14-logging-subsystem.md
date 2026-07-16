Status: in-progress

## Working mode
HITL (Human In The Loop). One TDD cycle per session. Agent enumerates its plan, does one iteration, pauses for explicit direction before proceeding. See `.coding-standards.md` → "TDD methodology (HITL)".

## Parent

`.scratch/sudoku/prd.md`

## What to build

Lightweight logging infrastructure built on top of Zig's standard `std.log` system rather than rolling our own. Provides a thin wrapper producing per-module scoped/tagged Logger instances that attach file, line number, and scope qualifiers to every log message through comptime-captured source attribution at each call site.

### Concretely (what lands on disk)

- Create `src/logger.zig`
- Define a comptime-scoped factory: `Logger(comptime scope: anytype) type` producing a struct with severity methods: `.fatal()`, `.err()`, `.warn()`, `.info()`, `.debug()`
- ### Source location (deferred)

Zig 0.17 lacks the `@callerSrc()` builtin that would let a generic wrapper capture the call site's file:line by default. Current workarounds (explicit src param, body-level `const src = @src()`) both fail — see Notes from development.

When/if `@callerSrc()` lands we can add file:line back to every log line automatically. Until then we use scope-only tagging; callers that need more context bake extra detail into the format string.
- Format per emitted log line (example): `[LEVEL] [scope_tag] file.zig:42 — message text`

### Stack trace handling

- On `fatal()` **always** dump the stack automatically via `std.debug.dumpStackTrace()` and then `os.abort()`. Fatal never returns.
- On all other severities, make stack output opt-in through keyword param: `stack bool = false`. Defaults to false so normal calls stay noise-free.

### Severity gating & threshold control

Rely entirely on `std.log`'s built-in severity system and thresholds. No custom filtering logic — Zig's stdlib already knows how to do this right.

```zig
// wired in main() / config phase:
const MyLog = logger.Logger(.GameEngine); // comptime-scoped, baked into type
```

### Per-module tagging pattern

Each consuming module gets its own comptime-scoped Logger type:

```zig
const MyLog = mylog.Logger(.GameEngine); // comptime-baked scope tag
var log: MyLog = undefined; // placeholder until wired in main()
pub fn set_logger(l: MyLog) void { log = l };
```

Wired during startup so no process-level globals exist outside factory scope.
Comptime `scope` keeps threshold gating efficient — below-threshold calls prune at compile time, zero runtime cost.

### Integration test / demo seam

Prove the end-to-end path works by having **GameEngine** log at least two different messages (e.g. `log.info("fill command processed for cell 3,5")` and `log.err("invalid digit value")`) and verify that:
- Output carries correct scope tag ("GameEngine"), timestamp, file (game_engine.zig), line numbers
- Threshold gating works (lower severity messages suppressed)
- Fatal path actually dumps stack + aborts (exercise in test or separate binary step if needed — your call on safe testability under Zig's std server model)

## Acceptance criteria

- [x] `src/logger.zig` exists with comptime-scoped Logger factory (`Logger(comptime scope: anytype) type`)
- [ ] Log output format includes: severity level, message text (source file:line deferred — see #14 source location notes)
- [x] Fatal always dumps stack trace before aborting (noreturn)
- [ ] Other methods accept optional `stack bool = false` keyword param to opt-in stack dumps without polluting default calls
- [x] `.debug()`, `.err()`, `.warn()`, `.info()` implemented via shared `_impl()`
- [x] `.fatal()` implemented (noreturn, stack dump + abort)
- [ ] Integration test with GameEngine logging at least two different messages as spec'd

## Blocked by

None — self-contained new module addition.

## Notes from development

Zig 0.17-dev (build system uses server-mode IPC for testing).

### Source attribution blocked by toolchain
- `@src()` inside generic methods resolves to definition line, not call site
- `@src()` as default param value is rejected by compiler (`expected ',' after parameter`)
- **Resolution:** use scope-only tagging now; `@callerSrc()` builtin will fix when/if it lands
- Callers that need file:line can bake it into the format string manually for now

### Cycles done (3):
- Logger factory with shared `_impl()`, plus `.debug()`, `.err()`, `.warn()` all working through it
- All tests pass (3/3 logger alone; 30/30 total suite)
- Coverage at ~99%
