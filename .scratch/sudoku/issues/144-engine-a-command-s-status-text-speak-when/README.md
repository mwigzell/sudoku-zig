# #144 — Engine: a command's status text — speak when the board changes, keep it when nothing does

Run record for the sandcastle run that did this issue's work, written by `npm run sandcastle:accept`.

## Run

- Branch: `sandcastle/sequential-reviewer/1795112915142`
- Cut from `develop` at `00084d4bf4636e56bbd4bf1c6a751e0eb7faef05`; head `b9bf944d417a342efd32ac83c14ff87c3da41643` (4 commits)
- Steps: 4 of 4 ticked; acceptance criteria: 11 of 11
- Final review: parity restored — `✓ parity: 85 scenario(s) on native, web and Android`
- Run logs and agent transcripts: `.sandcastle/logs/1795112915142/` (git-ignored; this copy is the record)

Commits, oldest first:

1. `58e64eb` refactor(engine): one status rule — a command speaks or stays silent
2. `b78b093` refactor(engine): drop the mid-command status resets in undo and redo
3. `13cde07` refactor(engine): a new game sets the status through the seam
4. `b9bf944` test(engine): pin what each board-changing command says, and say a mark's redo once

## Acceptance criteria

- PASS — `finishOkEvent` takes no clear-or-keep argument, and the engine has no remaining per-site decision about whether an empty command clears the durable status.
- PASS — The seam's doc comments state both rules: a command that writes sets the durable status; a command that writes nothing leaves it alone.
- PASS — Fill, clear, pencil mark on, pencil mark off, undo of a cell move, undo of a mark, redo of a cell move and redo of a mark each append their sentence, using the wording in Decisions.
- PASS — A conflicting fill shows both its fill sentence and the conflict sentence; a winning fill shows both its fill sentence and the win sentence.
- PASS — Selecting a cell after a hint leaves the hint as the durable status.
- PASS — Undo and redo of a solve batch no longer reset the scratch buffer mid-command; the rewind handler's reset carries a one-line reason.
- PASS — No handler outside the one command entry point and the one deliberate replacement resets the scratch buffer.
- PASS — `newFromOneLinePuzzle` sets the durable status through `beginEventMsg` and `finishOkEvent`; nothing outside the seam assigns `state.status`.
- PASS — The eight new sentences are in the sentence check's list and pass it.
- PASS — `docs/adr/0023-core-owns-the-status-line.md` records the rule, and `CONTEXT.md` lists it.
- PASS — `zig build verify` green, with the timing line reported.

## Concerns (not fixed here)

- Text drift beyond the issue: FILLED_FMT is 'Filled {d} in {s}.' where the Player screen / Decisions table writes 'Filled E5 with 3.' — the branch chose 'in' and documented it in ADR-0023; a human should decide whether that rewording is acceptable since the issue said text was 'new, not reworded' (the eight sentences are all new, but 'in' vs 'with' is a wording choice to confirm).
- The eight sentences are spread over three modules (game_engine.zig, pencil.zig, redo.zig/undo.zig) with three near-identical label-formatting helpers: appendCellEditMsg (game_engine.zig:391), appendUndoneMsgFmt (undo.zig:47), appendRedoneMsgFmt (redo.zig:54) and appendMarkMsg (pencil.zig:99, a one-line pass-through wrapper around appendEventMsgFmt). Consolidating the cell-label sentence helper into one place would remove the duplication (AGENTS.md rule 2, DRY); it was not judged a violation because each site has a distinct message set.
- applyForward gained a `speak: bool` parameter (pencil.zig:44) so a redo can suppress the toggle's own 'Marked …' — this is a per-call voice flag at a helper seam. It does not reintroduce a clear-or-keep flag on finishOkEvent, but it is the same shape of judgement the ticket removed; the redo path is pinned by 'a redo of a mark names only the redo, not what the mark did'.
- A mark that replaces a player's digit now reads 'Marked 5 in B2. The 7 in B2 was replaced by a pencil mark.' (pencil.zig:52 then :57) — correct per the 'special messages append' decision, but the resulting sentence pair is worth a player-screen sanity check.
- Undo of a solve-batch after a win reads 'You win! Undid the solve.', and redo of a solve reads 'Undid the solve. Redid the solve.' — the accumulation is what the rule dictates (append appends); the redo case in particular is a slightly odd running account. Confirmed by undo.zig:142 test and redo.zig test.
- Was a scope addition: src/wasm/boundary.zig writeCoreTextJson now exports BOOKMARK_SET_FMT, REWOUND_FMT, FILLED_FMT, CLEARED_FMT, MARKED_FMT, UNDID_MOVE_FMT to JS for the new step_runner.test.mjs assertion. This is a wire-surface addition that the issue did not name, though it is core-owned text and the gate's wasm-ownership check passes.
- No Android-only surface changed (git diff --name-only develop...HEAD lists no src/android file), so the declared pinned smoke coreAndJsLogLinesReachLogcat remains the whole device requirement; it was not run in this review (verify has no device).
- Android scenario requirement: satisfied by declaration, but a human running push-gate still owns the device evidence.

## Shotgun

- `FILLED_FMT` in 4 files — plumbing

## Files

- `step-1-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `step-2-verdict.json` — a step reviewer's verdict: the test added, what happened on revert, `verify_exit`, standards
- `verdict-acs.json` — the whole-branch acceptance-criteria matrix, with the evidence quoted
- `verdict-standards.json` — the standards lens, one answer per numbered rule
- `shotgun.json` — the symbols the branch carries through several files
