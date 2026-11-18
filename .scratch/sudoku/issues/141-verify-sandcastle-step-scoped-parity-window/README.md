# #141 — verify + sandcastle: step-scoped parity window for cross-arm refactors

Run record for the sandcastle run that did this issue's work, written by `npm run sandcastle:accept`.

## Run

- Branch: `sandcastle/sequential-reviewer/1794974817535`
- Cut from `develop` at `9a42b7a`; head `b649adc` (7 commits)
- Steps: 7 of 7 ticked; acceptance criteria: 10 of 10
- Final review: parity restored — `✓ parity: 85 scenario(s) on native, web and Android`
- Run logs and agent transcripts: `.sandcastle/logs/1794974817535/` (git-ignored; this copy is the record)

Commits, oldest first:

1. `6f3663b` refactor(sandcastle): add the ProjectConfig seam between harness and repo
2. `fe82629` feat(verify): omit the parity check inside a declared parity window
3. `6892457` feat(parity): let both parity runners skip inside a declared window
4. `58b4c91` feat(sandcastle): read a step-scoped parity window from the issue body
5. `539f7b3` feat(sandcastle): run each step's gate from its plan window
6. `9746b2a` feat(sandcastle): prove a declared parity window restored at the whole-branch review
7. `b649adc` docs(sandcastle): frame the step-scoped parity window where its readers look

## Acceptance criteria

- PASS — Plain `zig build verify` is unchanged (parity on, same output).
- PASS — `-Dparity=off -Dparity-off-issue=N` runs verify without the parity check, prints the OFF banner, and both parity runners skip with `expected: parity off (#N)`.
- PASS — The option refuses when the named issue is not open.
- PASS — A plan parses a step-scoped `## Parity window` and refuses malformed ranges, unknown steps and closed issues.
- PASS — Only the window's steps get the off-command; every later step runs plain verify, and a step outside the window reporting parity off stops the run.
- PASS — The whole-branch review always runs plain verify, records `parity_restored`, and the host stops if a declared window is not restored.
- PASS — Harness tests cover the parse/refuse paths, the per-step command, and the unrestored-window stop.
- PASS — The `ProjectConfig` seam exists: generic modules carry no repo literals, no ambient project reads and no subprocesses, enforced by a boundary test; `main.mts` and the project adapter own `gh`/`bwrap`/`npm`.
- PASS — ADR-0022 records the harness shape, the seam and the parity window, and the implementation matches it.
- PASS — `zig build verify` green (including the node and sandcastle suites).

## Concerns (not fixed here)

- ADR-0022 §2 says a generic module contains no `parity` literal, but plan.mts/verdict.mts/loop.mts use `parity` as a field and function name and boundary.test.mts deliberately allows the bare word (it refuses only `verify-parity`/`-Dparity`/`SUDOKU_PARITY_OFF`). The test states the exception; §2 does not, so the ADR's literal list reads stricter than the shipped seam.
- plan.mts:367 resolves the window's issue as the first `#N` anywhere in the section, not the `(#N)` on the `off for steps` line: a section whose prose cites another issue above the range would query that issue's tracker state instead (a closed one would refuse the run).

## Shotgun

- `parity` in 20 files — plumbing
- `ProjectConfig` in 3 files — plumbing

## Files

- `step-1-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-2-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-3-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-4-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-5-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-6-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-7-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `verdict-acs.json` — the whole-branch acceptance-criteria matrix, with the evidence quoted
- `verdict-standards.json` — the standards lens, one answer per numbered rule
- `shotgun.json` — the symbols the branch carries through several files
