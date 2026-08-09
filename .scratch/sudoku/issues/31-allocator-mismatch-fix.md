Status: closed
triage: ready-for-agent

## Parent
`.scratch/sudoku/issues/29-renderer-facade-for-wasm.md` (blocks Step 1a–1c and Step 2e)

## What to build

Fix the allocator mismatch in `ReaderSource.readline()` → `AsciiRenderer.getCommandInput()`.

### The bug

`getCommandInput()` L148-154 and `readLine()` L92-97:
```zig
const raw = self.inputSource.readline(self.io) catch ...;
defer self.allocator.free(raw);   // frees with renderer's allocator — WRONG
```

But `ReaderSource.readline()` dispatches to two different allocators:

| Tag | What allocates the slice | Mismatch |
|-----|-------------------------|----------|
| `.mock` → `MockSource.readLine()` | `self.allocator.dupe()` inside MockSource — whatever was passed to `MockSource.init()` | If test constructs MockSource with SafeAllocator canary `0xaaaaaaaa` and renderer uses canary `0xeeeeeeee`, the free on L154 hits the wrong canary → panic |
| `.stdin` → `StdinSource.readLine()` | `reader.interface.takeDelimiter('\n')` — hidden Allocating writer bridge's internal allocator | Cross-allocator free = undefined behaviour. Different SafeAllocator instance or plain GPA mismatch |

Proven by `src/debug_command_input.zig` — two SafeAllocators with distinct canaries trigger the panic at L154.

### Root cause

The contract "caller owns returned slice, frees with renderer's allocator" is not honoured by either source variant. The renderer passes its allocator to itself, but never threads it down into the source layer where allocation actually happens.

---

## Fix: Option C — Unified allocator in StdinSource

**Principle:** `ReaderSource.readline()` returns a slice allocated by `self.allocator`. One allocator, one free. No cross-instance leaks.

### Change 1: `StdinSource` gains an allocator field + init

Currently zero-field (`input_source.zig` L5-13). Becomes:

```zig
pub const StdinSource = struct {
    allocator: std.mem.Allocator,

    pub fn initStdin(allocator: std.mem.Allocator) StdinSource {
        return .{ .allocator = allocator };
    }
```

And `readLine` rewrites from the current `.interface.takeDelimiter()` path to use an explicit `Io.Writer.Allocating` backed by `self.allocator`. The returned slice then belongs to `self.allocator` — exactly what the renderer's `defer self.allocator.free(raw)` expects.

**Why change StdinSource's shape?** Today it wraps a stack buffer `[512]u8` for reading, which only works for lines ≤ 511 bytes. Longer input silently truncates or wraps through `.interface`. And either way the caller can't `free()` what they didn't allocate. Using the same allocator throughout closes all loops: alloc → readline → trim → free, all on one allocator.

### Change 2: MockSource — no code change, just construction discipline

MockSource already stores an allocator (L19) and uses it for `dupe()` (L37). The fix is at the construction site: pass the **renderer's allocator** to `MockSource.init()`.

Every existing test passes `std.testing.allocator` consistently for both MockSource init AND free — those tests already work because they use the same allocator instance. The only thing that broke was `debug_command_input.zig`, which was intentionally using two separate SafeAllocators to prove the mismatch (after this fix it still works because StdinSource's path is also unified).

### Change 3: `main.zig` L19 — pass allocator at construction

```zig
// Before:
.{ .stdin = input_source.StdinSource{} }

// After:
.{ .stdin = input_source.StdinSource.initStdin(std.heap.page_allocator) }
```

Same allocator passed to both AsciiRenderer and StdinSource.

### Change 4: `debug_command_input.zig` — update or remove

The debug app was a diagnostic probe, not production code. Options:
- Remove entirely (preferred — served its purpose)
- Update to use single allocator (if keeping for regression test)

Either way needs cleanup alongside this issue.

---

## Implementation plan

| Step | Description | TDD |
|------|-------------|-----|
| 1d-i | Add `allocator` field + `initStdin()` to `StdinSource` in `input_source.zig`. Rewrite `readLine` to use Allocating reader with `self.allocator`. | Standalone test: StdinSource.readLine returns owned slice freeable with its own allocator |
| 1d-ii | Update `main.zig` L19 construction site | No new test needed — build regression proves it compiles |
| 1d-iii | Delete `src/debug_command_input.zig` and the `debug_command_runner.zig` stub. Remove junk build step from `build.zig` | Build clean + full test suite passes |
| 1d-iv | Verify existing MockSource tests still pass; verify `getCommandInput` panic is gone when run via `zig build run` | Regression: all 204+ tests pass; no crash on real stdin input |

---

## Files involved

| File | Change |
|------|--------|
| `src/input_source.zig` | StdinSource gains allocator + initStdin(), readLine rewritten. MockSource untouched. Existing tests updated if needed. |
| `src/main.zig` L19 | Pass allocator to StdinSource construction |
| `src/debug_command_input.zig` | **Delete** (diagnostic probe, served its purpose) |
| `src/debug_command_runner.zig` | **Delete** (stale file from failed attempts) |
| `build.zig` L32-49 | Remove junk debug-cmd build step referencing wrong file |

---

## What does NOT change

- `getCommandInput()` body at L148 — `defer self.allocator.free(raw)` was always correct. The bug was below it, not here.
- `readLine()` body at L92-L97 — same deal; the free was wrong because the source layer didn't honour the contract, not because the line itself was buggy.
- Facade struct or Make() wrappers — untouched.
- Existing MockSource test pattern (pass same allocator for dupe+free) — already correct, unchanged.

---

## Risk assessment

**Low.** The change:
1. Adds one field to a struct used only for I/O (two construction sites)
2. Makes the allocator contract explicit where it was implicit and broken
3. Removes dead code (debug files) as a bonus cleanup
4. No behavioural change to correct inputs — same string returned, just from the right allocator

---

## Acceptance Criteria

- [ ] `StdinSource` has an `allocator` field and `initStdin()` constructor
- [ ] `StdinSource.readLine()` returns a slice allocated by its own allocator (freeable with `self.allocator.free()`)
- [ ] `MockSource` construction passes renderer's allocator consistently
- [ ] `main.zig` wires StdinSource with same allocator as AsciiRenderer
- [ ] `debug_command_input.zig` and `debug_command_runner.zig` deleted; build.zig clean
- [ ] All 204+ existing tests pass
- [ ] No SafeAllocator panic on real stdin command input
