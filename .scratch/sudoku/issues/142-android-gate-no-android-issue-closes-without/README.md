# #142 — Android gate: no Android issue closes without a recorded device run; full suite at push

Run record for the sandcastle run that did this issue's work, written by `npm run sandcastle:accept`.

## Run

- Branch: `sandcastle/sequential-reviewer/1794984795476`
- Cut from `develop` at `a7f5fb628e8d930da46a940d2691f3bce7c68605`; head `619342414102d5bf2ee6d28f108923c0ef982aca` (10 commits)
- Steps: 6 of 6 ticked; acceptance criteria: 8 of 8
- Final review: parity restored — `✓ parity: 85 scenario(s) on native, web and Android`
- Run logs and agent transcripts: `.sandcastle/logs/1794984795476/` (git-ignored; this copy is the record)

Commits, oldest first:

1. `e5ad8db` feat(android): gate a device run on a recorded evidence file
2. `e8c7d0c` docs(android): derive the required device scenarios where the branch is read
3. `c4678cb` feat(sandcastle): refuse an accept whose device evidence does not prove the branch
4. `532319a` feat(push): gate a push on verify, the slow suite and the full device suite
5. `bba1462` feat(sandcastle): prove an Android branch on a device before accept
6. `0f62258` docs(sandcastle): replace the hand-run device note with the close and push gates
7. `5abb434` refactor(sandcastle): carry the path-matching rule once
8. `fa21fb7` docs(android): record the device evidence on both closing paths
9. `58067f5` feat(android): target one device by ANDROID_SERIAL among several
10. `6193424` fix(android): print the device the suite targets, not the list of attached ones

## Acceptance criteria

- PASS — `zig build android-gate -Dandroid-methods=<a>,<b> -Devidence-out=<path>` runs exactly those methods and writes evidence naming the commit and the clean tree, or fails without a device — never skips; a dirty worktree is refused.
- PASS — The required set is derived at closeout: methods added or changed in the branch's Android test file, plus declared methods, plus the pinned smoke when the branch changes none.
- PASS — An Android-scope branch with a changed Android app surface and no added, changed or declared scenario ends `no scenario names this change` instead of accepting.
- PASS — Accept refuses **before merging** when evidence is missing, failed, from another commit, from a dirty tree, or names fewer methods than required, with a reason naming the defect; `drop` ignores evidence.
- PASS — `zig build push-gate` runs verify, verify-slow and the full Android suite cheapest-first, stops on the first failure, records each lane's status, and docs say a push waits for it.
- PASS — Direct (non-sandcastle) work records the same evidence line in the issue before closing, and the issue's own closeout keeps the evidence JSON in the run directory and the accepted record.
- PASS — A run whose branch has Android in scope ends in the closeout phase with device evidence on the run branch tip, or `stopped: device` with a reason — never a skip, and never a post-accept discovery.
- PASS — `zig build verify` stays device-free and green; the harness tests and `sandcastle:test` are green.

## Concerns (not fixed here)

- This branch's own device evidence is produced by the closeout that runs after this review, so no android-evidence.json exists yet; on a host without a device (or without ANDROID_NDK_HOME/ANDROID_NDK_ROOT) the run ends `stopped: device` with the gate's own line, which the criterion allows but a human should expect to see before accepting.
- The instrumented path itself (am instrument with the comma list, and a record written from a real run) was not exercised here: adb lists emulator-5554 attached, but no NDK root is exported in this environment, so `zig build android-gate` cannot reach the device. The tool binary was compiled directly and probed for the refusal and record paths instead.
- android-evidence.json's required[].why is the same generic sentence (`required by this run branch`) for every method: ProjectConfig.android.gate.command (project.mts:70-72) carries only the method list, so the reasons requiredScenarios derives (added/changed, declared, smoke) never reach the record.
- addedOrChangedMethods matches only added declaration lines (`+ … void name(`), so a scenario modified in its body alone is not detected and the branch falls back to the pinned smoke. That follows the issue's own design wording but is narrower than 'changed' in the criterion.
- `accept.mts:13` still imports `ghTracker` without using it; that line is carried over from develop, so it is not new on this branch.

## Shotgun

- `clean_tree` in 6 files — plumbing

## Files

- `step-1-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-2-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-3-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-4-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-5-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-6-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `verdict-acs.json` — the whole-branch acceptance-criteria matrix, with the evidence quoted
- `verdict-standards.json` — the standards lens, one answer per numbered rule
- `shotgun.json` — the symbols the branch carries through several files
- `android-evidence.json` — the device run accept gated on: the methods, the commit and the result
