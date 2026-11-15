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

2. **Judge each criterion on the branch, not on the steps.** For every criterion, find the code or the test that makes it true *now*, and run what you need to run. A criterion is `PASS` only when you can name what you read or ran; a commit message, a step title or a summary is not evidence. If you cannot prove it, it is `FAIL` with empty evidence — that is an honest answer, and the run stops for a human.

3. **Run the gate over the whole branch.** `zig build verify`, and keep its exit code. A branch that is green only in parts is not green.

4. **Answer every coding standard**, rule by rule. The list is `AGENTS.md` "## Coding standards" on this branch: read it, and answer **each numbered rule** — none skipped, none invented, and each answer carries `file:line` evidence or names the violation with its site. "Code smell", a hunch or a rule paraphrased out of existence is not an answer. Check the whole diff, not the last commit.

5. **Say what a human should know.** `concerns` carries what you would tell the person accepting this run: risks, follow-ups, anything that reads as drift from the issue. Do not invent work items.

# Write the verdict

The host ticks the criteria you pass — the ones marked `PASS` with evidence — and leaves the issue open. You never tick anything yourself, and you never touch the issue.

Write **`.sandcastle/verdict-acs.json`** in the repository root, and nothing else:

```json
{
  "criteria": [
    {
      "criterion": "the criterion as the issue words it",
      "status": "PASS",
      "evidence": "the test or command you read or ran, and what it showed"
    }
  ],
  "concerns": ["what a human should read before accepting this run"]
}
```

`criteria` lists **every** acceptance criterion of the issue, in the issue's order, worded as the issue words it: the host matches your matrix against the issue body, and a criterion it cannot match stops the run. `status` is `PASS` or `FAIL`, and `PASS` needs the evidence you read or ran. A criterion you cannot prove is `FAIL` with empty `evidence`; do not pad it.

Write **`.sandcastle/verdict-standards.json`** too, and nothing else:

```json
{
  "rules": [
    {
      "rule": "the rule's bold title, worded as AGENTS.md words it",
      "verdict": "PASS",
      "evidence": "src/host/host.zig:40 — what you read or ran, and what it showed"
    }
  ],
  "shotgun": [{ "symbol": "current_file", "files": 3 }]
}
```

`shotgun` names the symbols this branch carries through several files — one more argument, field, command tag or JSON key threaded layer by layer — and the host recounts the files itself, so the `files` figure you write is replaced by its own. `symbol` is one identifier exactly as the code spells it (a field, a parameter, a JSON key), never a sentence about it: the host searches for that text, and a parenthetical explanation belongs in `concerns` instead. An empty list is an honest answer when the diff carries no such symbol; naming one the branch does not have stops the run.

`rules` answers **every** numbered rule in the branch's `AGENTS.md` "## Coding standards", one entry each: the host reads the same list from that file and stops the run if a rule is unjudged, invented, or unevidenced. `verdict` is `PASS` or `VIOLATION`; a `VIOLATION` stops the run for accept or drop exactly as a failing step does, so it must name the site.
