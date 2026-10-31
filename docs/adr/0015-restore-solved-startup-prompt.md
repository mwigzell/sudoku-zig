# ADR-0015 — Restore-solved startup prompt policy

Status: accepted (amended: the question is a core `ask` step, not the New Game dialog)
Date: 2026-10-24

## Context

Startup precedence is currently `restore > new > idle` (shared core policy). After recent status-lifecycle work, restore continuity is strong: solved board + `"You win!"` status can be restored exactly.

That exposes a product tension:

- **Flow goal**: auto-new should move users to the next puzzle quickly.
- **Reflection goal**: restore/idle should let users sit with completed state.

On a solved restore, forcing either behavior globally is too rigid.

## Decision

Add an explicit solved-restore branch in shared startup policy:

- `on_restore_solved = prompt`

Meaning:

- if startup action resolves to `restore` and restored board is solved,
- the startup flow asks "Puzzle solved" (New game / Keep) on every platform,
- **New game** => generate at the saved difficulty,
- **Keep** => keep restored solved board and restored status.

## Consequences

- Maintains core policy centralization: adapters only show the question, they do not invent behavior.
- Web loses the difficulty picker on this path; the saved difficulty is used.
- Preserves restore continuity when user cancels.
- Provides forward-compatible seam if future options are needed (`stay`, `auto_new`, `prompt`).

## Implementation Tracking

- Open issue: [#77](https://github.com/mwigzell/sudoku-zig/issues/77)
