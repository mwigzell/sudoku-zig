# Handoff: Issue 27 (path.zig module) created to address Issue 25 Step 11

## What was done

**Created Issue 27** (`.scratch/sudoku/issues/27-path-module.md`) — new `src/path.zig` module for OS-aware data directory resolution. This is the proper fix for the relative path crash in `openGame()`.

**Updated Issue 25 Step 11** → now status `🔄 → Issue #27`, blocked until the path module lands.

## Decisions made

### Allocator: use `std.heap.page_allocator` directly
- `handleResult()` currently has no allocator threaded through it.
- Rather than add `gpa` as a struct field or thread through init(), use `std.heap.page_allocator` for the short-lived path strings.
- Path allocations are tiny (~50-100 bytes) and freed immediately via errdefer — page allocator is cheap here.
- **Signature stays:** `getDataDir(gpa, io)` still takes an explicit allocator param for consistency with stdlib style; call site will pass `std.heap.page_allocator`.

### Directory creation: take `io` param, use `createDirPath`
- `std.Io.Dir.createDirPath(io, sub_path)` is the `mkdir -p` equivalent on 0.17.
- We silently catch/ignore its return — save/open will fail with real errors if the dir truly can't be accessed.

### Platform strategy: Linux now, compile_error elsewhere
- `getHomeDir()` switches on `std.builtin.target.os.tag`, implements `.linux` branch, `else => compile_error(...)`.
- macOS/Windows deferred to future issues (they have different conventions and Windows has WTF-16 encoding issues with getAlloc).

## Next steps (Issue 27 implementation)

| Step | Description |
|------|-------------|
| 1 | Create `src/path.zig` — `getHomeDir()` using `Environ.getAlloc(environ, gpa, "HOME")` + compile_error switch |
| 2 | Add `getDataDir(gpa, io)` — allocates `~/.local/share/sudoku/`, calls `cwd.createDirPath(io, data_dir)` |
| 3 | Add `resolveSavePath(gpa, path)` — joins bare filename against data dir; passes absolute through via dupe |
| 4 | Wire into `sudoku.zig` handleResult for both `.save` (DEFAULT_SAVE_FILE) and `.open` (o_data.path) |
| 5 | Tests covering each function + edge cases (absolute passthrough, HOME missing, etc.) |

## Open questions for next agent

1. **Absolute path detection:** `path[0] == '/'` is sufficient on Linux? Or should we use a proper "is absolute" check?
## Agent corrections / additions (2026-08-04)

### BLOCKING: Original `Environ` approach doesn't compile on Linux
- The original spec proposes: `std.process.Environ{ .block = .{ .use_global = true } }` + `getAlloc(environ, gpa, "HOME")`.
- This only works on Windows/WASI where `Environ.Block` is a `GlobalBlock` (has `.use_global`).
- On **Linux**, `Environ.Block` is `PosixBlock` which has a `.slice` field — no `.use_global` exists.
- `getAlloc()` is a method on `Map`, not `Environ` — it requires building a full map first from the raw envp, adding allocator overhead we don't need to read one string.

### DECISION: Use `std.c.environ` directly (Option B)
- Same global that Zig's own startup code reads envp from on Linux (verified at `std/start.zig`).
- Pattern: walk null-terminated array, find `HOME=...`, extract with `mem.sliceTo()`.
- Matches project pattern — `game_engine.zig` already uses `std.heap.page_allocator` everywhere for short-lived allocs.
- Avoids threading `*Environ.Map` through 5 layers of call chain (main → Sudoku → handleResult → path module).

### DECISION: `resolveSavePath` takes `data_dir` param
- Signature: `resolveSavePath(gpa, data_dir, path)` — caller passes the already-resolved data dir.
- Keeps `getDataDir` and `resolveSavePath` cleanly separated: one resolves data dir (with side effect of mkdir), the other does pure path joining. Prevents calling `createDirPath` needlessly when only resolving a bare filename.

### OPEN QUESTION ANSWERED: `path[0] == '/'` is fine for Linux
- On Linux, absolute paths always start with `/`. No symlink or mount-namespace tricks matter here — we're just doing string ops. No need for a heavier check.
