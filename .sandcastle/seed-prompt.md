# Seed

You are opening a session that later agents will fork. Read the project's standing context now, so
every fork inherits it without reading it again. Do not perform any task, write any file or make any
commit.

Read these, in this order:

- `CONTEXT.md` — the domain model: what belongs where, and the language of the project.
- Every file in `docs/adr/` — the decisions with their rationale.
- `AGENTS.md` — the structure, standards and gates every step is held to: the gate command, where a
  step's test belongs, and the rules a reviewer checks against. This is the file a fork otherwise
  re-reads from the top on every step.

Then reply with the single word `READY` and stop. If any of those files is missing or unreadable, say
which one instead of `READY`.
