# #4.5 — Slice 3: GameEngine reshape + delegation

Triage: ready-for-human
Status: open
Carved out of `mwigzell/sudoku-zig` issue #4 (Web renderer), Step 5 Slice 3.
Parent shape (verbatim from issue #4):

- `GameEngine = { state: State, transport: FileTransport, data_dir: ?[]const u8, last_save_msg: ?[]const u8 }` — the `io: std.Io` field (game_engine.zig:44) is **gone**; keeps `saveGame(path)` / `openGame(path)`; every byte goes through `FileTransport`.
- Migrate `GameEngine.init(puzzle, std.testing.io)` call sites (the bulk) — behaviour identical.
- Close: full native suite green + `./zig-out/bin/sudoku` save/open smokes green.

## Blocked by

- Issue #4 Step 5 Slice 1 + Slice 2 — implemented GREEN (242/242) but **UNCOMMITTED** (owner commit gate). Slice 3 builds on `src/engine/state.zig` + `src/engine/file_transport.zig` (both currently untracked).

## Open design questions (resolve before step 2 RED — owner gate)

1. `GameEngine.init` signature: takes `transport: FileTransport` (native `main` builds `NativeTransport.make(init.io)`), or transport constructed internally (defeats the point)? Issue text does not pin it.
2. `save_format.zig`'s file-backed `saveGame`/`openGame` still take `io` and do file ops directly — route them through the transport, make them engine methods, or delete?
3. `NativeTransport.readAll` allocates with `std.heap.page_allocator` (no gpa on the transport) — keep, or inject an allocator? If changed, that's a shape change to flag to the owner (do not sneak in).

## Steps

### Step 1 — Shape confirmation (HITL)
Owner answers the three open design questions above; record answers in this issue. Nothing written.

### Step 2 — RED: reshape GameEngine
`GameEngine` drops the `io: std.Io` field; gains `state: State` + `transport: FileTransport`. `saveGame(path)` / `openGame(path)` kept, delegate to `self.transport`. Write tests first against a test transport: bytes pass through unchanged, `data_dir` / `last_save_msg` behaviour preserved, codec round-trip still via `State`. Expect the migration failures (call sites still pass `std.testing.io`) to be the red signal.

### Step 3 — GREEN: delegation + migration (the bulk)
Implement delegation in `game_engine.zig`. Migrate every `GameEngine.init(puzzle, io)` call site (main.zig + tests) to the confirmed Step-1 shape. Native `main` supplies `NativeTransport.make(init.io)`. Behaviour byte-identical.

### Step 4 — Resolve the file-backed save_format fns (per Step 1 answer)
Route `save_format.zig` save/open through the transport, or delete them — per the owner's Step-1 ruling. No guessing.

### Step 5 — Close
`zig build test` full suite green; `echo`-driven smoke: `./zig-out/bin/sudoku` save then open round-trip; `zig fmt --check` clean; diff scoped to engine + call sites. Commit + push owner-gated (push currently HELD).

## Acceptance criteria

- [ ] `GameEngine` has no `std.Io` field; `saveGame`/`openGame` route every byte through `FileTransport`
- [ ] All `GameEngine.init(puzzle, std.testing.io)` call sites migrated; no test or prod code references an engine io field
- [ ] `data_dir` / `resolveSavePath` / `last_save_msg` unchanged (transport stays dumb)
- [ ] Full native suite green; `./zig-out/bin/sudoku` save/open smokes green; wire format `SUD0` unchanged

## Comments
