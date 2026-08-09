## Triage
closed

### Notes
- Axis: code safety / maintainability. Six independent sources of truth for command list means no compile-time guarantee of sync.
- Depth: medium refactor — touches parse.zig, game_engine.zig, and dependent code.

## Parent
`.scratch/sudoku/prd.md`

## Working mode
HITL. Design the comptime table first; TDD per step for each surface refactor.

## What to build
Replace `CommandNames` (struct-of-consts) with a **comptime table** as single source of truth — an ordered array that derives all six current surfaces.

### Current problem

The project has **six independent sources of truth** for the command list. Adding or removing a command means touching all six with no compile-time guarantee they stay in sync:

| # | Surface | Location | Purpose |
|---|---------|----------|---------|
| 1 | `CommandTag` enum | `parse.zig:16` | Union discriminant |
| 2 | `CommandNames` struct-of-consts | `parse.zig:19-28` | Display names + string accessors |
| 3 | `Command` union | `parse.zig:31-40` | Per-tag payload (void, FillData, etc.) |
| 4 | `AvailableCommands` bool flags | `game_engine.zig:10-18` | Runtime enable/disable per game state + getNames() loop |
| 5 | exec() switch | `game_engine.zig:281+` | Command handler dispatch |
| 6 | parse() default cmds array | `parse.zig:79` | Full command list for backward compat parser |

No structural relationship between any of them. You can silently add a tag but forget the display name, exec case, or availability bit. Zig's compiler won't catch the mismatch until runtime (or never).

### Confirmed Decisions

- **Eliminate `CommandNames.fill`** → accessor fn e.g. `Command.getName(.fill)` on the comptime table.
- **AvailableCommands derives names from `CommandTag` enum** — iterate tag values, look up in table.
- **Comptime invariant test** if achievable (tag count == table length >= exec cases).

### Why ordered array, not StaticStringMap?
Zig 0.17's `StaticStringMap` doesn't iterate its keys. An array gives both comptime lookup AND enumeration for building `getNames()`, the parse() default list, and exec() switch coverage.

### Sketch shape
```zig
pub const CommandTableEntry = struct { tag: CommandTag, name: []const u8 };
pub const Commands: []*const CommandTableEntry = &.{
    .{ .tag = .fill, .name = "Fill" },
    ... // one per tag, ordered to match enum layout
};
```

## Steps

| Step | Goal | Seam | TDD Status |
|------|------|------|------------|
| 1 | Define `CommandTableEntry{ tag, name }` comptime table | `command.Commands[]` — ordered array lit | ✅ GREEN |
| 2 | Write `getName(tag) []const u8` accessor | `command.getName(.fill)` >= `"Fill"` | ✅ GREEN |
| 3 | Replace `parse()` default cmds array with table derive | `parse()` calls use `Commands` | ✅ GREEN |
| 4 | Replace `AvailableCommands.getNames()` to iterate enum + getName() | iterates tags >= derives names | ✅ GREEN |
| 5 | Remove `CommandNames` struct entirely | Deleted, refs updated | ✅ GREEN — all callers migrated to getName(tag) |
| 6 | Comptime invariant test (`@typeInfo(CommandTag).field_names.len == Commands.len`) | compile error on drift | ✅ GREEN |

## Blocked by
(none — steps approved, TDD started per step 1)
