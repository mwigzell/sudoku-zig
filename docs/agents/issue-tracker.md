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

## Steps a run can take

An issue that a sandcastle run steps through writes its steps in a `## Steps` section as **checkboxes**, one per iteration:

```markdown
## Steps

- [ ] **The file:** `config.json`, read and written generically.
- [ ] **Config leaves the engine:** platforms hold Config beside the engine.
```

- One `- [ ]` item is one step: one implementer session, one reviewer session, one commit on the run branch.
- The host ticks a step by changing `- [ ]` to `- [x]`, and touches nothing else in the body. The agents never write to the issue, never label it and never close it.
- A numbered list (`1. …`), `### Step N:` headings, or prose in that section cannot be ticked without rewriting the author's words, so `npm run sandcastle:plan -- --issue N` refuses the issue with the reason and no run starts.
- Acceptance criteria stay checkboxes under their own heading. They are judged once, against the whole branch, at the end of the run — never per step.
- Write the step's text as the work to be done now: the implementer performs it as written and stops there. A step that needs a later step to make sense is two steps.

Triage fixes the step shape while it is already editing the body.

## When a skill says "publish to the issue tracker"

Create a **GitHub issue** (`gh issue create`).

## When a skill says "fetch the relevant ticket"

Use `gh issue view N` or the issue URL the user provides.
