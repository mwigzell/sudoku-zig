# ADR-0023 — Core owns the status line; a command speaks or stays silent

Status: accepted
Date: 2026-11-19
Related: ADR-0019 (core owns the selected cell; every front end draws core's frame), ADR-0011 (layer ownership)

## Context

The engine builds the text for a command in a scratch buffer, folds it into the durable status, and hands the result out as part of the frame every front end draws. The durable status outlives the command that wrote it: it is drawn now, saved into the game file, and restored at the next launch.

Two things follow, and both need a home:

- A command may say nothing. The board may have changed, or it may not have. Something has to decide whether the previous sentence still describes the board.
- Commands reach the board by more than one route. Gameplay commands are routed by the engine; menu actions are routed by the shell and the flow. Both change what the player sees.

If each route, or each call site, decides for itself whether the line is cleared or kept, the answer drifts: the same silence means different things in different places, and a front end can suppress a line core deliberately kept.

## Decision

- **Core owns the status line.** It is produced in one place, from one rule, for every command — engine-routed and menu-routed alike. No route sets it directly.
- **A command that writes to the scratch buffer sets the durable status to what it wrote.**
- **A command that writes nothing leaves the durable status alone.** Keeping is the default, not a per-site choice; there is no clear-or-keep argument on the seam.
- **A command that changes the board must write.** Silence is legitimate only when the board is unchanged. A board-changing command that says nothing leaves a sentence that no longer describes the game, which is a defect, not a policy option.
- **A command that has something special to add appends it.** A conflict or a win follows the command's own sentence rather than replacing it.
- **Front ends draw the status they are handed.** Non-null is drawn; null draws nothing. No front end decides whether a status core produced should be shown.

## Consequences

- One rule, stated on the seam, decides what the player sees after any command. Changing the policy means changing that one place.
- The durable status is a statement about the board, not about the last action, so a save taken after a command that changed nothing still describes the game.
- A board-changing command that forgets to speak is a visible bug rather than a silent choice, which is what makes the rule safe to hold.
- Parity compares the status a `show_game` step carries, so a front end that draws something different from core fails the gate.
- A new command joins the seam; it does not get its own way of setting the line.
