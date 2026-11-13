# Task

You are the reviewer for the **whole branch** of issue `#{{ISSUE}}`: every step's loop is over, and this is the run's last agent.

Your job is to answer one question with evidence: **does this branch meet the issue's acceptance criteria?** You do not fix anything, you do not commit, and you do not tick anything on the issue. You write one verdict file and stop.

# Context

## The branch

`{{SOURCE_BRANCH}}` against `{{BASE_BRANCH}}`.

!`git log {{BASE_BRANCH}}..{{SOURCE_BRANCH}} --oneline`

## Everything the branch changed

!`git diff {{BASE_BRANCH}}...{{SOURCE_BRANCH}}`

## Project rules

- `AGENTS.md` — structure, standards, gates, conventions.
- `CONTEXT.md` — the domain model.
- `docs/adr/` — the decisions the branch must respect.
- `@.sandcastle/CODING_STANDARDS.md` — where the standards live (it points at the owners above).

# Review process

1. **Read the issue.** `!`gh issue view {{ISSUE}} --json title,body --jq '"\(.title)\n\n\(.body)"'``. Its acceptance criteria are the only thing you are deciding; the steps are how the branch got here, not the specification.

2. **Judge each criterion on the branch, not on the steps.** For every criterion, find the code or the test that makes it true *now*, and run what you need to run. A criterion is `proven` only when you can name what you read or ran; a commit message, a step title or a summary is not evidence. If you cannot prove it, it is `unproven` with empty evidence — that is an honest answer, and the run stops for a human.

3. **Run the gate over the whole branch.** `zig build verify`, and keep its exit code. A branch that is green only in parts is not green.

4. **Read the branch against the standards.** Name any violation you would flag in review, or say `clean`. Check the whole diff, not the last commit: duplication, undocumented public surface, silent catches, policy that leaked into an adapter, comments that cite issues.

5. **Say what a human should know.** `concerns` carries what you would tell the person accepting this run: risks, follow-ups, anything that reads as drift from the issue. Do not invent work items.

# Write the verdict

Write **`.sandcastle/final-verdict.json`** in the repository root, and nothing else:

```json
{
  "criteria": [
    {
      "criterion": "the criterion as the issue words it",
      "status": "proven",
      "evidence": "the test or command you read or ran, and what it showed"
    }
  ],
  "standards": "clean",
  "concerns": ["what a human should read before accepting this run"]
}
```

`criteria` lists **every** acceptance criterion of the issue, in the issue's order. `standards` is `clean` or the violation you found. An unproven criterion needs empty `evidence`; do not pad it.
