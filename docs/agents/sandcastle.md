# Sandcastle: one run per issue, one agent per step

The harness that runs an issue's `## Steps` through fresh agents, one step per iteration, and hands a
branch back for a human to accept or drop. It is deliberately **not** an autonomous closer: the host
writes to the tracker, a person decides what happens to the branch, and only a person closes an issue.

The code is `.sandcastle/` (Node/TypeScript, run through `tsx`), the three human commands are
`scripts/sandcastle-*.sh`, and the design record is the GitHub issue it was built from.

## Commands

| Command | What it does |
|---|---|
| `npm run sandcastle -- --issue 116` | Start a run over that issue's steps |
| `npm run sandcastle:plan -- --issue 116` | Print the run's shape — branch, bound, next step, agent-run count — and exit. Never invokes an agent |
| `npm run sandcastle:verdict` | Read the finished run: one block per step verdict, then the whole-branch matrix, then the diffstat |
| `npm run sandcastle:accept` | Merge the run branch into the **current** branch, remove its worktree, delete the branch |
| `npm run sandcastle:drop` | Take back the ticks the run wrote, remove its worktree, delete its commits |
| `npm run sandcastle:logs` | Show the newest agent transcript — the live view of a run. `-f` follows it, `-n <lines>` shows more, `--list` lists every transcript |
| `npm run sandcastle:test` | The harness's own `node --test` suites (also wired into `zig build verify`) |

Only one run exists at a time: a second `sandcastle/*` branch blocks both a new run and accept/drop.

## What a run does

1. **Aim.** `--issue N` is read once and parsed into a plan. A refused plan (no `## Steps`, or steps
   written as a numbered list or headings instead of `- [ ]` checkboxes) prints the reason and exits 1
   without touching the repo.
2. **Preflight**, all fatal: the working tree is clean, HEAD is on `develop`, no earlier run's branch or
   worktree remains, and `.sandcastle/.env` holds a `GH_TOKEN` (bwrap hides the host's `gh` login, so the
   agents need one of their own).
3. **One sandbox for the whole run**, created once: bwrap, the `pi` agent on `ollama/sandcastle-worker`,
   the host's `~/.pi/agent` mounted, `npm install` before the first agent, `node_modules` copied in. Every
   step commits to the one run branch, cut from `develop`.
4. **Per step, two fresh sessions.** An implementer performs that step only (red test, green, `verify`,
   red-on-revert proof, docs) and commits once; a reviewer in a new session tries to falsify it and writes
   `.sandcastle/verdict.json`. A step with no commit, two commits, or a reviewer that commits at all stops
   the run.
5. **The host reads the verdict** and decides (see below). On a pass it ticks that step on the issue and
   records the tick. Nothing else is ever written to the issue, and acceptance criteria are never touched.
6. **After the last tick, the whole-branch review** runs: one more session reads the entire diff and judges
   the issue's acceptance criteria, writing `.sandcastle/final-verdict.json`. The run exits 0 only if every
   criterion is proven with evidence.

The iteration bound is the **unticked** steps plus that final review; agent runs are two per step plus one.
A resumed issue therefore costs only what is left.

## What a verdict must say

A step verdict (`verdict.mts`), every field evidence the reviewer produced itself:

| Field | Meaning |
|---|---|
| `step` | The step it judges; a verdict naming another step stops the run |
| `test_added` | The failing test, as `file: what it asserts`. Empty stops the run |
| `red_on_revert` | What happened when the step's production change was reverted. Empty stops the run |
| `verify_exit` | The reviewer's own `zig build verify` exit code; must be 0 |
| `standards` | `clean`, or the violation; anything else stops the run |
| `on_track`, `drift` | Whether the diff is this step, and whether the branch is still heading for the issue |
| `ac_at_risk` | Criteria this step endangers; any entry stops the run |
| `concerns` | What the next step or the accepting human should know |

The whole-branch verdict carries `criteria` (`criterion`, `status` of `proven`/`unproven`, `evidence`),
`standards` and `concerns`. It passes only when every criterion is `proven` **with non-empty evidence** and
standards are `clean`; an unproven or unevidenced criterion stops the run and names itself.

A malformed verdict file is always a problem, never an empty pass.

## The tick ledger

Every tick the host writes is recorded in `.sandcastle/logs/<stamp>/ticks.json` — the issue and the
position of each step ticked, in order. That record is what makes `sandcastle:drop` able to rewrite exactly
the bytes the run wrote: it re-reads the issue as it stands now, flips those checkboxes back to `- [ ]`, and
says which steps it took back. A run with no record (from before the ledger existed) prints that the issue
is being left as it is, and the drop continues.

## Accept, drop, verdict

- **accept** merges the run branch into whatever branch you are on — so be on `develop`. It refuses when a
  second `sandcastle/*` branch exists or the run's worktree has uncommitted changes, then removes the
  worktree and deletes the branch.
- **drop** asks once, then reverts the recorded ticks, removes the worktree and deletes the branch. The
  verdicts and the ledger stay in the log directory as the record of what the run did.
- **verdict** is read-only: it never merges, never deletes, and never touches the issue.

Neither accept nor drop ticks acceptance criteria or closes the issue: that is the human's, after reading
the report.

## Files

| Path | Role |
|---|---|
| `.sandcastle/main.mts` | Entry: plan, preflight, sandbox and agent configuration, the run |
| `.sandcastle/plan.mts` | Reading `## Steps`, the tick and untick, the iteration bound, the plan text |
| `.sandcastle/loop.mts` | The step loop, the tracker write, the whole-branch review |
| `.sandcastle/verdict.mts` | Verdict shapes, their field-by-field validation, and the pass/stop rules |
| `.sandcastle/ledger.mts`, `drop.mts` | The tick record, and the tracker half of a drop |
| `.sandcastle/report.mts` | Turning verdict files into the readable report |
| `.sandcastle/{implement,review,final-review}-prompt.md` | What each agent is told |
| `.sandcastle/CODING_STANDARDS.md` | Points the agents at the standards' owners |
| `.sandcastle/logs/<stamp>/` | `step-<n>-verdict.json`, `final-verdict.json`, `ticks.json` |
| `.sandcastle/logs/sandcastle-<branch>-<role>-step-<n>of<m>.log` | The agents' transcripts, one per session; `npm run sandcastle:logs` reads the newest |
| `.sandcastle/.env` | `GH_TOKEN` for the sandboxed agents (untracked) |

`logs/`, `worktrees/`, `.env` and a stray `verdict.json` are gitignored: a run's evidence is local.

## Reading a stopped run

A stopped run leaves its branch and worktree with the verdicts it produced, and says why in `[stop] …`.
The verdict files say what the reviewer saw; the diff is `git diff develop...<branch>`. The two usual
causes are a step that did not prove itself (no red-on-revert evidence, a `verify` failure, a criterion at
risk) and an agent that went off-script (two commits, or a reviewer that wrote).

Prompt arguments `SOURCE_BRANCH` and `TARGET_BRANCH` are reserved by sandcastle itself; the harness passes
the run's own base as `BASE_BRANCH` so a review range never depends on the host's checkout.

## Limits worth knowing

- **No issue picking.** `--issue N` is required; the harness never chooses from labels.
- **No retry.** A step that stops the run is a human's to re-scope; the run does not re-attempt it.
- **Ticks outlive a drop before the ledger existed.** A pre-ledger run's ticks cannot be reverted, and the
  drop says so.
- **The gate covers the harness**, via the `sandcastle-test` build step in `zig build verify`; a timing
  budget change goes in `docs/verify-timing.json` when the suites legitimately grow.
