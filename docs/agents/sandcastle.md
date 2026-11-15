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

1. **Aim.** `--issue N` is read once into a plan, with its labels. A refused plan (an issue without
   `ready-for-agent`, no `## Steps`, or steps written as a numbered list or headings instead of
   `- [ ]` checkboxes) prints the reason and exits 1 without touching the repo.
2. **Preflight**, all fatal: the issue carries `ready-for-agent` (a label check, not a picker: an
   issue on `needs-info`, `ready-for-human` or `wontfix` is refused by the plan, before preflight),
   the working tree is clean, HEAD is on `develop`, no earlier run's branch or worktree remains,
   and `.sandcastle/.env` holds a `GH_TOKEN` (bwrap hides the host's `gh` login).
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
   the issue's acceptance criteria, writing `.sandcastle/verdict-acs.json`. The host then ticks every
   criterion that session proved — matched one for one against the issue body, so a criterion it invented
   or skipped stops the run — and leaves the issue open. The run exits 0 only if every criterion is proven
   with evidence.

The iteration bound is the **unticked** steps plus that final review; agent runs are two per step plus one.
A resumed issue therefore costs only what is left.

## The device lane is outside the gate

`zig build verify` runs no Android test: the suite in `src/android/test/FileBridgeTest.java` needs a connected device, and the harness preflight checks none. A run therefore holds Android-only behaviour by the scenario the step adds (`AGENTS.md` rule 11, `implement-prompt.md` step 6) and by `zig build android-test -Dtest-filter=<method>` when a device happens to be up — never by `verify`. With no device the implementer says so; the owner runs the suite before a push, and the acceptance gate says which scenarios it ran.

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
standards are `clean`; an unproven or unevidenced criterion stops the run and names itself. Each criterion
is matched against the issue body by its text: one the issue does not word that way, or one the matrix
leaves out, is a stop — the reviewer may neither invent a criterion nor skip the one it could not prove.
The proven ones are then ticked by the host, exactly as a step is.

The final pass also answers the **standards lens** in `logs/<stamp>/verdict-standards.json`: one entry per
numbered rule in the branch's own `AGENTS.md` "## Coding standards", each `PASS` with `file:line` or a
`VIOLATION` naming its site. The harness reads that same list from that file rather than keeping its own,
so a rule added to `AGENTS.md` is required by the next run with no change here. A rule unjudged, invented,
or unevidenced stops the run, and so does any `VIOLATION` — the standards lens is not advisory.

The one figure in that report the host does not take on trust is the shotgun count: the reviewer names
the symbols the branch carries through several files, and the host counts the files that name them
(`rg -l`), keeping its own numbers in `logs/<stamp>/shotgun.json`. A symbol the branch does not have
stops the run; a count of three or more files is reported as `plumbing`, fewer as `carried`.

A malformed verdict file is always a problem, never an empty pass.

## The tick ledger

Every tick the host writes is recorded in `.sandcastle/logs/<stamp>/ticks.json` — the issue, the position of
each step ticked as it passed, and the position of each acceptance criterion the final pass proved. That record is what makes `sandcastle:drop` able to rewrite exactly
the bytes the run wrote: it re-reads the issue as it stands now, flips those checkboxes back to `- [ ]` — steps and
criteria alike — and says which positions it took back. A run with no record (from before the ledger existed) prints that the issue
is being left as it is, and the drop continues.

## Accept, drop, verdict

- **accept** merges the run branch into whatever branch you are on — so be on `develop`. It refuses when a
  second `sandcastle/*` branch exists or the run's worktree has uncommitted changes, then removes the
  worktree and deletes the branch.
- **drop** asks once, then reverts the recorded ticks, removes the worktree and deletes the branch. The
  verdicts and the ledger stay in the log directory as the record of what the run did.
- **verdict** is read-only: it never merges, never deletes, and never touches the issue.

Ticking acceptance criteria is the whole-branch reviewer's call, carried out by the host on its evidence —
the same split as a step. Accepting a run then closes the issue it was aimed at, because the run already
proved its criteria: the number comes from the run's own record (`logs/<stamp>/run.json`, written before any
agent starts), falling back to the ledger for a run older than that record. A run that leaves neither closes
nothing and says so, rather than guessing a number and closing someone else's issue.

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
| `.sandcastle/logs/<stamp>/` | `step-<n>-verdict.json`, `verdict-acs.json`, `verdict-standards.json`, `shotgun.json`, `ticks.json`, `run.json`, `events.jsonl`, `run.log` |
| `.sandcastle/logs/sandcastle-<branch>-<role>-step-<n>of<m>.log` | The agents' transcripts, one per session; `npm run sandcastle:logs` reads the newest |
| `.sandcastle/.env` | `GH_TOKEN` for the sandboxed agents (untracked) |

