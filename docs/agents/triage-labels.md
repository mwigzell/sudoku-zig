# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Specified with tickable steps; sandcastle can run it |
| `ready-for-human`          | `ready-for-human`    | Cannot be delegated: an owner decision, or no runnable proof |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

**`ready-for-agent` means a run can execute it, not that one cycle closes it.** Sandcastle (`npm run sandcastle -- --issue N`) runs the issue's `## Steps` one step per iteration: a fresh implementer, a fresh reviewer, then the host ticks that step, and a person accepts or drops the branch at the end. The human is in the loop per step, which is why a cloud LLM is not a problem; a multi-step issue with tickable steps is exactly the case the harness is for, so it stays `ready-for-agent`.

Use `ready-for-human` only when the work itself cannot be delegated: a decision that is the owner's, a task with no executable step or no proof the branch can carry, or access the run does not have. A step that needs a connected device is still runnable: it adds or updates the scenario, and the close and push gates run that scenario on a device — the scenario is the artifact, and the evidence is what accept reads.

## Before `ready-for-agent`: walk the player's screen

An issue is not ready until someone has walked it as a player, on each front end in scope (native, web, Android):

1. **Controls:** list every control the issue adds or changes (pad button, menu item, shortcut, typed command) and what each one does.
2. **States:** list every state the board and its settings can be in, including combinations (a mode on with a setting off, no game yet, a given selected).
3. **Each pair:** for every state, say what the player sees and what each control does. Any pair the issue does not answer is an open question for the maintainer.
4. **Saved data:** check each change to saved data against ADR-0018: an older app must still open the file.
5. **Steps:** when a run will step the issue, `## Steps` must be `- [ ]` items — one step per run iteration — or the planner refuses it. The shape and what a step must say are in "Steps a run can take" in `docs/agents/issue-tracker.md`.
6. **Parity window:** an issue whose steps change a contract parity observes declares a step-scoped `## Parity window`, and one that changes such a contract and carries no window is not `ready-for-agent`. The shape and the gate are in "Parity window" in `docs/agents/issue-tracker.md`.

Record the answers in the issue (Decisions, acceptance criteria), not in a comment that can be missed.

The `## Android scenarios` section is optional. Triage adds it only when it already knows which existing device method proves the change; it is not a `ready-for-agent` condition, because closeout derives the required set from the branch. "A device step is still runnable" above is why a device step is not `ready-for-human` on its own. See "Android scenarios" in `docs/agents/issue-tracker.md`.
