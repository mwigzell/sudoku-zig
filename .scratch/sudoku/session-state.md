[2026-07-15] TDD Cycle 1 — Issue #14: Logger Subsystem

Red -> green on base factory shape. `Logger(comptime scope: anytype) type { return struct { ... }}`.
Routes through std.log default formatter, comptime-gated below threshold via std.log.logEnabled().

## What we learned
@src() works inside function body with `const src = @src();` and resolves to caller's file/line correctly.
Zig 0.17 dev rejects `@src()` as a default parameter value (parser error: expected ',' after parameter).

## Current state
28 tests passing. Logger module has a .debug() method wired with comptime scope gating.

## Remaining acceptance criteria from issue #14:
1. [x] Logger factory with comptime-scoped tagging
2. [ ] Wire custom logFn for format: `[LEVEL] [scope_tag] file.zig:LL - message`
3. [ ] Add remaining severity methods: .err(), .warn().info()  
4. [ ] Implement .fatal() with stack dump + abort (noreturn)
5. [ ] Added opt-in `stack bool = false` named param to all non-fatal methods
6. [ ] Integration test with GameEngine logging at least two messages as spec'd

## Next: Cycle 2 — custom logFn formatting wired through std.options.logF
