# Unpushed Code Review — 111 commits since `origin/main`

**Fixed point:** `origin/main` = `024fcef` (2026-11-10)
**Range:** `git diff origin/main...HEAD` — 111 commits, 116 files, +9771 / −535
**Spec sources (GitHub, local copies in `/tmp/review-specs/`):** #130, #131, #132, #133, #134, #135, #137. #136 is open and not implemented here.
**Standards sources:** `AGENTS.md` ("Coding standards", "Code comments", "Multi-front-end policy invariant", "Test-suite discipline"), `CONTEXT.md`, `docs/agents/*`, `docs/adr/*`, `.sandcastle/CODING_STANDARDS.md`, plus Fowler smell baseline.

**Method:** two standards reviewers (app code; sandcastle/tooling/docs) and one spec reviewer ran in parallel over the diff. Findings below were then spot-verified with probes against the tree; refuted claims are listed at the end so triage does not spend time on them.

---

## Standards

### App code (`src/**`, `build.zig`)

**S1 — Settings *write* refusal worded as *read* refusal. (FIXED 2026-11-16)** — `src/core/startup/config.zig` now treats startup persistence as best-effort: the read already produced a usable config, `writeFailed` logs the reason, and the boot proceeds. `Error.WriteFailed` no longer folds into the read refusal, so Android's read sentence stays true. ADR-0021 decision 3 updated.

**S2 — Comment narrates history. (hard, comment rule)** — `src/android/jni_host.zig:146-149`
"The refusal used to reach Java only when its port poll timed out…" — AGENTS.md "Code comments": describe what the code *is*, never what once changed it.

**S3 — Test lists are hand-enumerated. (judgement, rule reference)** — `build.zig:65` (32-file `node … && node …` shell line), `build.zig:82` (14 `.sandcastle/*.test.mts` paths)
AGENTS.md "Test-suite discipline" warns that a new test file can be silently skipped. Here a new `src/wasm/**/*.test.mjs` or `.sandcastle/*.test.mts` is invisible until someone remembers to edit `build.zig`. Directory discovery (`node --test .sandcastle/`, glob for wasm suites) removes the class.

**S4 — Test scaffolding lives in the shipping Android module. (judgement)** — `src/android/jni_host.zig:197-247`
`startBootForTest`, `finishBoot`, `bootOnThread`, `bootPollSleep`, `testDataDir`, plus `boot_finished` / `BOOT_*` globals, are production code shaped by tests. `src/test/support/` already exists as the home for this.

**S5 — Pin test asserts nothing. (nit)** — `src/android/jni_host.zig` (unnamed `test { _ = .{ web_host, config }; }` near end)
Both modules are already reached by production code in the file.

**S6 — Format-string splice where a join states intent. (nit)** — `src/test/support/memory_transport.zig` `resolve`: `DIR ++ "/{s}"`.

### Sandcastle harness, tooling, docs

**H1 — Ledger default omits a required field. (type-level; runtime recovered)**
`.sandcastle/loop.mts:239` creates `{ issue, ticks: [] }` while `Ledger.criteria` is required (`ledger.mts:21`); 223 and 358 use the full literal. Nothing typechecks (`package.json` test script is `node --test` only), so it ships. Runtime survives because `readLedger` normalises a missing `criteria` to `[]`, but the next write drops the key. Fix with one `emptyLedger(issue)` helper and, ideally, a `tsc --noEmit` gate.

**H2 — `drop` misreports what it took back. (behaviour, destructive op)**
`.sandcastle/drop.mts:30-35`: `positions` is `ledger.ticks ++ ledger.criteria` (`ledger.mts:88`) but the message says "steps", and names only `ledger.issue` although child ticks carry `issue: CHILD` (`loop.mts:224`). The only report of a destructive operation is wrong about both kind and target.

**H3 — Three scripts duplicate 14 lines of branch enumeration. (DRY)** — `scripts/sandcastle-accept.sh:12-25`, `sandcastle-drop.sh:9-22`, `sandcastle-verdict.sh:12-25`, same message ×3, same worktree `awk` (`accept.sh:30-33`, `drop.sh:39-42`). Extract `scripts/lib/sandcastle-run.sh`.

**H4 — Docs contradict the shipped resume lane. (docs drift)** — `docs/agents/sandcastle.md:37` still requires "no earlier run's branch or worktree remains" at preflight, while `main.mts:129-140` resumes an unsettled run and only checks worktrees.

**H5 — `sandcastle-verdict.sh` invokes `.mts` with `node`, others use `npx tsx`.** — `scripts/sandcastle-verdict.sh:47,53`; `.sandcastle/report.mts:78` relies on `import.meta.main`. Works on Node v26.13.1 here; inconsistent/portability risk.

**H6 — Fragile parse of a hand-built status line. (Primitive Obsession)** — `.sandcastle/status.mts:61` parses `^step (\d+)\/(\d+)` out of the message built at `loop.mts:148`; rewording silently yields "none started".

**H7 — Citations in comments. (hard, comment rule)** — `.gitignore:9` (`# Sandcastle trial toolchain (chore/sandcastle)`), `.sandcastle/loop.mts:323` (`(AGENTS.md AC 13)`).

**H8 — Accept/drop script edges. (judgement)** — `scripts/sandcastle-accept.sh:51-54` exits 0 when `accept.mts` fails (prints warning); `drop.sh:29` `read -p` under `set -e` exits silently on EOF, and `worktree remove --force` (`:43`) has no dirty-tree guard while accept refuses one.

**H9 — Missing harness evidence.** No suite for `drop.mts` (absent from the `sandcastle:test` list); no `tsc --noEmit`; `standards.mts readRules` never tested against the real `AGENTS.md`; `status.test.mts:75-78` asserts `dir === null || /\d+$/.test(dir)` — a tautology named "picked by stamp".

