triage: needs-triage

## Code comment policy pass — signposts, not citations

**Rule (already codified in `AGENTS.md` § Code comments):** comments orient the reader
— what seam is this, why does the code exist. Short, 1–3 lines. **Zero** issue/handoff/
session/date references in code, including test headers. Code is the source of truth;
issues are historical and must not need maintaining.

## Axis A — strip external anchors (concrete checklist, audited 2026-08-16)

~26 comments across 9 files reference `Issue N` / `Step N` / `chunk N`. Rewrite each to
state what the code *does*, or delete if the code is self-explanatory:

- `sudoku.zig` — 7 test-section headers: `Step 7 test placeholder`, `Issue 32 — full
  round-trip…`, `Step 10 — Save/Open must route…`, `Step 12b — Subsequent saves…`,
  `Issue 34 Step 2 — e2e: save_as…`, `Issue 34 Step 3 — e2e: new command…`,
  `Issue 45 Step 4 — verify factory delegation…`
- `engine/game_engine.zig` — 4: `(Step 5)` inline, `Step 2 — MutationHistory struct tests`,
  `Step 6 — remaining integration tests`, `Issue 28 Step 4 — Cycle 3` ×2,
  `Issue 28 Step 1 — io threaded through…`
- `engine/save_format.zig` — 3 test headers: `Step 6 — save → open round-trip…`,
  `Step 3 — SaveFileHeader & SaveFileTrailer…`, `Step 4 — toSaveFormat/fromSaveFormat…`
- `engine/mutation_history.zig` — 1: `MutationHistory unit tests (co-located, Step 2)`
- `renderer/ascii_renderer_alloc.zig:14` — doc comment on `makeFacade` says
  "the mock path owns its own (chunk 4 moves it into the session)" — stale future-tense;
  mock path now *borrows* the session writer (chunk 4 landed). Rewrite to describe the
  current split: prod borrows session writer, mock branch borrows the mock buffer.
- `renderer/ascii_renderer_alloc.zig:14` `makeFacade` doc and `buildContext` doc —
  verify they match post-chunk-4 reality while you're there
- `renderer/ascii/ascii_renderer.zig:14` — "Implements the Renderer Facade vtable
  (Issue 29)…" → drop the citation, keep the orientation ("Implements the Facade vtable
  so the same game loop works over ASCII and other renderers")
- `renderer/ascii/parser.zig:8` — "Re-export domain types … (until Step 3 switches
  imports)" → stale; re-export is permanent by now, drop the expiry clause
- `command.zig:38` — "Comptime command registration table (Issue 30)" → drop the citation
- `io_session.zig:4` — "Issue 47 chunk 3 — WriterSource + IoSession (spec: issue-47
  sketch)" → drop, keep one-line description

Re-verify after the pass: `grep -rn 'Issue [0-9]\|issue-[0-9]\|Step [0-9]\|chunk [0-9]'
src/ --include='*.zig'` must return **zero** hits in comments.

## Axis B — fill the signpost gap (coverage audit)

Per-file pass over `src/**/*.zig` (main.zig, sudoku.zig, io_session.zig,
board.zig, engine/*.zig, command*.zig/, renderer/*.zig) adding **missing** comments only:

- File-header line: one sentence of what the module is and which seam it owns
- Structs: one line each — why it exists, who owns what (already present on some —
  `ProdFacadeContext`/`MockFacadeContext` have field-level notes; keep those)
- Public methods: one line each on non-obvious ones; skip trivially named pass-throughs
- Important code blocks (arena wiring, vtable bridging, error-set mapping): one line of
  *why*, not *what*

Constraint from AGENTS.md: describe what the code **is**; never what once changed it.

## Acceptance criteria

- [ ] `grep -rn 'Issue [0-9]\|issue-[0-9]\|Step [0-9]\|chunk [0-9]' src/ --include='*.zig'` → zero hits
- [ ] No future-tense TODO-style sentences in comments that describe already-landed work
- [ ] `zig build test` green (full suite)
- [ ] `echo quit | zig build run` smoke exits 0 (main() lazy semantic analysis — see AGENTS.md)
- [ ] `zig build test` after touching any file in `main.zig`'s import graph (test discovery caveat, AGENTS.md)

## Constraints

- HITL: one file at a time, stop for confirmation at each file boundary
- Never set `triage:` or `Status:` lines without explicit user instruction
- Comment-only changes expected; **no code behaviour changes**. If a comment reveals an
  actual bug, stop, report to user, do not fix in-place
- Small `edit` ops with fresh `LINE#HASH` anchors; no full-file rewrites
- `zig build clean` for cache, never `rm -rf .zig-cache`
