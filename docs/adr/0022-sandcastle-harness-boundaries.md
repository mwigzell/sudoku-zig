# ADR-0022 — Sandcastle harness boundaries

Status: accepted
Date: 2026-11-17
Related: issue #141 (parity window), `docs/agents/sandcastle.md` (operating manual), `AGENTS.md` ("Sandcastle runs")

## Context

The run harness lives inside this repo (`.sandcastle/`, Node/TypeScript plus prompts) and produces the gate it is checked against: `sandcastle:test` runs inside `zig build verify`, the agents inside a run execute `zig build verify`, and the issues, steps and acceptance criteria are this repo's. It has grown an architectural shape that nothing wrote down — one issue per run, one commit per step, two fresh sessions, host-only tracker writes — so each new session re-derives it and each new step may dilute it.

The boundary between generic harness and project policy was implicit. It showed up as coupling in a handful of places: `standards.mts` parses `AGENTS.md`, `loop.mts` reads it from the worktree, `verdict.mts` hardcodes the words `zig build verify` in its contract and stop reason, the prompts name Zig, and `main.mts` runs `gh`, `bwrap` and `npm`. Everything else (plan, verdict validation, ledger, ticks, resume, events, report) was already project-neutral.

A cross-arm refactor exposed a second gap: parity compares the front ends **against each other**, so the first arm of a contract change is red even when it is correct. The workaround used for #125 — listing new commands in `flowless_commands` — is self-certified: prose, no issue number, no expiry, and it removes those commands from cross-arm comparison on all arms.

## Decision

### 1. The harness's shape is fixed, not configurable

- One unaccepted run per repository; one issue per run, one branch, one commit per step.
- Two fresh sessions per step: an implementer performs the step, a reviewer tries to falsify it. A reviewer may not write.
- **Who is who.** The **run host** is the harness process on the developer's machine (`.sandcastle/main.mts` → `loop.mts`), outside the agent's sandbox: it reads the agents' files, runs `gh`, and writes the **tracker** (GitHub). An **agent session** is the implementer or reviewer inside the sandbox: it writes only its commit and `.sandcastle/verdict.json`. The **human** runs `sandcastle:accept` or `sandcastle:drop`; accept closes the issue. All of these are glossary terms in `CONTEXT.md` ("Sandcastle (issue → branch)"). "Host" here never means the Zig `Host` in `src/native/` — that is the app's platform entry.
- The tracker is written only by the run host, never by an agent session: the host ticks the issue step it just accepted and the acceptance criteria the whole-branch review proved. The human's accept command closes the issue. An agent never accepts or drops a run, never ticks, and never closes the issue it worked on.
- The whole-branch review judges the issue's acceptance criteria with evidence per criterion; an unevidenced or invented criterion stops the run.
- The harness's own tests run in `zig build verify`, so the gate covers the tool that produces the gate.
- The Android device lane stays outside `verify`: the gate has no device, so a run holds Android-only behaviour by the scenario it adds and by a hand-run, never by pretending `verify` covers it.

These are opinions, not options. Anything a project can configure must be a **project fact** (paths, commands, syntax), never a harness policy choice.

### 2. A typed project seam separates the generic harness from this repo

- Generic modules receive a typed `ProjectConfig` (verify command, standards file and section, step and criterion syntax, tracker, agent/model, docs paths).
- Generic modules contain no repo literals (`zig`, `sudoku`, `parity`, `AGENTS.md`), read no project file by ambient path, use no `process.cwd()`, and spawn no subprocess. `main.mts` owns `gh`, `bwrap`, `npm` and the agent; one project adapter builds the config.
- A boundary test fails on a repo literal or an adapter import inside a generic module.
- Rejected: extracting the harness into a separate project **now**. There is one consumer; the harness and this repo's issue format, standards file and verify command evolve together, and a pinned package would break that lockstep (or be path-linked back into it). Extraction triggers, either of them: a second repository uses the harness, or the harness needs a release cadence independent of this repo. The seam exists so extraction is a move, not a rewrite.

### 3. A parity window is the only sanctioned way to run a cross-arm refactor

- An issue whose steps change a parity-observed contract declares a `## Parity window` in its body: parity off for a named range of steps, naming this issue.
- `zig build verify -Dparity=off -Dparity-off-issue=N` omits the parity check, prints an OFF banner and makes both parity runners skip with a logged reason; it refuses a closed or unknown issue.
- Only the window's steps get the off-command. The first step after the window, and the whole-branch review, run plain `zig build verify`; the loop's host stops when a declared window is not restored.
- Rejected: using `flowless_commands` as a migration tool (self-certified, no expiry, switches parity off per command on every arm), and disabling parity without a declared, closed window.

## Consequences

- Harness changes and project changes move in one commit stream; there is no version to pin and no release to wait for.
- A cross-arm refactor is planned as a window: arms inside it, integration at the window edge, parity proven again for every later step and at the final review.
- The generic modules are reusable if a second consumer arrives; extraction becomes relocation plus a package boundary.
- Adding a project fact means adding a `ProjectConfig` field and its adapter; changing harness policy needs this ADR, not a config flag.

## References

- `.sandcastle/` and `docs/agents/sandcastle.md` — the implementation and the operating manual.
- Issue #141 — the `ProjectConfig` seam and the step-scoped parity window this ADR decides.
- Issue #125 — the `flowless_commands` workaround that motivated the window.
