## What to build

Add a command queue to `MockRenderer` so that `Sudoku.run()` executes end-to-end with canned input instead of blocking on real stdin. Currently `getCommandInput()` returns `.error_msg` — breaking the loop after one tick. Replace it with deterministic command playback.

### Design decisions

1. **`MockRenderer.command_queue: []const command.ParseCommandResult`** — pre-built slice of parsed results. Tests construct commands, not raw strings, keeping the same precision as `handleResult` tests.
2. **`MockRenderer.queue_index`** — advances on each call to `getCommandInput()`. Reaching end-of-queue returns `.quit` to break the `while(true)` loop cleanly.
3. **No string parsing in MockRenderer.** The queue holds `ParseCommandResult`, same type that `handleResult()` receives today. Tests parse once (or construct directly) and replay through `run()`.

### Steps

| # | Description |
|---|-------------|
| 1 | Add `command_queue: ?[]const command.ParseCommandResult` and `queue_index: usize` to `MockRenderer` struct. |
| 2 | Update `MockRenderer.init()` to accept an optional command slice. Default to empty (existing behavior). |
| 3 | Replace `getCommandInput()` stub with queue cycling logic — return next entry, advance index, EOF → `.quit`. |
| 4 | ✅ Add e2e test: `"run: fill → save → quit"` — verify call_count == expected renders. |
| 5 | Add e2e test: `"run: new command resets board and history"` — fill cell, run `new`, assert fresh puzzle + cleared undo. |
| 6 | Add e2e test: `"run: save_as writes file and re-renders"` — queue save_as + quit, assert call_count bump. |

### Acceptance criteria

- [x] 1. `MockRenderer.getCommandInput()` returns queued commands in order and `.quit` on exhaustion.
- [x] 2. `Sudoku.run()` completes without blocking using only MockRenderer input.
- [x] 3. Test `"run: fill → save → quit"` passes — calls the full while loop.
- [ ] 4. Test `"run: new command resets board and history"` passes.
- [ ] 5. Test `"run: save_as writes file and re-renders"` passes.
- [ ] 6. All existing tests still pass (>=206).
