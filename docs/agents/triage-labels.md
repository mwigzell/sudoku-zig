# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Before `ready-for-agent`: walk the player's screen

An issue is not ready until someone has walked it as a player, on each front end in scope (native, web, Android):

1. **Controls:** list every control the issue adds or changes (pad button, menu item, shortcut, typed command) and what each one does.
2. **States:** list every state the board and its settings can be in, including combinations (a mode on with a setting off, no game yet, a given selected).
3. **Each pair:** for every state, say what the player sees and what each control does. Any pair the issue does not answer is an open question for the maintainer.
4. **Saved data:** check each change to saved data against ADR-0018: an older app must still open the file.

Record the answers in the issue (Decisions, acceptance criteria), not in a comment that can be missed.
