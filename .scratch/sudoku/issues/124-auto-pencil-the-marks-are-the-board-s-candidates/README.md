# #124 — Auto Pencil: the marks are the board's candidates, not the player's notes

Run record for the sandcastle run that did this issue's work, written by `npm run sandcastle:accept`.

## Run

- Branch: `sandcastle/sequential-reviewer/1795151488836`
- Cut from `develop` at `e1a4d7253bd97b39015b5199c70ae2f0eb966fee`; head `a55e83618cc0b9c9537c9a4caf8104c87a6c631e` (8 commits)
- Steps: 6 of 6 ticked; acceptance criteria: 0 ticked
- Final review: no whole-branch verdict was copied
- Run logs and agent transcripts: `.sandcastle/logs/1795151488836/` (git-ignored; this copy is the record)

Commits, oldest first:

1. `386165b` feat(config): add the auto_pencil setting
2. `3b42645` refactor(pencil): rename pencil_mode to is_pencil
3. `b24a37b` feat(board): read a cell's candidates from the board
4. `6aad3af` feat(frame): answer the drawn marks for the whole board
5. `b6f3ca5` feat(engine): a digit fills in Pencil while Auto Pencil is on
6. `2601607` feat(settings): Show Pencil Marks is unavailable while Auto Pencil is on
7. `ad9dd96` fix(settings): a Settings change reaches View -> Show Pencil Marks as it lands
8. `a55e836` Revert "fix(settings): a Settings change reaches View -> Show Pencil Marks as it lands"

## Acceptance criteria

- (none recorded)

## Concerns (not fixed here)

- (none recorded)

## Shotgun

- (none recorded)

## Files

- `step-1-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, standards
- `step-2-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, standards
- `step-3-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, standards
- `step-4-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, standards
- `step-5-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, standards
- `step-6-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, standards
