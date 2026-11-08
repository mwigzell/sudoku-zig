# Agent Configuration

## Key project locations

- Issues: GitHub (`mwigzell/sudoku-zig`) — open work, triage labels, acceptance criteria
- Source modules: `src/core/{board,engine,renderer}/` + `src/core/command.zig` — domain packages with co-located tests
- Docs: `docs/adr/` (architectural decisions), other reference docs live under `docs/`

## Development Approach — Vertical Slicing First

When proposing work or building features, prioritise end-to-end completeness over depth:

1. **Start from `main()`.** Every cycle's target should be: "can I demo this in the running binary?" If yes, that's the goal. If no, the gap is what we close.
2. **No stubs.** Wire real implementations end-to-end before perfecting one layer. A working loop at low fidelity beats a polished module nobody calls.
3. **Mocks are scaffolding with expiry dates.** Every mock should have a clear path to being replaced by (or retired alongside) its real counterpart. Prefer thin real types over deep abstractions when the flow is simple.
4. **Wider than deeper.** Touch all layers once before perfecting any single layer. Tests exercise the same code paths `main()` uses — not wrapper functions only tests call.
5. **Each cycle produces a runnable demo.** Even two commands working end-to-end, proven by `zig build run`.

## Entry shape — always long-term, not “small app” shortcuts

Repo size or slice size **does not** relax structure. **Do not** tell the user that inline wiring in `entry_native.zig` is “acceptable for a small Zig app” or defer extraction to a follow-up unless they explicitly asked to defer.

**`src/entry_native.zig` is a switchboard only:** resolve startup config (and shared inputs like `data_dir` once), then dispatch to a **thin entry arm** — e.g. `native/desktop_web.zig`, `native/desktop_terminal.zig`, future `android/` JNI. No browser open, no Sudoku loop, no HTTP serve loop, no fat error policy in entry wiring.

**Shared modules stay deployment-agnostic:** `web_host` serves loopback; desktop browser open stays in the entry arm (`open_browser` + ready callback). Callbacks and comments must match reality — if a fn-pointer is passed, document **who calls it on which platform**; never imply it is unused on desktop.

**Public API hygiene:** no unused `pub fn` “for later” without a caller or test; prefer one obvious production path per entry (e.g. desktop web → `desktop_web.run` → `web_host.runWithHostConfig`).

**When adding a second deployment (web vs terminal vs Android):** extract or extend an entry module in the **same change** that introduces the branch — do not grow `main` into a hodgepodge and “clean up later.”

Placement rules: ADR-0011 (N thin entries), `CONTEXT.md` (shell vs `web_host` vs platform entry).

## Multi-front-end policy invariant (enforce)

For this repo's shared-core architecture, **policy centralization is mandatory**.

- Front ends (native shell, web JS, Android host/WebView) are adapters: input/output, lifecycle, presentation.
- Shared seams (engine/startup/host contracts) own policy: rule semantics, save/restore/autosave semantics, startup decisions, and log filtering policy.
- **One log line per event.** Do not log the same event twice (e.g. an adapter logging a failure reason core already logs, or two sinks writing one line to the same host log).
- Do **not** duplicate or fork policy in a front end "for convenience". If a front end appears to need custom behavior, extract or extend a shared seam instead.
- **Text ownership follows the behaviour.** Whoever implements a behaviour writes the words the user sees for it. For engine, flow and generation behaviour that is core: adapters show core's text and pass their technical reason (`err.message`, Zig error names) to core for the log, never into a dialog. A platform writes text only for what it alone implements (e.g. web boot failure before wasm loads). Dialog and status text is always full sentences.

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

Open issues and triage live on **GitHub** (`gh issue list`, `gh issue view N`). See `docs/agents/issue-tracker.md` and `docs/agents/triage-labels.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

- **Every `/triage`** walks the player's screen (`docs/agents/triage-labels.md`, "Before `ready-for-agent`"): controls, states and each pair, per front end in scope, plus the ADR-0018 check on saved data. An issue moves to `ready-for-agent` only when every pair is answered in the issue.

- **Issue lifecycle**: triage labels above are pre-work roles only. When acceptance criteria are verified, tick the boxes and close the GitHub issue — on the working branch, without waiting for a merge to `main` and without asking. If something blocks closing, state the blocker in one line.
- **Front ends**: every issue names native, web and Android, each in scope or out of scope with a reason. An issue closes only when every in-scope front end meets the acceptance criteria. See `docs/agents/issue-tracker.md` ("Front ends in every issue").

### Closed issues are historical

- **Open issue** = spec for the current slice: acceptance criteria define done.
- **Issue closed** (`zig build verify` green + criteria met) = **code is source of truth**; the closed issue is historical, not a living spec.
- **Do not** revert or reshape shipped code to match stale closed-issue, epic, or parent text. Read the running code and tests instead.
- **Do** update open epics and `CONTEXT.md` when they drift from shipped behaviour — docs catch up to code, not the reverse.

### Domain docs

Single-context. `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Native renderer facade seam

