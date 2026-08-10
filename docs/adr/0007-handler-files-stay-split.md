# ADR-0007 — GameEngine handler files stay split

Status: accepted
Date: 2026-08-11

## Context

The `src/engine/` directory contains per-cmd handler files: `fill.zig`, `clear.zig`, `undo.zig`, `redo.zig`, etc., each a thin delegate inside `GameEngine`. A proposed deepening suggested collapsing them back into `game_engine.zig` to reduce file count and keep the engine "self-contained."

Two concerns counter this:
- The AI editor (pi) reads files in full before editing. When a single file grows beyond ~800 lines, the read payload risks truncation inside the model's context window — edits fail mid-operation.
- Cognitive load: reasoning about one command's behaviour should not require scrolling through eight other handlers plus Board state, config wiring, and test scaffolding.

## Decision

**Handler files stay as separate modules.** Each command that mutates engine state gets its own `.zig` file under `src/engine/`, even if it is only 20–40 lines. The split is a deliberate editing-safety mechanism:

- Small files guarantee the AI agent can read, edit, and write them without truncation in a single pass
- Neighboring handlers become visible in directory listings, making it easy to see what commands exist without opening the engine
- The game engine itself stays a coordinator — `game_engine.zig` owns state fields and wiring, not command logic

## Consequences

- File count is higher than a "consolidated" design would produce, but each file stays in an easily-bounded read window
- Future commands that need richer logic (batch edits, transactional undo stacks) can grow their own file without bloating the engine
- If a handler grows large enough to warrant internal splitting (e.g., save/load serialization becomes its own sub-module), that earns a structural decision — not this boundary
