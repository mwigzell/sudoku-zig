# Agent Configuration

## Key project locations

- Issues: `.scratch/sudoku/issues/` — one markdown file per ticket, `triage:` + optional `status:` in header
- Source modules: `src/{board,engine,command,renderer}/` — domain packages with co-located tests
- Docs: `docs/adr/` (architectural decisions), other reference docs live under `docs/`

## Development Approach — Vertical Slicing First

When proposing work or building features, prioritise end-to-end completeness over depth:

1. **Start from `main()`.** Every cycle's target should be: "can I demo this in the running binary?" If yes, that's the goal. If no, the gap is what we close.
2. **No stubs.** Wire real implementations end-to-end before perfecting one layer. A working loop at low fidelity beats a polished module nobody calls.
3. **Mocks are scaffolding with expiry dates.** Every mock should have a clear path to being replaced by (or retired alongside) its real counterpart. Prefer thin real types over deep abstractions when the flow is simple.
4. **Wider than deeper.** Touch all layers once before perfecting any single layer. Tests exercise the same code paths `main()` uses — not wrapper functions only tests call.
5. **Each cycle produces a runnable demo.** Even two commands working end-to-end, proven by `zig build run`.

## Zig version & stdlib notes

We are on **Zig 0.17** (dev snapshot). Consult `docs/zig-testing.md` for the stdlib API surface
(Io, testing, build system changes) **before** searching stdlib source files with grep.
The zig stdlib source hierarchy is at /home/mark/.local/tools/zig-latest/lib/std/
### Zig 0.17 changed interfaces from older Zig versions
See ~/Documents/Obsidian/Zig 0.17 Code Guide.md. Covers:
 - The Io threading model — every I/O call takes an explicit handle
 - Production entry point — main(init: std.process.Init) → init.io
 - Testing pattern — std.testing.io + Io.Dir.cwd()
 - Dir API — create, open, stat, delete, walk (all take io)
 - Writer methods cheat sheet — writeAll, writeInt, print via interface
 - Before→After migration table — std.fs.cwd() → Io.Dir.cwd() etc.
 - Common gotchas — fake convenience functions that don't exist, buffer requirements
 - Build system 0.17 changes — configure/maker split, no more b.args
 - cross-referenced against actual stdlib source at /home/mark/.local/tools/zig-latest/lib/std/Io/.

### Local working example: Ziglings
`~/Dev/src/ziglings/exercises/` contains solved exercises against the same 0.17 toolchain.
Use as reference before guessing at syntax — especially `std.Io.Writer`, file I/O, and formatting:
- `026_hello2.zig` — Standard Out via `Io.File.stdout().writer(io, &buf)` + `.interface`
- `034_quiz4.zig` — Error handling with stdin/stdout writers
- `102_formatting.zig` — Number/string formatting with Io.Writer

## Agent skills

### Issue tracker

Local markdown issues live under `.scratch/sudoku/issues/`. No external remote or PR triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

- **Issue Status lifecycle**: triage labels above are pre-work roles only. After an issue is complete and acceptance criteria verified, set `Status: closed` — "closed" is a life-cycle state, not a triage role.

### Domain docs

Single-context. `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Test-suite discipline (root.zig)

`src/root.zig` is the test discovery entry point — it imports every sub-module with co-located tests and references them in the root `test {}` block so Zig's test runner discovers all blocks.

Whenever you create a new source file or rewrite an existing one that contains inline `test { ... }` blocks, **you must also update `src/root.zig`**:
1. Add `const <module> = @import("<module>.zig");`
2. Reference the imported object inside the root `test` block tuple (e.g. `_ = .{ ..., <module>, ... };`) so it is linked and not stripped.

Failure to do this means your tests are invisible to the test runner. Always verify after changes by running `zig test src/grid.zig` (or the relevant file) and confirming all expected tests appear.

## clean "nuke" build cache 
zig build clean
-- **DO NOT** run "rm -rf .zig-cache kcov-out"

### Coverage discipline (`zig build cov`)
Coverage report lives in this project's build system. After every cycle, run:
```bash
zig build cov
```
at `/home/mark/Dev/src/sudoku/`. This runs all 16+ tests and produces JSON showing per-file `percent_covered`. Use it to spot untested code after each change.
## run build
zig build run
- expect that the output is a message and an ascii cell matrix of the initial puzzle.
## run test
zig build test
or
zig test src/root.zig -lc
- don't pass --summary it does nothing
- for full console output (not server-mode) use the `zig test` form above
- to filter a single test: `zig build test -Dtest-filter='exact test name'` (hyphen, not underscore)
## zig version
zig -version