`logs/`, `worktrees/`, `.env` and a stray `verdict.json` are gitignored: a run's evidence is local.

## The two shapes a run can take

**A single multi-step issue**: the steps are the issue's own work. Each step's reviewer judges the step
and nothing else; when the last step passes, the whole-branch review judges the issue's acceptance
criteria in `logs/<stamp>/verdict-acs.json` (`PASS` with evidence, or `FAIL`), and the host ticks the
`PASS` ones and leaves the issue open.

**A parent whose steps are sub-issues**: a step's checkbox names a child issue (`- [ ] #125 …`), so the
child is the step. That child's reviewer judges the **child's** criteria and the host ticks them on the
child; the parent's step is ticked once the child's criteria pass. The whole-branch review still runs at
the end, judging only the parent's own end-to-end criteria — often none — so a shape-B run never skips it.
Every tick records the issue it landed on, so a drop takes a child's marks back from the child.

## Watching a run

`npm run sandcastle:status` says where the newest run stands, read from that run's directory alone
(no git, no GitHub): its issue and branch, its phase, which step it is on, how much it has ticked, how
long it has been going, and the last thing it logged. The phase is `live` while the last event is recent,
`stalled` when the run has gone quiet for 90s without finishing, `finished` when it logged its own end or
a stop. An agent session can think for minutes without logging anything, so the loop beats for it: a
`heartbeat` line every 30s for as long as a wait is outstanding, which is what keeps a working run `live`.

`npm run sandcastle:watch` follows the newest run instead of asking once: each event as it lands, then
the phase, and it exits when the run ends (Ctrl-C stops watching, not the run).

Every run keeps two copies of the same log, one line per transition: `logs/<stamp>/events.jsonl` for
programs (`status` reads it) and `logs/<stamp>/run.log` for a person.

## Reading a stopped run

A stopped run leaves its branch and worktree with the verdicts it produced, and says why in `[stop] …`.
The verdict files say what the reviewer saw; the diff is `git diff develop...<branch>`. The two usual
causes are a step that did not prove itself (no red-on-revert evidence, a `verify` failure, a criterion at
risk) and an agent that went off-script (two commits, or a reviewer that wrote).

Prompt arguments `SOURCE_BRANCH` and `TARGET_BRANCH` are reserved by sandcastle itself; the harness passes
the run's own base as `BASE_BRANCH` so a review range never depends on the host's checkout.

## Limits worth knowing

- **No issue picking.** `--issue N` is required; the harness never chooses from labels. It does read
  one: an issue without `ready-for-agent` is refused, because the label is triage's word that the work
  is specified.
- **No retry.** A step that stops the run is a human's to re-scope; the run does not re-attempt it.
- **Ticks outlive a drop before the ledger existed.** A pre-ledger run's ticks cannot be reverted, and the
  drop says so.
- **The gate covers the harness**, via the `sandcastle-test` build step in `zig build verify`; a timing
  budget change goes in `docs/verify-timing.json` when the suites legitimately grow.