---

## Spec

### #130 — Sandcastle harness

- **Stale verdict files can pass a step. (FIXED 2026-11-16)** Each reviewer run now clears its expected verdict paths first (`clearVerdict` in `loop.mts`), including the shared `verdict-acs.json` of a child step and the final review. New test: "a verdict left in the worktree is cleared, so a silent reviewer cannot pass on it" (117 harness tests pass).
- **Accept** merges into the current branch — **resolved 2026-11-16**: the harness has no privileged branch. `TARGET_BRANCH = "develop"`, `checkOnTargetBranch`, the `accept.mts` `develop` default and every `develop` mention in docs/prompts were removed; a fresh run records HEAD as its base, a resumed run keeps its recorded base. Issue #130's AC still words it as `develop`; the closed issue is historical, code is the contract.
- **Event shape missing fields.** `agent-end` has no duration (`loop.mts:170,184,297`); `verdict` events name no file (`:193`). Spec §Observability item 1 lists both.
- **Status "elapsed per phase"** is one overall `elapsed` (`status.mts:84-95`). The AC softens this to "elapsed" and heartbeat age, so this is a design-text vs AC mismatch, not an AC failure.
- **Scope without an originating issue:** `--plan`/`sandcastle:plan`, `resume.mts`, `run_record.mts`, `report.mts` and `standards.mts` shotgun counting are not named in #130's change list. Defensible, but currently undocumented as commissioned work.

### #131 — Startup Config read

- Three read cases behave as specified; the real reason is logged (`config_store.zig:135-168,188-219`).
- **Unproven AC:** "the process exits 1 with core's line on stderr". `entry_native.zig:82-93` only pins the seam error set; nothing exercises exit code or stderr.
- **Wrong sentence path:** fixed with S1 — a startup write failure no longer aborts the boot, so Android's read sentence is only shown for a refused read.

### #132 — Android settings failure

- **Two Zig accessors, not one.** `bootState()` (`jni_host.zig:150`), `startupFailureText()` (`:187`), plus the JNI wrapper `startupFailureMessage()` (`:192`). AC asks for "one accessor"; the second was added by the later boot-state fix. Judgement: keep both but make the split explicit (state vs sentence) or fold them.
- **Logcat carried core's line twice — FIXED 2026-11-16.** `MainActivity.showBootError` now logs `boot failed: the settings read was refused` when core worded the text, instead of repeating core's sentence; the technical `reason` is still logged for failures core did not word.
- Device scenario exists and is the right test; it pins the rendering by core's distinguishing advice (`SETTINGS_REFUSAL_ADVICE = "Android Settings app"`) instead of re-spelling the whole sentence — FIXED 2026-11-16. Android has no bridge to core's constant; the exact wording stays pinned by core's sentence test.

### #133 — Web refusal wording

- Body/header path is single-sourced (`web_host/mod.zig` `answerPointerWrite`/`answerRefusal`); `host_api.js` keeps no reason list. ACs met.
- **Spec conflict, not a defect:** #133 step 5 said a non-ok reply without core's sentence keeps today's behaviour; #135 deliberately reversed that (`step_runner.js` `failedInput`). #135 is later and explicit — record the supersession in #133 if it matters.

### #134 — Harden the config read

- Portable fixture (`config_store.zig:330-332`) and the new branches are tested (`:432-441`, `startup/config.zig:365-379`, `config_store.zig:502-530`).
- **Unproven AC:** "proven by running the suite as root" leaves no artifact or wired root run in the tree.

### #135 — Refused forget

- Core order, refusal mapping, per-cause sentences, transport `delete`, one-line logging: present and tested (`forget.zig`, `storage.zig`, `web_host` `pointerError`, `file_transport.zig`).
- Reviewer's "no settings location deletes nothing" claim is **refuted**: `applyCurrentFileForget` returns `.landed` only when `session.current_file == null` (nothing to forget); with no settings location it passes `settings = null` and the deleter still runs (`web_host/mod.zig:311-325`), exactly what the AC's transport note requires.

### #137 — Memory transport move

- Met: file at `src/test/support/memory_transport.zig`, import `../../native/shell/file_transport.zig`, type/API unchanged, delete test moved with it.

---

## Refuted during verification (do not triage)

- `src/test/layering.zig:232-239` "defer leak in walker loop" — Zig runs `defer` at the end of each loop-body block; no leak.
- `.sandcastle/loop.mts:239` "ledger default crashes drop/child ticks" — `readLedger` normalises missing `criteria` to `[]`; type error only (H1), no runtime failure found.
- `#135` "no settings location deletes nothing" — matches the AC; see above.
- `.sandcastle/status.mts` "no pid file" — the #130 AC accepts heartbeat age; pid was design prose only.

## Suggested triage buckets

Harness findings H1–H9 are filed as GitHub #138 (needs-triage). App standards S2–S5 are #139; S6 was dropped as taste, not a defect.

1. **Fix before push:** H2 (`drop` misreports), H4 (docs vs resume). S1, #130 stale verdicts, #132 logcat and device-test literal are fixed in the working tree (2026-11-16).
2. **Fix soon:** #132 accessor split, #131/#134 unproven ACs (add the exit/root proof or untick). S2–S5 and H3/H7 are filed (#139, #138).
3. **Decide the contract:** #133 step 5 vs #135 (record the supersession); uncommissioned plan/resume/report scope.
4. **Nits / backlog:** #130 event fields. S4–S6, H1/H5/H6/H8/H9 are filed or dropped (#139, #138).
