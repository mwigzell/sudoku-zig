# #4.5 — Slice 3: GameEngine reshape + delegation

Triage: ready-for-human
Status: closed
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

### Step rules

One step at a time, owner go between steps. **The tree does not compile after step 2 and stays red through step 14 — do not try to keep it green mid-migration.** First expected-green check is step 15.

### Step 3 — `save.zig` — **DONE** (in tree, uncommitted)

- Drop the `engine.io` arg from the `saveGame` call; `engine.board` → `engine.state.board`; test init sites → `NativeTransport.make(std.testing.io)`.

### Step 4 — `save_as.zig` — **DONE** (in tree, uncommitted)

Same as step 3 (drop `engine.io` arg, nest `engine.state.board`, migrate test init sites).

### Step 5 — `open.zig` — **DONE** (in tree, uncommitted)

Replace raw `std.Io` reads with `engine.transport.readAll`; `getDataDir` → io-free `computeDataDir`; `engine.board` → `engine.state.board`; migrate test init sites.

### Step 6 — `new.zig` — **DONE** (in tree, uncommitted)

Same as step 5 (raw file reads → `engine.transport.readAll`, io-free `computeDataDir`, nest state, migrate test init sites).

### Step 7 — `fill.zig` — **DONE** (in tree, uncommitted)

`engine.board` → `engine.state.board`, `engine.history` → `engine.state.history`; migrate test init sites.

### Step 8 — `clear.zig` — **DONE** (in tree, uncommitted)

Same as step 7.

### Step 9 — `undo.zig` — **DONE** (in tree, uncommitted)

Same as step 7.

### Step 10 — `redo.zig` — **DONE** (in tree, uncommitted)

Same as step 7.

### Step 11 — `quit.zig` — **DONE** (in tree, uncommitted)

Migrate test init sites (census found `GameEngine.init(` here).

### Step 12 — `sudoku.zig` — **DONE** (in tree, uncommitted)

`Sudoku.init` builds `NativeTransport.make(host.io)` for the engine + best-effort dir-create call (per decision 2).

### Step 13 — `host.zig` — **DONE** (in tree, uncommitted)

Host test `GameEngine.init` sites → `NativeTransport.make(std.testing.io)`.

### Step 14 — `save_format.zig` — **DONE** (in tree, uncommitted)

Delete file-backed `saveGame`/`openGame` (~lines 121–196) + their io + their tests; keep pure `toSaveFormat(state, &_)` / `fromSaveFormat(alloc, buf)` and their tests.

### Step 15 — Close (owner-gated) — **DONE** (2026-09-11): 241/241 green (`zig build test` + `zig test src/main.zig -lc`); quit + save smokes rc 0 (`sudoku_save.sud` written through NativeTransport); `zig fmt --check` clean; `git diff` scoped to the 15 slice files. **Commit + push awaiting owner go.**

`zig build test` ≥ 242 green; `zig build run` quit/save/open smokes; `zig fmt --check` clean. Commit + push only on owner go (push HELD).

## Acceptance criteria

- [ ] `GameEngine` has no `std.Io` field; `saveGame` / `openGame` route every byte through `FileTransport`
- [ ] All `GameEngine.init(puzzle, std.testing.io)` call sites migrated to `(puzzle, NativeTransport.make(std.testing.io))`; no test or prod code references an engine io field
- [ ] Nested state: `engine.state.board` / `engine.state.history` everywhere; `data_dir` / `last_save_msg` behaviour unchanged (transport stays dumb)
- [ ] `save_format` is a pure State codec (no GameEngine, no io); wire format `SUD0` unchanged
- [ ] Full native suite green; quit/save/open smokes green at `./zig-out/bin/sudoku`

## Comments

- **Open follow-on (raised in Step 2, 2026-09-11):** `openGame` frees `transport.readAll`'s `[]u8` with `page_allocator` (game_engine.zig:111–112). That is correct for the Native arm, but if the **Wasm arm** (`issue #17`, a later roadmap slice) allocates its `readAll` result from a different allocator, this `free` is cross-allocator. When the Wasm arm lands, `readAll` must document which allocator owns the `[]u8` (ideally pin it to `page_allocator`, or make `free` part of the transport vtable). Not fixed in Step 2 (out of scope; Native-only).
