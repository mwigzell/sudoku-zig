# #4.5 — Slice 3: GameEngine reshape + delegation

Triage: ready-for-human
Status: open
Standalone ticket (web renderer roadmap, Step 5 Slice 3). Self-contained — do not need issue #4 to work it. GitHub: mwigzell/sudoku-zig#16.

## Target shape

- `GameEngine = { state: State, transport: FileTransport, data_dir: ?[]const u8, last_save_msg: ?[]const u8 }` — the `io: std.Io` field is **gone**; keeps `saveGame(path)` / `openGame(path)`; every byte goes through `FileTransport`.
- Migrate `GameEngine.init(puzzle, std.testing.io)` call sites (the bulk) — behaviour identical.
- Close: full native suite green + save/open smokes green.

## Locked decisions (owner, 2026-09-06)

1. **State is nested (Option B)** — `engine.board` → `engine.state.board`, `engine.history` → `engine.state.history` across all files. No flat-state escape hatch.
2. **`getDataDir` split** — io-free path computation stays in `path.zig` (`computeDataDir`) for engine/handlers; the best-effort `createDirPath` moves to native startup (`Sudoku.init`, which holds io). Create is log-and-continue today, so behaviour is preserved.
3. **Delegation + codec** — `init(puzzle, transport: FileTransport)`; `saveGame(path)` / `openGame(path)` delegate to `self.transport`; `save_format`'s two io file fns deleted (AC: save_format is a pure State codec).

## Steps

### Step 1 — RED — **DONE** (in tree, uncommitted)
Test in `src/engine/game_engine.zig` (~line 207): `"slice 3: GameEngine holds State + FileTransport; save/open io-free"` — drives the target shape (`init(puzzle, NativeTransport.make(io))`, `engine.state` round-trip). Red signal: `error: expected type 'Io', found 'FileTransport'`. Baseline before RED: 242/242 green at `b441255`.

### Step 2 — GREEN: reshape GameEngine
`engine/game_engine.zig`: struct per parent shape (io gone); `init(puzzle_str, transport)`; `deinit` frees `state.history` + `data_dir` + `last_save_msg`; `saveGame(path)` / `openGame(path)` move bytes via `self.transport` — `openGame` frees the `readAll` result with page_allocator.

### Step 3 — Migration (the bulk)
- Handlers `save.zig`, `save_as.zig`, `open.zig`, `new.zig` — drop `engine.io` args; `open.zig` / `new.zig` replace raw `std.Io` file reads with `engine.transport.readAll`; `getDataDir` → io-free `computeDataDir`.
- `fill.zig`, `clear.zig`, `undo.zig`, `redo.zig` — `engine.board` → `engine.state.board`, `.history` → `.state.history`.
- `sudoku.zig` — `Sudoku.init` builds `NativeTransport.make(host.io)` for the engine + dir-create call (per decision 2).
- Every remaining `GameEngine.init(puzzle, std.testing.io)` site (host tests, census: `grep -rn "GameEngine.init(" src/`) → `NativeTransport.make(std.testing.io)`.

### Step 4 — save_format cleanup
Delete file-backed `saveGame`/`openGame` (~lines 121–196) + their io; keep pure `toSaveFormat(state, &_)` / `fromSaveFormat(alloc, buf)` and their tests.

### Step 5 — Close (owner-gated)
`zig build test` ≥ 242 green; `zig build run` quit/save/open smokes; `zig fmt --check` clean. Commit + push only on owner go (push HELD).

## Acceptance criteria

- [ ] `GameEngine` has no `std.Io` field; `saveGame` / `openGame` route every byte through `FileTransport`
- [ ] All `GameEngine.init(puzzle, std.testing.io)` call sites migrated to `(puzzle, NativeTransport.make(std.testing.io))`; no test or prod code references an engine io field
- [ ] Nested state: `engine.state.board` / `engine.state.history` everywhere; `data_dir` / `last_save_msg` behaviour unchanged (transport stays dumb)
- [ ] `save_format` is a pure State codec (no GameEngine, no io); wire format `SUD0` unchanged
- [ ] Full native suite green; quit/save/open smokes green at `./zig-out/bin/sudoku`

## Comments
