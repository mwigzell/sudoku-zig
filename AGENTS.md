# Agent Configuration

## Agent skills

### Issue tracker

Local markdown issues live under `.scratch/<feature>/`. No external remote or PR triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Test-suite discipline (root.zig)

`src/root.zig` is the test discovery entry point — it imports every sub-module with co-located tests and references them in the root `test {}` block so Zig's test runner discovers all blocks.

Whenever you create a new source file or rewrite an existing one that contains inline `test { ... }` blocks, **you must also update `src/root.zig`**:
1. Add `const <module> = @import("<module>.zig");`
2. Reference the imported object inside the root `test` block tuple (e.g. `_ = .{ ..., <module>, ... };`) so it is linked and not stripped.

Failure to do this means your tests are invisible to the test runner. Always verify after changes by running `zig test src/grid.zig` (or the relevant file) and confirming all expected tests appear.
