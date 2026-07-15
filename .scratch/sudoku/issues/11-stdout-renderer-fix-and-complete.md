Status: ready-for-agent

## Working mode
HITL (Human In The Loop). One TDD cycle per session.

## Parent

`.scratch/sudoku/prd.md`

## What to build

Fix and complete `StdoutRenderer` so it produces visible output of the full 9×9 Sudoku board when run from `main.zig`. Currently it prints only a header border line and takes an externally-injected `Io.Writer` — both wrong.

### Current state (broken)
- `init(buf: []u8)` requires a caller-supplied buffer via `Io.Writer.fixed()` — violates the spirit of a *Std* renderer that should own its output destination
- Only writes `+-------+--------\n` border line; cells are not rendered at all
- Caller (`main.zig`) must manually manage stdout plumbing and dump the buffer contents after render completes
- Produces garbage output beyond the first line because uninitialised buffer bytes leak out

### What to fix

2. **Render the full board.** Replace the placeholder print with loop that fills the snapshot from `RenderSnapshot.cells[row][col]`:
   - Row labels (1-9), column labels (A-I)
   - Box boundary characters (`+`, `-`, `|`), cell values, and empty cells
   - Cell values render as single chars: `' '` for empty, `'1'`–`'9'` for digits
   - No locked/user distinction yet — all cells show raw value
   - `RenderCell.locked` and `RenderCell.conflicting` in contract but not visually distinguished
   - Respects `RenderCell.conflicting: bool` for future conflict highlighting wire

### Acceptance criteria

- [ ] Running `zig build run` prints a complete 9×9 ASCII Sudoku board to terminal
- [ ] All 18+ existing tests still pass at comparable coverage
- [ ] Locked cells visually distinct from empty/user-filled cells in output
- [ ] Conflict flag field exercised in rendering (can be stub logic; data shape proves seam works)

## Design note: why `init()` would take two parameters (when testable under server mode)

When we refactor `init()` to accept a file handle, it takes **both** `io: std.Io` and `out_file: std.Io.File`. Not because there are two separate I/O responsibilities, but because Zig 0.17 splits "which destination" from "the async execution context":

| Parameter | At runtime (`main.zig`) | In tests | What it controls |
|-----------|--------------------------|----------|--------------------|
| `io` | `init.io` (from `std.process.Init`) | `std.testing.io` | Async scheduler, cancellation, timing — the "world handle" for cooperative I/O |
| `out_file` | `std.Io.File.stdout()` | temp file from `io.openFile()` | Which actual file descriptor receives writes |

Both are needed because every Zig 0.17 blocking call threads through `io` for scheduling, but the *destination* (stdout vs temp file) is independent.

We don't need both right now — the TTY guard (`isTty()` check in the test) avoids server-mode deadlocks without parameter changes. The two-param refactor is worth doing later when we want to verify rendered output content in tests.

## Session log

### 2026-07-14: `zig build test` hang fix (build.zig)

**Problem:** `zig build test` panicked at build time with `assert(argv.len >= 1)`. This was caused by a previous session attempt that replaced `addRunArtifact(test)` with `addSystemCommand(&.{})` and then called `addArtifactArg(check)` afterwards. Zig 0.17's `addSystemCommand` asserts its argument list starts non-empty, so passing an empty slice and appending after crashed the build immediately.

**Deeper root cause:** On x86_64 + Zig 0.17, `addRunArtifact(test)` always enables server-mode IPC (`--listen=-`) through `.zig_test` stdio mode. The maker process and test binary contend over the same stdin/stdout pipes for their own IPC, causing a hang.

**Attempted but rejected:**
- `addSystemCommand(&.{})` + `addArtifactArg(check)` → build-time panic (empty argv assertion)
- `.test_runner = .{ .path = ..., .mode = .simple }` on the compile step → Zig still resolved `.path` as a file reference and failed with `file_hash IsDir`/`FileNotFound`

**Working fix:** Replaced `addRunArtifact(check)` with:
```zig
const run_tests = b.addSystemCommand(&.{
    "/bin/sh",
    "-c",
    "exec $0",
});
run_tests.addArtifactArg(check);
```
The `$0` trick passes the resolved artifact path as the shell's positional arg, and `exec` replaces sh with the actual test ELF. This runs entirely outside Zig's server-mode IPC orchestration.

**Important:** `.use_llvm = true` must be **kept** on the `addTest()` options. It controls the compilation backend (provides debug symbols kcov needs), not the runner protocol. Removing it was a red herring — tests hang regardless of backend; the hang is purely from `addRunArtifact`'s server-mode IPC, which this fix sidesteps. Keeping `.use_llvm = true` means kcov still works.

**Result:**
- `zig build test` → all 20 tests pass instantly, no hang
- `zig build cov` → 99.72% coverage (io_sink + std_renderer both at 100%)
