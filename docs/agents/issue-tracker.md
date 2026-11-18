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
- Android-only behaviour names the device scenario that holds it: the `src/android/test/FileBridgeTest.java` method the issue's steps add or update, or one the issue declares. `zig build verify` never runs that suite, so an issue that leaves it out leaves the behaviour held by nothing. Which scenarios a branch must prove is derived from the branch at closeout — see "Android scenarios".

Triage adds the section before an issue moves to `ready-for-agent`, and an **Agent Brief** carries it as a `**Front ends:**` field after `**Summary:**`.

## The mandate: fix the issue

Every issue means **fix the issue**, to its acceptance criteria, on every front end it names as in scope. Three rules keep that from becoming a moving target:

- **The Front ends section is the fence.** Work outside it does not happen. A defect that is real but only manifests on a front end the issue marks out of scope is named once — in the run's verdict or the reply — and left alone. Chasing it is scope the issue did not ask for.
- **Prefer steps in one issue over sibling tickets.** Splitting is for work one run cannot carry, not for tidiness: a split re-opens the goalpost, because each new issue re-derives what "done" means. Sibling tickets spun out of a parent (a messaging change becoming one issue per front end) are how a fixed issue turns into four open ones.
- **Stopping is not splitting.** A run that stops resumes the same issue. Nothing about an unfinished run justifies a new ticket.

What this does not license: an issue whose criteria cannot all be met without widening it says so and stops; widening the issue is the maintainer's edit, never the run's.

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

## Parity window
Cross-front-end parity compares the arms **against each other**, so an issue whose steps change a contract parity observes — a `CommandTag`, a flow `Step` kind, a fixture `expect` field, a runner step — cannot go green one arm at a time: the first arm is red because the other still speaks the old contract. Such an issue declares the hole instead of hiding it, in a section of its own:

```markdown
## Parity window
off for steps 1–4 (#141) — `zig build verify -Dparity=off -Dparity-off-issue=141`
parity is back on from step 5; final acceptance is plain `zig build verify`
```

- The gate is off for a named range of the issue's own steps, and the section names the issue the window belongs to as `(#N)`. The shape `plan.mts` reads, and what it refuses, is pinned in `docs/agents/sandcastle.md` ("The parity window").
- **Triage gate:** an issue that changes a parity-observed contract and carries no window is not ready for a run — it is not `ready-for-agent`, because the first step would come back red on work that is correct. A window that names a closed or unknown issue is refused as well.
- Every other step runs plain `zig build verify`, and the whole-branch review always does: the section says from which step parity is back on, and that claim is what the run proves.
- The window goes with the issue: when the issue closes, the section is deleted or marked `closed`, so a later run cannot inherit a hole that has already been paid for.

## Android scenarios

`zig build verify` runs no Android test: the suite in `src/android/test/FileBridgeTest.java` needs a connected device. Which scenarios a branch must prove is therefore **derived at closeout from the branch**, never guessed at triage — the set changes with the code. Three sources, in one list:

1. **Added or changed** — every method added or modified in the branch's diff of `src/android/test/FileBridgeTest.java` (a `+` line matching `void <name>(`). The issue's own steps create this work, so it needs no advance knowledge.
2. **Declared** — an optional section of the issue's own, naming an *existing* method the change deliberately exercises (a core or bridge change that needs no new test):

   ```markdown
   ## Android scenarios

   `freshAppWithAutoSave` — the save path this change rewrites
   ```

   Triage adds the section only when it genuinely knows which method proves the change. It is **not** a `ready-for-agent` condition, and an issue without one is still ready. A fenced example of the section is not a declaration: the reader skips fences, so a worked example in a doc cannot be mistaken for a method name.
3. **The pinned smoke** — one method configured once in the project adapter, `ProjectConfig.android.smoke` (`coreAndJsLogLinesReachLogcat`), used when the branch changes no Android test method at all. Pinned in one place, not picked per issue.

Two rules close the hole a list written before the code leaves open:

- **Changed surface, no scenario: stop.** A branch that touches the Android app surface (`src/android/jni_host.zig`, `src/entry_android.zig`, the bootstrap Java, the WebView bridge) and adds, changes or declares no scenario does not close: closeout stops with `no scenario names this change`. The issue carries rule 11's escape — one sentence saying why a scenario cannot exist — or the change needs one.
- **No Android code: the smoke is the whole requirement.** Tooling work is the ordinary case.

The set is not advice. The `android-gate` build target runs it on one device and records the evidence, accept refuses before merging without that evidence, and a push runs the whole suite. The gates and the evidence file are in `docs/agents/sandcastle.md`.

## When a skill says "publish to the issue tracker"

Create a **GitHub issue** (`gh issue create`).

## When a skill says "fetch the relevant ticket"

Use `gh issue view N` or the issue URL the user provides.
