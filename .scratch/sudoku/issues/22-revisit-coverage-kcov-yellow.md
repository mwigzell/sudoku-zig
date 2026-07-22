
## Working mode

Refactor / test improvement.

## Preamble

kcov reports 100% for nearly every module, but the HTML view shows yellow lines instead of all green. Yellow = branch not exercised, even though the line itself executed. The JSON `percent_covered` only counts lines, so it lies.

Root cause: kcov's `--dump-summary` is line-granularity; the browser view is branch-granularity. Zig's inline assertion intrinsics (`std.testing.expectEqual`, etc.) embed conditional branches that show yellow when their failure paths never fire — which is expected behavior but still visual noise.

## Scope

- Decide: accept yellow on assertion-only lines as expected, or restructure test code so each expect/assert is a single basic block
- If accepting: document the convention clearly
- If restructuring: audit test files and reduce conditional branches in assertions
- Re-run `zig build cov` and confirm browser view is all green (except intentionally skipped failure paths)

## Acceptance criteria

- [ ] kcov HTML shows green across the board (no yellow)
- [ ] JSON percent_covered numbers no longer lie by omission vs. browser truth
- [ ] Decision documented: what counts as "covered" and what we accept as untestable

## Blocked by

(none)
