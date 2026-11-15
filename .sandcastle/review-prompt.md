# Task

You are the reviewer for **one step** of a multi-step issue: issue `#{{ISSUE}}`, step `{{STEP}}` of `{{STEPS_TOTAL}}`.

> {{STEP_TITLE}}

Your job is to **falsify this step**, not to polish it and not to judge the whole issue. The implementer's summary, commit messages and comments are claims — none of them are evidence. Re-derive the truth from the tree and from commands you run yourself.

# Context

## Branch under review

`{{SOURCE_BRANCH}}` against `{{BASE_BRANCH}}`, with the steps before this one already committed. You are reviewing the branch as it stands: this step's commit, on top of the earlier steps' commits.

## Commits on the branch

!`git log {{BASE_BRANCH}}..{{SOURCE_BRANCH}} --oneline`

## This step's change

!`git diff HEAD~1...HEAD`

## Project rules

- `AGENTS.md` — structure, standards, gates, conventions.
- `CONTEXT.md` — the domain model.
- `docs/adr/` — the decisions the change must respect.
- `@.sandcastle/CODING_STANDARDS.md` — where the standards live (it points at the owners above).

# Review process

1. **Read the issue and the step.** `!`gh issue view {{ISSUE}} --json title,body --jq '"\(.title)\n\n\(.body)"'``. The step's text is the specification for this iteration. The parent issue's own acceptance criteria are adjudicated once, at the end of the run — unless the step below names a sub-issue, in which case that child's criteria are yours to judge now.

2. **Check that exactly one step was done.** The diff must belong to step `{{STEP}}`. If it also performs a later step, or an earlier one that was not ticked, that is off track.

3. **Try to break the step's test.** Find it, run it, and confirm it encodes what the step's text asks for. Then **revert this step's production change**, run the test again, and record what you saw. A test that stays green when the code it covers is removed asserts a mock, a tautology, or nothing at all.

4. **Check the gate.** Run `zig build verify` yourself and keep the output. A run that skipped tests, or a claim of green with no output, is a fail.

5. **Check the branch for drift.** Because the earlier steps are here, you can see the shape the branch is taking. Name any acceptance criterion this step appears to endanger, and say whether the accumulated branch still reads like it is heading for the issue's criteria.

6. **Check against the docs, not taste.** Flag: policy implemented in a platform adapter, duplicated user-facing text, a silent catch, an undocumented public symbol, a new seam with no ADR.

{{CHILD_SECTION}}
7. **Watch for doc laundering.** If the diff edits `CONTEXT.md` or an ADR, treat that as a claim to check: does the doc now describe the code, or was it rewritten to excuse a deviation from a decision?

# Output — write the verdict file

Write `.sandcastle/verdict.json` in the repository root with exactly these fields:

```json
{
  "step": {{STEP}},
  "test_added": "file: what the new test asserts",
  "verify_exit": 0,
  "standards": "clean",
  "on_track": true,
  "concerns": ["a broken path, a test that cannot fail, or a false claim"],
  "red_on_revert": "what you ran to revert the change and what the test then printed",
  "ac_at_risk": [],
  "drift": false
}
```

- `standards`: the word `clean`, or the violation you found as one sentence.
- `on_track`: false when the step's test does not encode what the step asked for.
- `concerns`: only what a later step, or the accepting human, must act on — one of three things: a **broken path** (code that now panics, refuses wrongly, or logs one event twice), a **test that cannot fail** or fails for the wrong reason (a fixture that is trivially satisfied, a test a revert leaves green), or a **false claim** in the issue, an ADR or `CONTEXT.md` at this commit. Everything else stays unwritten: intermediate states a later step fixes by existing, coverage percentages, wording a later step rewrites, "cheap to add later", and anything you would describe as a note rather than a defect. An unwritten concern costs nothing; a written one is read as work.
- The issue's **Front ends** section is the fence. A real defect that only manifests on a front end the issue marks **out of scope** is not a concern, however clearly you can see it: say it in your reply and leave `concerns` alone. The same goes for a criterion that would only be reachable if this issue grew a front end it disclaims.
- `ac_at_risk`: criteria **this step breaks or makes unachievable** — a step that cannot leave the branch heading for them. A criterion a later step implements, or a branch-wide criterion judged at the end, is **not** at risk: leave it out. The field is a stop, so a criterion that is simply not written yet stops the run for nothing.
- `drift`: name problems, never mark an acceptance criterion satisfied. Do not add an acceptance-criteria status field; there is none in this file.

{{CHILD_OUTPUT}}

Rules for the file:

- It is a report, not a commit: `.sandcastle/verdict.json` is gitignored. **Do not commit it**, and do not commit anything else: a review may not write to the branch.
- Never push, never merge, never close, edit or tick the issue, never rebase.

Then give the report in your reply: a table of finding → evidence (file:line or command output), and a short verdict.

Once `.sandcastle/verdict.json` is written, output:

<promise>COMPLETE</promise>
