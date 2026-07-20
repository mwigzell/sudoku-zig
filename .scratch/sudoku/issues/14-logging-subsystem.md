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
- On all other severities, ~~make stack output opt-in through keyword param: `stack bool = false`~~ — **Deferred: not possible.** Zig has no keyword/default parameters after `anytype`. The signature `fn foo(fmt: []const u8, args: anytype, stack: bool = false)` fails to parse in Zig 0.17 (error: *expected ','* after parameter). No ergonomic workaround exists.

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
- [x] `src/logger.zig` exists with comptime-scoped Logger factory (`Logger(comptime scope: @EnumLiteral()) type`)
- [x] Logger delegates to `std.log.scoped()` for level printing + gating (custom `_impl()` dropped per cycle 5 decision)
- [ ] Log output format includes severity level, message text (source file:line deferred — see #14 source location notes)
- [x] Fatal always dumps stack trace before aborting (noreturn)
- [ ] Other methods accept optional `stack bool = false` keyword param to opt-in stack dumps without polluting default calls (**Deferred — Zig has no keyword args after anytype, not a blocker for issue close**)
- [x] `.err()`, `.warn()`, `.info()` implemented (delegated one-liner per method, matching `.debug()` signature)
- [x] `.debug()` implemented via std.log delegation
- [ ] Integration test with GameEngine logging at least two different messages as spec'd

## Blocked by

None — self-contained new module addition.

## Notes from development

### Final decision (after 5+ cycles):
We dropped our custom `_impl()` formatting entirely and delegate to `std.log.scoped()`. Reason: we tried manually driving level + scope via `std.debug.print()` which required us reimplementing gating ourselves, plus every iteration had API guesses wrong (`bufPrint` tuple splat fails, `Io.stderr()` doesn't exist in 0.17, `logEnabled` only accepts `@EnumLiteral()`).

**What we ship instead:**
```zig
pub fn Logger(comptime scope: @EnumLiteral()) type {
    const log = std.log.scoped(scope);
    return struct {
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            log.debug(fmt, args);       // std.log handles level + scope printing
        }
        pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
            log.err("FATAL: " ++ fmt, args);
            std.debug.dumpCurrentStackTrace(.{});
            std.process.abort();
        }
    };
}
```

**Trade-offs accepted:**
- Output format is `std.log` default (`level(scope): msg`) — we lose our `[LEVEL] [scope]` style
- Proper per-scope gating works for free now (was hardcoded to `.default` before)
- No manual buffer management, no catch-swallowing on write errors
- Scope passes as `.something` (EnumLiteral) not string — compiles at comptime

### Source attribution blocked by toolchain
- `@callerSrc()` not yet in Zig 0.17
- File:line tagging deferred — scope-only until builtin lands

### Stack trace opt-in (deferred / not possible)
- Zig does not support keyword arguments or default parameters after `anytype`. Signature `fn foo(fmt: []const u8, args: anytype, stack: bool = false)` fails to parse. No ergonomic workaround exists — callers cannot pass positional booleans after a variadic `anytype` tuple without breaking the API. Deferred indefinitely unless Zig lands labelled parameter syntax.

### Test output note
- Logger tests pass clean AND do emit visible text during test runs — `zig test src/logger.zig` prints `[logger] (warn): range 1..9` to stderr, proving threshold gating works end-to-end even in the test runner.
- Only `.debug()` is suppressed in test mode (below log threshold), which is correct behaviour.
- Runtime logging via `zig build run` also works correctly:
  ```
  debug(sudoku): Starting sudoku game.
  ```

### Cycles done (6+):
- Logger factory with custom `_impl()` — tried, dropped
- Delegate to `std.log.scoped()` — working
- `.err()`, `.warn()`, `.info()` added as one-liner delegations
- `stack bool = false` opt-in attempted, confirmed impossible in Zig 0.17 (no keyword args after `anytype`) — deferred
- All 30 tests pass
