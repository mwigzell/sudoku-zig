# Issue tracker: GitHub

Open work lives on **GitHub**: `mwigzell/sudoku-zig`.

```bash
gh issue list
gh issue view N
gh issue create ...
```

Use `docs/agents/triage-labels.md` for label vocabulary (`ready-for-agent`, `ready-for-human`, etc.). When acceptance criteria are verified, close the GitHub issue.

## When a skill says "publish to the issue tracker"

Create a **GitHub issue** (`gh issue create`).

## When a skill says "fetch the relevant ticket"

Use `gh issue view N` or the issue URL the user provides.
