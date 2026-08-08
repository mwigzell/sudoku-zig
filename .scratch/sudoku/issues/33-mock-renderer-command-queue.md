Triage: ready-for-agent

## What to build

Add a command queue to `MockRenderer` so that tests can drive `Sudoku.run()` with canned input instead of blocking on real stdin. Currently the stub returns `.error_msg` — breaking the loop after one tick. Replace it with deterministic playback.

### Design decisions

1. **`MockRenderer.command_queue: []const command.ParseCommandResult`** — pre-built slice of parsed results. Tests construct commands, not raw strings, keeping the same precision as `handleResult` tests.
2. **`MockRenderer.queue_index`** — advances on each call to `getCommandInput()`. Reaching end-of-queue returns `.quit` to break the `while(true)` loop cleanly.
3. **No string parsing in MockRenderer.** The queue holds `ParseCommandResult`, same type that `handleResult()` receives today. Tests parse once (or construct directly) and replay through `run()`.

### Steps

| # | Description |
|---|-------------|
| 1 | ✅ Add `command_queue: ?[]const command.ParseCommandResult` and `queue_index: usize` to `MockRenderer` struct. |
| 2 | ✅ Update `MockRenderer.init()` to accept an optional command slice. Default to empty (existing behavior). |
| 3 | ✅ Replace `getCommandInput()` stub with queue cycling logic — return next entry, advance index, EOF → `.quit`. |
| 4 | ✅ MockRenderer's own unit tests pass (line 85-132) — ordered playback, exhaustion → quit, error_msg entries. |

### Acceptance criteria

- [x] 1. `MockRenderer.getCommandInput()` returns queued commands in order and `.quit` on exhaustion.
- [x] 2. MockRenderer's own unit tests pass (line 85-132).
- [x] 3. All existing tests still pass.

### Superseded steps

The following e2e `run:` tests originally planned via MockRenderer were superseded by ~~Issue 34~~, which uses AsciiRenderer + MockSource instead (testing real dialog intercepts):

| Original Step | Status |
|---|---|
| `"run: fill → save → quit"` | Superseded — now in Issue 34 |
| `"run: new command resets board and history"` | Superseded — now in Issue 34 |
| `"run: save_as writes file and re-renders"` | Superseded — now in Issue 34 |
