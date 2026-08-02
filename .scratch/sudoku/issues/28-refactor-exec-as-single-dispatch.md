Status: ready-for-human





## Parent

`.scratch/sudoku/prd.md` (refactor)

## What to build

Two things: **one file per command** and **restore exec() as the single dispatch surface**.

### Problem 1 — game_engine.zig should not be a monolith

Each command's implementation should live in its own file under `src/command/`.
This is hygiene: stop stuffing everything into one file. exec()'s switch body
already has inline paragraphs for fill/clear/undo/redo — each of those deserves
its own module.

Related modules that belong with commands move too: `legend.zig`,
`disambiguate.zig`, `path.zig` (save/open I/O helpers), and `undo.zig`
(MutationHistory lives next to undo).

### Problem 2 — exec() isn't the dispatch surface it should be

Currently `handleResult()` in `sudoku.zig` intercepts `.quit`, `.save`, and
`.open` before they reach `exec()`, bloating the dispatch layer with path
resolution, filename persistence, and message construction. Root cause:
`GameEngine.init()` took no Io handle, so save/open couldn't live in exec().
Fix by threading Io through GameEngine's constructor.

### After — one file per command

```
src/command/
  disambiguate.zig   ← moved
  fill.zig           ← new (extracted from game_engine)
  clear.zig          ← new
  path.zig           ← moved
  legend.zig         ← moved
  mutation_history.zig  ← renamed from undo.zig, moved
  undo.zig           ← new (command handler)
  redo.zig           ← new
  save.zig           ← new (from handleResult interception)
  open.zig           ← new (from handleResult interception)
```

### After — exec()

```zig
fn exec(self: *@This(), cmd: Command) Event {
    switch (cmd) {
        .fill => |data| command.fill.execute(self, data),
        .clear => |data| command.clear.execute(self, data),
        .undo   => |_|  command.undo.execute(self),
        .redo   => |_|  command.redo.execute(self),
        .save   => |_|  command.save.execute(self),
        .open   => |d|  command.open.execute(self, d.path),
        .quit   => |_|  eventQuit(), // exhaustiveness stub — production never hits
    }
}
```

### After — handleResult()

```zig
fn handleResult(...) {
    .valid => |cmd| {
        if (cmd == .quit) return true;  // still needs early exit, kept thin
        
        const event = try self.engine.exec(cmd);
        return try self.handleEvent(out, in_, renderer, event);
    }
}
```

### Fields that move from Sudoku → GameEngine

| Field | Current owner | New owner | Reason |
|-------|---------------|-----------|--------|
| `_dataDir: ?[]u8` | Sudoku | GameEngine | Only used by save/open commands, both now in exec() |
| `_filename: ?[]u8` | Sudoku | GameEngine | Persists filename across saves, accessed by save handler |
| `_lastSaveMsg: ?[]u8` | Sudoku | GameEngine | Carries feedback message back through Event.ok.msg |

## Steps (vertical slice)

| Step | Description | Target file(s) | Tests |
|------|-------------|----------------|-------|
| 1 | Add `_io: std.Io` field to GameEngine struct; update `init(puzzle_str, io)` to accept and store Io. Also add `_dataDir`, `_filename`, `_lastSaveMsg` fields here (from Sudoku). No behavioral change — just the constructor signature + struct shape. | `game_engine.zig` | Compile + existing tests pass with new init signature |
| 2 | Create `src/command/`. Move `undo.zig` → `command/mutation_history.zig`. Move `path.zig`, `legend.zig`, `disambiguate.zig` into `command/`. Update all import paths that reference them. | multiple (structural only) | Compile, 0 behavioral changes — pure import surgery |
| 3 | Extract existing exec() cases: fill → `command/fill.zig`, clear → `command/clear.zig`, undo → `command/undo.zig`, redo → `command/redo.zig`. Each exports `fn execute(g: *GameEngine, ...) Event`. Replace inline switch bodies with calls. | `src/command/*.zig`, `game_engine.zig` | Existing fill/clear/undo/redo tests still pass — same behavior, different home |
| 4 | Add `command/save.zig` and `command/open.zig` — move save/open logic from handleResult interception blocks into exec() cases. Uses GameEngine's `_io` field for disk I/O. Path resolution via `command/path.zig`. | `src/command/save.zig`, `src/command/open.zig`, `game_engine.zig` | Tests #154-#159 still pass; .save/.open now go through exec() |
| 5 | Collapse handleResult: remove .save and .open interception blocks. Every command except quit → `exec(cmd)` + `handleEvent(event)`. Remove `_dataDir`, `_filename`, `_lastSaveMsg` from Sudoku struct (now on GameEngine). | `sudoku.zig`, `game_engine.zig` | All integration tests pass through simplified path |
| 6 | Update all test sites constructing GameEngine to pass `std.testing.io` as second arg. ~50 call sites. Update root.zig imports for new module paths. Run full suite + coverage. | multiple | All 179+ tests pass, coverage holds |

### What handleResult still intercepts (and why)

Only `.quit`. Must return `true` immediately to break the command loop. The
exec() switch keeps `.quit => return .ok` for exhaustiveness but production never
calls it through exec(). Acceptable — early exit is a control-flow necessity, not a side effect.

## Acceptance Criteria

- [ ] `GameEngine.init()` signature is `init(puzzle_str, io) → !GameEngine`
- [ ] `_io` field stored on GameEngine struct  
- [ ] Each command (fill/clear/undo/redo/save/open) has its own file under `src/command/`
- [ ] exec() switch is flat: one function call per case, no inline logic
- [ ] MutationHistory moved to `command/mutation_history.zig`, lives beside undo handler
- [ ] legend/disambiguate/path moved into `src/command/` sub-folder  
- [ ] handleResult dispatches every command except quit through exec() — no fat switch
- [ ] `_dataDir`, `_filename`, `_lastSaveMsg` on GameEngine struct (removed from Sudoku)
- [ ] Save and Open handled in exec() (no interception in handleResult)
- [ ] All existing tests pass, no behavioral changes
- [ ] Coverage holds at or above 98%
