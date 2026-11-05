# Issue tracker: GitHub

Open work lives on **GitHub**: `mwigzell/sudoku-zig`.

```bash
gh issue list
gh issue view N
gh issue create ...
```

Use `docs/agents/triage-labels.md` for label vocabulary (`ready-for-agent`, `ready-for-human`, etc.). When acceptance criteria are verified, close the GitHub issue.

## Front ends in every issue

The product is one core with three front ends: **native** (terminal), **web** and **Android**. Every issue has a **Front ends** section that names all three, each either in scope or out of scope with a reason:

```markdown
## Front ends

- **Native:** in scope.
- **Web:** in scope.
- **Android:** out of scope: the terminal-only renderer is not used there.
```

- Web and Android share the web shell (Android is a WebView over the same page), so one shell change can cover both; each still gets its own line and its own test.
- Name what core owns for the change when front ends are involved: front ends draw core's state and text and send the player's input to core; they decide nothing.
- Tooling issues (build, coverage, standards) say which front ends' code they cover.
- An issue is closed only when **every in-scope front end** meets the acceptance criteria. Done on one front end is not done.

Triage adds the section before an issue moves to `ready-for-agent`, and an **Agent Brief** carries it as a `**Front ends:**` field after `**Summary:**`.

## When a skill says "publish to the issue tracker"

Create a **GitHub issue** (`gh issue create`).

## When a skill says "fetch the relevant ticket"

Use `gh issue view N` or the issue URL the user provides.