The `Facade` vtable (`src/core/renderer/facade.zig`, ADR-0009) is the **terminal's** renderer seam only. Web and Android do not use it: they draw from core's wasm JSON. It was once meant to be the command API shared by every front end; that never happened, so nothing about it needs to stay frozen for other front ends.

- **Add a method** when a new *kind* of interaction is needed; reshape an existing method when its arguments belong together.
- **Arguments are values core builds for that call.** A struct is the right shape when its fields travel together (one draw's state, the current Config); a long list of scalars that always move as a group is a smell (see "Shotgun plumbing" below).
- **The renderer holds no pointer to core state** and gets no hooks pushing changes to it; it receives values per call and returns the player's input. `getCommandInput` and the menus take a copy of `Config` per call; the renderer may import core's read-only config table (`src/core/config_table.zig`) for labels and choices.
- **Product rule:** every Config field in `config.json` is editable in Settings on each supported platform; every Settings menu is drawn from core's config table and every change is one `set_config { field, value }`. Adding a field touches only `Config` and the config table in production code. Renderer choice is **not** in that file — use CLI (`-r`) per run.

## Coding standards

### Code quality
1. **Document public surfaces.** Every public function must have a header comment explaining its purpose, parameters, and return value. Every public struct must document what it represents and the role of each field.
   - **HARD RULE (MANDATORY):** No undocumented public symbol is allowed in committed code. This applies to `pub fn`, `pub const` type declarations, and public fields that are not self-evident.
   - **HARD RULE (MANDATORY):** Any non-obvious logic block added or modified must include a short signpost comment explaining intent/constraint (what and why, not line-by-line narration).
2. **DRY** — Don't repeat yourself. Extract duplication into shared helpers or functions as soon as repetition is obvious. No copy-paste logic; if two renderers share code, it lives in one place.
 - **Shotgun plumbing is a smell — say so.** When a change edits several files the same mechanical way (one more argument, field, command tag or JSON key carried through each layer), stop before finishing it and tell the user, with the count (`rg -l <name> src | wc -l`). Propose the missing vehicle (one value carried end to end) even when the rule being followed requires the plumbing; do not widen the current issue without asking.
3. **SOLID principles:**
   - **S**ingle Responsibility — a module has one reason to change. GameEngine orchestrates commands; Validator checks rules; Renderer draws output. Keep these roles distinct.
   - **O**pen/Closed — extend behavior by adding new implementations (renderers, puzzle sources), not modifying existing ones. When duplication exists, abstract behind interfaces.
   - **L**iskov Substitution — any concrete renderer must fulfill the interface contract completely without the caller needing to know which implementation it is.
   - **I**nterface Segregation — small, focused interfaces with no unused fields or methods. Interfaces are extracted only when two consumers exist (abstractions earned by duplication, never stubbed).
   - **D**ependency Inversion — depend on abstractions, not implementations. High-level policies (GameEngine) do not import rendering details; low-level renderers are injected at runtime.
4. **No magic numbers.** Hard-coded values must be pulled out into named constants or configuration structs at the appropriate scope level. Prefer `const GRID_SIZE: u8 = 9` to a random bare literal, with a descriptive name that explains what it represents.
5. **Constructors are pure.** A constructor (`init`, `fromX`, etc.) only sets fields and returns the object. No rendering, no logging, no mutation of external state, no hidden behaviour. The caller controls when and how side effects happen.
6. **Nothing is silent**: every caught error is logged with its system message (`@errorName(err)`, `err.message`, `e.toString()`), whether or not the user is told. An expected error, part of normal processing, is logged at info as `expected: <why> (<system message>)`; any other at warn or err. A line that cannot reach the host log goes to the console (JS) or stderr (Zig) instead. `scripts/verify-standards.sh` flags new silent catches.
7. **no God classes**: do not make huge multi-page functions or switch statements. Modularize early so the structure is easy to discern.
8. **Clean** code style.
9. **Central plumbing is mandatory (hard rule).**
   - **HARD RULE (MANDATORY):** Cross-platform behavior policy lives in core modules only (e.g. startup policy, save/restore policy, defaults, user-facing status text, wire-contract fields).
   - **HARD RULE (MANDATORY):** Platform adapters (`src/native/**`, `src/wasm/**`, `src/android/**`) may adapt capabilities only (I/O APIs, picker/clipboard/bridge plumbing, rendering mechanics); they must not define independent policy semantics.
   - **HARD RULE (MANDATORY):** If behavior must match across platforms, define it once in core and pass it through shared contracts; never duplicate policy constants/messages per platform.
   - **HARD RULE (MANDATORY):** Any exception must be documented inline with a one-line rationale proving it is transport/UI capability only, not business policy.
   - **HARD RULE (MANDATORY):** Status message authorship is core-owned. Adapters must not invent fallback status copy for core flows (startup/new/open/save/import/autosave).
   - **HARD RULE (MANDATORY):** Durable status lifecycle (`set|preserve|clear`) is decided in core seams only; adapters render/pass through only.
   - **HARD RULE (MANDATORY):** Startup restore must use the core restore lane (persisted status continuity), not generic open-with-label behavior.
10. **Web modules import each other by namespace.** In `src/wasm/`, `import * as statusBar from "./status_bar.js"`, so a call site reads `statusBar.applyEventStatus(...)`. The namespace is the file name in camelCase; when that clashes with a local name, add `Mod` (`sessionMod`, as Zig uses `storage_mod`).

### Test / SUT colocated (Ziglings 105 style)
- Test blocks are colocated with the code being tested.
- Use inline `test { ... }` blocks within the same source file as the production code they exercise.
- Build step (`zig build test`) must compile and run all tests alongside the root module so every seam is exercised.

### Clean compilation & lint discipline
- Zero warnings: every zig compiler warning or lint finding must be addressed cleanly — never ignored.
- If a legitimate use requires bypassing a lint rule, apply an explicit scoped suppression annotation (e.g. `// Allow unused`) with a one-line reason; no blanket ignores.
- Builds that produce any warnings are considered broken.

### TDD methodology (issue role: ready-for-human HITL — Human In The Loop)
- TDD is either as the role ready-for-agent (AFK) or ready-for-human (HITL)
- AFK: Away from keyboard - agent works autononmously till done.
- HITL: Human in the loop
*The user is the architect; the agent is the junior coder. This project's goal is learning Zig.*

- **One cycle per session.** One test, one minimal code addition, stop. Always pause after a single red→green cycle.
- Never write huge chunks of code. Keep functions small and manageable.
- Before starting any work, enumerate your plan so the user knows what you are planning and where you are.
- Do not keep an internal numbered list ("2a", "2b") and run through it AFK. Every iteration requires explicit user direction to proceed.
- If you hit a blocker, halt immediately — do not loop trying multiple approaches.
- After every cycle, write current session state to disk (`.scratch/sudoku/session-state.md`) then wait for human instructions before proceeding.
- Check back with the architect regularly. Explain _why_ choices are made so the user learns Zig along the way.
- The user has the right to `/handoff` or change direction between every cycle.
- obey Steering directions immediately: context window is limited.

## Code comments

Comments are **signposts, not citations**.
- File, struct, and method comments orient the reader: what seam is this, why does it exist. Short — 1–3 lines.
- Import blocks should carry a one-line note of the module's role.
- **Never** reference issues, handoffs, sessions, or dates from code: no `Issue N`, `Step N`, `chunk N`, no `spec: issue-XX`, **including test headers**.
- If a comment describes *intended* behaviour ("will move to…", "chunk 4 adds…") it is stale the moment it is written — describe what the code *is*, not what once changed it.
- Code is the source of truth; **closed** issues are historical and must not need maintaining.

## JS typing/readability rule

When editing web-shell JavaScript (`src/wasm/**/*.js`), maintain JSDoc typing for navigation and reviewability.

- Prefer shared typedef aliases (for example via `src/wasm/types.d.ts`) over repeated ad-hoc object shapes.
- Public seam functions should have `@param`/`@returns` annotations when type intent is not obvious.
- Replace broad `any` placeholders in option objects with named typedefs when feasible.
- Keep types aligned with the real boundary contracts (`glue.js`, wasm action/config payloads); do not invent parallel schemas.

## Test-suite discipline

Test discovery uses **`src/entry_native.zig`** as the entry point (there is no `src/root.zig` — it was removed in commit 02f55d8). Zig's test runner follows the **transitive import graph**: every `test {}` block in any module reachable from `entry_native.zig`'s imports is discovered and linked — no manual tuple or central registration file is needed.

Caveat: a new source file with tests is only visible if it is **imported by something in entry_native.zig's graph**. If you add `src/foo.zig` with tests and it isn't imported by an existing module, its tests are silently skipped. Make sure it is reachable from the domain (e.g. imported by `native/shell/shell.zig` or another module), and verify with `zig build test` that the new tests actually run.

### Tests use the text's constant, not a copy

A test that checks user-facing text compares against the owner's constant or formatter (Zig `*_MSG`/`*_FMT`, `formatProgressEvent`; JS reads core's text through wasm: `test_support.coreText.X`, `fillText(coreText.X_FMT, …)`, `genText`; add a constant to `boundary.writeCoreTextJson` when a JS test needs it). Spell a sentence out only in the one test that pins the wording itself. Tests that only check placement or plumbing pass neutral placeholders (`"progress line 1"`), not copies of core's sentences.

