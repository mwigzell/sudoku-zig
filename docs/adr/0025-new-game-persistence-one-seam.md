# ADR-0025 — New-game persistence is one shared core seam

Status: proposed
Date: 2026-11-27

## Context

"Generate a new game and persist it" is implemented in two places:

- `StartupFlow` (`src/core/flow/startup.zig`) — the startup auto-new path. It calls
  `startNewGameWrite()` → `SaveFlow.newGame(...)`, which writes the accepted game
  immediately. This is the copy #136 fixed.
- `CommandFlow` (`src/core/flow/command.zig`) — the File → New menu path. It calls
  `load(.new_game)` → `noteLoad(.new_game)` → show, and never writes. The `new` command
  is `false` in `commandTriggersAutoSave`, so the game sits unsaved until the first move.

Because the behavior lives in two places, #136 fixed only the `StartupFlow` copy. The
`CommandFlow` copy kept the old "wait for first move" behavior, so the first digit after
File → New autosaves onto an existing target with a `.detached` write context — the #69
guard fires, and the player sees "Replace file?" on their first move.

The two *flows* are legitimately different (startup policy vs. per-command pipeline), but
"new game → persist" is one behavior and should be one seam, not two copies.

## Decision

"Generate and persist a new game" is a single shared core operation. Both `StartupFlow`
and `CommandFlow` call it; neither reimplements it.

The shared operation honors this contract:

- **Auto Save gates the write.** With Auto Save off, nothing is written and the new game
  stays detached (as today).
- **The new-game write reports where it landed; autosave stays silent.** `SaveFlow.newGame` sets `.report = true`, so a new game reports `SAVED_TO_FMT` ("The game was saved to {s}.") after the write — the player's explicit action. A move's autosave uses the silent path (`.report = false`) and reports nothing. The `.report` flag is scoped to the new-game write only; it never leaks onto autosave.
- **Where the new game lands decides whether anything is asked:**
  - the app's own autosave target (hidden restore copy) — write silently;
  - a file the player named or picked — the existing replace confirmation, once, and act
    on the answer;
  - no target yet — write it, no question.
- **Declining the replace keeps the old file.** The existing `SaveFlow` decline path
  leaves the new game unpersisted and the session detached; the shared operation inherits
  this, so a declined New does not overwrite the player's file.

## Consequences

- A fix to new-game persistence lands once and applies to every path that generates a new
  game; the two flows can no longer diverge.
- The overwrite policy stays centralized in `file_policy.evaluateOverwritePolicy`, which
  decides write-silently / ask-once / write from `(intent, target_exists, write_context)`
  regardless of which flow invoked it.
- File → New now reports `SAVED_TO_FMT` after the write, matching the startup path — a
  deliberate, user-visible change (New confirms it saved, where today it is silent).
- No saved-data change: `SUD0` (ADR-0018) and `config.json`'s shape are untouched.

## Implementation Tracking

- Open issue: [#161](https://github.com/mwigzell/sudoku-zig/issues/161)
