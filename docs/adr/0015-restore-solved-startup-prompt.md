# ADR-0015 — Restore-solved startup prompt policy

Status: proposed
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
- launch the same New Game dialog used by normal New flow,
- **confirm** => start a new game,
- **cancel** => keep restored solved board and restored status.

## Consequences

- Maintains core policy centralization: adapters execute the branch, they do not invent behavior.
- Preserves restore continuity when user cancels.
- Provides forward-compatible seam if future options are needed (`stay`, `auto_new`, `prompt`).

## Implementation Tracking

- Open issue: [#77](https://github.com/mwigzell/sudoku-zig/issues/77)
