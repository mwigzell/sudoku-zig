Status: needs-triage
Triage date: 
Triage notes:
  - Parent umbrella for interactive play loop (US1/US2/US3 from PRD).
  - Sub-steps broken into T1–T6 per README spec.
  - Not ready-for-agent until children claim and complete in dependency order.

## Blocked By

- [x] 01-command-parser (T1) — command union + parser returning ParseCommandResult
- [x] 02-game-engine-exec (T2) — exec(Command) returns CommandResult with given-cell feedback
- [ ] 03-validator-flag-conflicts (T3) — walk Board views and flag conflicting cells
- [ ] 04-exec-wires-validator (T4) — wire validator into exec path post-mutation
- [ ] 05-styler-conflict-decoration (T5) — AnsiStyler decorates conflicting cells
- [ ] 06-main-command-loop (T6) — full command loop with acknowledge gate

## Working mode
TDD per TDD skill. Agent writes tests first, then code for each step. T6 is integration-heavy — verified by manual `zig build run`.

## Parent

`.scratch/sudoku/prd.md` — US1, US2, US3: Interactive terminal Sudoku game with visible conflicts

## What to build

Replace the "render once and exit" main with a command-driven loop. The player types commands like `fill A1 7`, `clear C3`, or `quit`. Parse errors and rule violations both flow through an acknowledge gate (print message, consume Enter press). Visible conflict detection via validator + styler decoration.

## Current state at start of issue

- ✅ Board owns flat `[81]Cell`, can mutate cells via setCell/clearCell, has isGiven guard
- ✅ GameEngine wraps Board + Renderer — fill(), render(), fillAndRender()
- ✅ AsciiRenderer renders grid with unicode borders, Styler seam for givens highlight
- ✅ main() bootstraps GameEngine and renders initial board once
- ❌ No stdin command parsing — game exits after initial render
- ❌ No Validator — conflicts across row/col/box not detected or marked
- ❌ fill() silently swallows given-cell rejections — no feedback to player

## Acceptance criteria

- [x] Command tagged union defined with fill/clear/quit variants and chess-style coordinate parse
- [x] Parser returns ParseCommandResult — valid commands carry structure, invalid inputs carry rejection message
- [x] GameEngine gains exec(Command) !CommandResult entry point; given-cell rejections surface as .error_msg
- [ ] Validator detects digit conflicts across row/col/box using Board topology
- [ ] Conflicting cells are visually distinguished via AnsiStyler
- [ ] Main event loop: render → prompt → read → parse → switch → exec → acknowledge (on failures)
- [ ] quit command exits cleanly
- [ ] Parse errors handled without crashing
- [ ] zig test passes all prior tests

## Blocked by

(none — Board, GameEngine, AsciiRenderer, Styler seam all delivered)
