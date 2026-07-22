/** Origin: grilling — Command → Event seam (ADR-0002) was aspirational and diverged from implementation */

Status: ready-for-agent

Triage date: 2025-07-23

Triage notes:
- Spec is thorough — well-scoped 6-step plan, clear Event shape, detailed acceptance criteria
- All 6 steps NOT STARTED in code; CommandResult still return type (game_engine.zig:5)

- GameEngine still generic over renderer with internal render() calls (game_engine.zig:9, line 68)

- Tests still use MockRenderer and assert on internal Board state via engine.board.isConflicting()

- Issue 21 would resolve naturally alongside this once Event seam lands, but is separate work
- Issue 13 is a sibling (both touch the wiring layer), not a dependency. After issue 20,
   main.zig still passes `*R` to Sudoku.init — Sudoku just stops forwarding it to GameEngine
   and keeps it for use inside run(). The renderer call moves from exec() to the Event
   switch in run(); no CLI parsing required.

## Goal
Morph `CommandResult` into the **Event** type defined in CONTEXT.md, remove the renderer dependency from GameEngine entirely, and have `exec()` return BoardView snapshots so `Sudoku.run()` owns rendering. MockRenderer drops out of GameEngine tests.

---

## Context
PRD spec: *"Event snapshot describes the resulting state … the Renderer consumes this, not the Board or Grid themselves."*

- **Today**: `GameEngine(comptime R)` is generic over a renderer type; exec() calls `self.renderer.render(BoardView)` as a side effect.
- **Tests** assert on internal Board fields (`engine.board.isConflicting(...)`) — coupled to domain implementation.
- **MockRenderer** exists only because GameEngine needs something to call render(); once exec returns BoardView, mock is no longer relevant for those tests.
- **BoardView already exists** as the read-only borrowed lens — it *is* the Event payload. No copying needed.

## Event type (agreed shape)

```zig
pub const Event = union(enum) {
    ok: struct {
        board_view: BoardView,
        msg: ?[]const u8, // null when no user-facing note; populated later for "win" etc.
    },
    error_msg: []const u8,
};
```

- `.ok.board_view` — the same `Board.BoardView` borrowed lens renderer already uses today. No copy.
- `.ok.msg` — optional user-facing message string; null for normal fills.
- `.error_msg` — just a string. The caller shows it (waitAck) and does NOT render.

---
## Steps (each builds on previous, each is a vertical slice)
**Pre-requisite**: none. Issue 13 is a sibling (both touch the wiring layer). This can run immediately.


## Blocked by

(none)

### Step 1: Define Event union in game_engine.zig
**File**: `src/game_engine.zig`
- Add `Event` union type as agreed above.
- Keep existing `CommandResult` temporarily (both exist) so we don't break callers yet.


### Step 2: Rename `ParseCommandResult.invalid_message` → `error_msg` for naming consistency
**File**: `src/command.zig`
- Tag name `invalid_message` is an awkward adjective-noun mashup. Rename to `.error_msg` to match Event's failure branch shape.
- This renames the tag in `ParseCommandResult` and updates every caller (`sudoku.zig`'s parse switch + all command tests). Straightforward mechanical change.

### Step 3: Remove renderer from GameEngine struct
**Files**: `src/game_engine.zig`, `src/sudoku.zig`
- Drop `GameEngine(comptime R)` generic parameter → just `GameEngine`.
- Remove `renderer: *R` field.
- Remove `.render()` and `.fillAndRender()` methods (no longer needed).
- Update `GameEngine.init(puzzle_str, r)` → `GameEngine.init(puzzle_str)` — no renderer param.

### Step 4: Replace internal render() calls with Event returns in exec()
**Files**: `src/game_engine.zig`, `src/sudoku.zig`
- In `tryFill()` and `tryClear()`: replace `self.renderer.render(self.board.asView())` with returning `Event.ok { board_view, null }`.
- The `.error_msg` path stays as-is (returns string via event tag).
- Update `Sudoku.run()`: switch on Event `.ok | .error_msg`; on `.ok`, call renderer.render(event.board_view) and optionally show event.msg.
- Remove initial `try self.engine.render()` splash render (now done first in the loop or as separate Event from init if needed).

### Step 5: Update GameEngine tests — swap MockRenderer for direct BoardView assertions
**File**: `src/game_engine.zig` (test blocks)
- Every test that currently does `var mock = MockRenderer.init(); engine = ...init(puzzle, &mock)` → drops the mock.
- Tests call `exec(cmd)`, switch on returned Event, assert on `event.ok.board_view.get(row, col)` etc.
- Remove `const mock_renderer = @import("...")` from game_engine.zig tests.
- Run `zig build test` — all GameEngine tests pass through BoardView directly.

### Step 6: Clean up Sudoku integration tests and MockRenderer usage
**Files**: `src/sudoku.zig`, `src/root.zig`
- Update Sudoku's `init()` to not pass renderer to engine anymore.
- If MockRenderer is no longer needed anywhere, remove it (or keep for non-engine tests only).
- Run full test suite + `zig build cov`.

---

## Acceptance Criteria
- [ ] `Event` union defined in `game_engine.zig`, replacing `CommandResult`
- [ ] GameEngine no longer generic over renderer type — just `GameEngine`
- [ ] Renderer param removed from `GameEngine.init()` signature
- [ ] All internal `self.renderer.render(...)` calls replaced with returning `Event.ok { board_view, null }`
- [ ] `.error_msg` path in exec still works (e.g., attempt to modify a given cell)
- [ ] `Sudoku.run()` main loop switched: on `.ok` it calls renderer.render(board_view), no longer empty
- [ ] GameEngine tests inspect `Event.ok.board_view` directly — MockRenderer removed from game_engine.zig test suite
- [ ] All tests pass; coverage maintained (`zig build cov`)