## clean "nuke" build cache 
zig build clean
-- **DO NOT** run "rm -rf .zig-cache kcov-out"

### Verify gate (`zig build verify`)
Every cycle gate lives in the build as a single command so task-local checklists can't shadow it. After every cycle, run:
```bash
zig build verify
```
at `/home/mark/Dev/src/sudoku/`. Runs all tests + `zig fmt --check` + **standards** (`scripts/verify-standards.sh` on the branch diff vs `origin/main`) + coverage, and dumps the per-file `percent_covered` JSON (kcov) alongside. See `docs/agents/verify-standards.md`. **Timing:** `scripts/verify-gate.sh` enforces `docs/verify-timing.json` policy (budget + regression); last successful run timing is written to local untracked state under `.zig-cache/`. See `docs/agents/verify-timing.md`. **Slow (delivery):** `zig build verify-slow` — costly suites via `src/entry_verify_slow.zig` (currently includes live generator properties in `src/test/slow/puzzle_gen_live.zig`); timed via `docs/verify-slow-timing.json` with local timing state in `.zig-cache/`. See `docs/agents/verify-slow.md`. Not part of `verify`. Verify stays report-only; `zig build cov` regenerates the report and opens it in the browser; `zig build cov-report` is the report-only target (no browser).
## run build
zig build run
- expect that the output is a message and an ascii cell matrix of the initial puzzle.
- web UI: `zig build web` or `zig build run -- -r web` (run step uses `addPassthruArgs` on 0.17).
### Web menubar drag-release (do not regress)

