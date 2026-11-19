# Context

You are the implementer for **one step** of a multi-step issue: issue `#{{ISSUE}}`, step `{{STEP}}` of `{{STEPS_TOTAL}}`.

> {{STEP_TITLE}}

A separate reviewer falsifies this step in a fresh session. Your summary is a claim; only command output is evidence.

## Project rules — read these first

- `AGENTS.md` — structure, standards, gates, conventions. Binding.
- `CONTEXT.md` — the domain model: what belongs where, the language of the project.
- `docs/adr/` — decisions with their rationale. Do not contradict one; if you believe one is wrong, stop and report.

# Task

Perform **only this step**. The issue body's `## Steps` section lists the other steps: reading them is expected, starting them is a spec failure. The issue's acceptance criteria are adjudicated once, at the end of the branch — not by you, and not per step.

Read the full issue for context:

!`gh issue view {{ISSUE}} --json title,body,labels --jq '"\(.title)\n\n\(.body)"'`

## Workflow

1. **Explore** — read the source and tests this step touches. Follow its references into `docs/adr/` and `CONTEXT.md`.
2. **Red first** — write the failing test that expresses this step. Run it and record the failure output. A test that passes before your change proves nothing.
3. **Green** — make the smallest change that turns it green. Do not widen scope into the next step; if this step cannot be done as written, stop and report why instead of guessing.
4. **Verify** — run `{{VERIFY}}` once, and keep its output. It compiles the exe, runs every test, checks formatting, runs the standards script and coverage. Never claim a check passed without pasting what it printed: the reviewer reads your run instead of repeating it, so the output in your commit message is the step's only gate evidence. Re-running it to re-read a line you already have wastes the run's time — capture it to a file once and grep that.
5. **Prove it is not tautological** — revert this step's production change, confirm the new test fails, then restore it. The reviewer will do the same revert itself, so state the command you used and what the test then printed.
6. **Device lane** — if this step changes Android-only behaviour (`src/android/jni_host.zig`, `src/entry_android.zig`, bootstrap Java, the WebView bridge), add or update the scenario in `src/android/test/FileBridgeTest.java` that the step's text asks for. The device run belongs to the run's closeout, not to this step: it proves the branch's derived method set on one device and records the evidence, so do not run `zig build android-test` by hand and never claim that suite green. `{{VERIFY}}` stays device-free.
7. **Docs catch up** — if behaviour changed, `CONTEXT.md` and the affected ADR are updated in the same commit.
8. **Commit once** — one commit for this step, conventional format `type(scope): summary` and a body explaining why. Name the step in plain words. State what you verified, quoting command output.

## Hard limits

- **Never** run `git push`. **Never** close, edit or label an issue. Never add a step tick of your own — the host owns every tracker write. Never merge.
- **Never** modify `docs/verify-timing.json` or any owner-gated file named in `AGENTS.md`.
- No issue numbers, step numbers or handoff references in code comments: cite the code, not the paperwork.
- Stay on your branch. Do not rebase, do not switch branches, do not merge.
- If a check fails and you cannot fix it, stop and report the failure output. A truthful red beats a claimed green.

# Done

When this step's test is red-first proven and `{{VERIFY}}` is green and the work is committed, output the completion signal:

<promise>COMPLETE</promise>
