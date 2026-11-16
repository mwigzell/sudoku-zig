# #135 — web: a refused forget deletes the save its pointer could not clear

Run record for the sandcastle run that closed this issue's work. The issue is **open, awaiting
accept/drop**; nothing here is a tracker write.

## Run

- Branch: `sandcastle/sequential-reviewer/1794776469897`
- Cut from `develop` at `4865736`; head `ee693d9` (9 commits)
- Steps: 9 of 9 ticked; acceptance criteria: 17 of 17 ticked
- Run logs and agent transcripts: `.sandcastle/logs/1794776469897/`

Commits, oldest first:

1. `f03e005` fix(flow): a refused forget leaves the save, and core owns its order
2. `3c8cffb` fix(flow): a refused save says the game file was written
3. `0655271` fix(flow): a refused save and an unremembered load say what happened
4. `eff8f4d` test(parity): the transcript records what a forget answered
5. `cf09c0b` refactor(web): the wasm boundary is the only judge of a refusal kind
6. `76914eb` fix(flow): a store error that is no refusal is not called a settings refusal
7. `df26a8b` fix(native): a run with no settings location deletes what a forget asks it to
8. `974564e` fix(delete): an already-gone file is logged as expected on both delete arms
9. `ee693d9` fix(web): a pointer-write failure names its system message in the answer, once

## Evidence

- Branch gate: `zig build verify` exit 0 — 726 passed, 2 skipped (pre-existing macOS `open_browser`
  cases), 0 failed; standards clean on 69 changed files; timing gate passed; parity scenarios on
  native, web and Android.
- Android device suite: **23/23 passed** (`Time: 499.258`, `OK (23 tests)`) on `ee693d9`, headless
  `Agent_API_30`, run from a worktree of the branch.

## Harness fixes made on `develop` while running this issue

Each one was a stop that was not the branch's work:

- `e266556` fix(sandcastle): a standard's title continues past its bold — `8. **Clean** code style.`
  parsed as the rule "Clean", which no reviewer wording could match.
- `651ca31` fix(sandcastle): a standard's bold-only wording names the same rule — the next reviewer
  wrote "Clean", so both readings now match.
- `4865736` fix(sandcastle): a criterion that wraps is one criterion — the criteria reader took only
  the first line of a wrapped bullet, so a correct verdict was rejected.

## Concerns (not fixed here)

From the final review; recorded in the issue body as `## Known concerns (not fixed here)`:

- A save whose pointer write fails for a store error no refusal names answers `SAVE_FAILED_MSG`
  ("The game could not be saved.") although the bytes landed. The written-not-current sentences
  cover only `settings_unreadable` / `settings_unwritable`.
- The unwritable-settings parity scenarios skip themselves under a root uid, before the transcripts
  are written; a root CI run would leave the native parity transcript stale. The gate runs as
  uid 1000 and does not hit it.

## Files

- `verdict-acs.json` — the whole-branch acceptance-criteria matrix, with the evidence quoted.
- `verdict-standards.json` — the standards lens, one answer per numbered rule, plus `shotgun`.
- `step-1-verdict.json` … `step-9-verdict.json` — per-step reviewer verdicts: the test added, what
  happened on revert, `verify_exit`, standards, on-track/drift, concerns.
- `shotgun.json` — the symbols the branch carries through several files.