Classic menubar: **mousedown** menu title → drag → **mouseup** on item. Implemented in `src/wasm/menus/menu_bar.js` (`wireMenuDropdowns`).

- **Trigger `mousedown` uses `preventDefault()`** so the menu opens and drag-across titles works. That **suppresses the native `click`** on the item you release over. **Click-then-click on items still works**; drag-release does **not** without extra wiring.
- **Fix:** while `barDragging`, on **document capture `mouseup`**, use **`elementFromPoint(clientX, clientY)`** (not `event.target` — target often stays the **trigger**), find a **`.menu-panel` button** (menuitem / menuitemradio / menuitemcheckbox), then **`item.click()`**. File/Edit handlers stay **per-button `click` listeners** (`file_menu.js`, `menu.js`).
- **Do not** “fix” drag by only moving Edit to panel delegation + `elementFromPoint` on the synthetic click (clientX/Y **0** hits the wrong node). **Do not** skip synthesis when `target === item under pointer` — after a trigger drag they differ.
- Contract test: `src/wasm/menus/menu_bar.test.mjs` (File → New drag-release).

## run test
zig build test
or
zig test src/entry_native.zig -lc
- don't pass --summary it does nothing
- for full console output (not server-mode) use the `zig test` form above
- **`zig build verify` is the gate and runs every test.** A test counts as passing only from a run whose output shows its name.
- **Never filter from `src/entry_native.zig`** (`-Dtest-filter`, `--test-filter`): a file's tests are only found when a running test calls into it, so a filter can match nothing and still exit 0. `-Dtest-filter` is for single `android-test` methods.
- **One Zig test on its own:** a temporary root in `src/` that imports the test's file (a root inside a subfolder cannot import `../`), e.g. `src/_one_test.zig` with `test { _ = @import("core/engine/pencil.zig"); }`, then `zig test src/_one_test.zig -lc --test-filter "<name>"`; check the name in the output, then delete the root.
## zig version
zig -version
# ANSWERING
When reporting information to me be extremely concise and sacrifice grammar for the sake of concision.
