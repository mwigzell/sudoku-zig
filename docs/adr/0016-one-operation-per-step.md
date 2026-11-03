# ADR-0016 — One operation per flow step

Status: accepted
Date: 2026-11-02

## Context

Core flows (ADR-0011) drive the platforms through steps. Several steps were folded operations told apart by a `kind` flag (`check_target` and `write` with `save` / `save_as` / `auto_save` / `export_line`, `pick_open` with `game` / `puzzle`), and others were named for their mechanism (`pick_existing`, `pick_new`, `generate`, `copy_line`). Every handler switched on the flag to work out what core meant, so the platform ended up deciding. Web built a handler set per flow and swapped Android behaviour in at runtime (`session.bound*`), so a step issued from an unexpected flow (e.g. `save_as` after autosave's `taken`) found no handler, and nobody could see which code ran where.

## Decision

- **A step is one operation.** If a platform would act differently depending on which flow issued it, it is two steps; if it acts the same, it is one shared step.
- **No kind flags** on steps.
- **Names:** a step that is one command's operation takes the command's name (`save`, `save_as`, `open`); steps about the puzzle say `_puzzle` (`export_puzzle`, `import_puzzle`, `copy_puzzle`, `paste_puzzle`); a step is never named for the platform call that carries it out.
- **No check step.** Saved-game writes (`save`, `save_as`, `autosave`) carry `replace`. A handler writing a fixed file answers `exists` without writing when the file is there and `replace` is false; a picker never answers `exists`. Core applies the replace policy and reissues or asks.
- **One handler per step per platform**, used by every flow: native `Storage` / renderer, web `web_steps.js`, Android `android_steps.js`. Web and Android are separate sets built on shared helpers; no runtime swapping.
- **A step a platform never receives answers failed with a reason for the log**, documented at its handler; no `unreachable` arms, no missing handlers.

The step list lives in `CONTEXT.md` (Flows and steps).

## Consequences

- Handlers read as a table: one function per step, no branching on who asked.
- A new flow can issue any existing step without touching handler wiring.
- Adding an operation means adding a step on every platform, even where it only fails with a reason.
- The closing write is its own `flush` step instead of an autosave with a web-only `hostOnly` option.
